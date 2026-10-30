import Foundation

/// An open vault: its files on this device (`Vault`), its index (`VaultIndex`), and two-way sync
/// with its remote. What an Atlas app holds while a vault is open, and the one place the app
/// reads and changes pages through, so the index never falls behind the files.
///
/// It lives on the main actor, like the UI that uses it. A sync pass runs there too and only
/// suspends at network calls. Pages written while a pass is running are held back and written
/// to the vault when it ends: the pass commits each file only after the server accepted it, and
/// an edit slipped in under it would be recorded as already synced. Moves and deletions wait
/// for the pass to finish.
@MainActor
public final class VaultWorkspace {
    public let index: VaultIndex
    private let vault: Vault
    private let engine: VaultSync

    public private(set) var isSyncing = false
    public private(set) var lastSync: Date?
    /// Conflicted copies made by the last passes, until the app clears them.
    public var conflicts: [SyncReport.Conflict] = []

    /// Edits made during a pass, written when it ends.
    private var pending: [String: Data] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called after anything changed the vault's files or their content: an edit, a move, a
    /// deletion, or a sync pass that brought changes. `moved` maps old paths to new ones, so an
    /// app can follow a page it has open.
    public var onChange: ((_ moved: [String: String]) -> Void)?

    public init(vault: Vault, remote: VaultRemote) throws {
        self.vault = vault
        self.engine = VaultSync(vault: vault, remote: remote)
        self.index = try VaultIndex()
        try index.batch {
            for path in vault.paths { try reindex(path) }
        }
    }

    // MARK: Reading

    /// Every file's path, sorted: pages (`.md`) and attachments.
    public var paths: [String] {
        guard !pending.isEmpty else { return vault.paths }
        return Set(vault.paths).union(pending.keys).sorted()
    }

    public var pages: [String] { paths.filter(Self.isPage) }

    public func content(at path: String) throws -> Data? {
        if let data = pending[path] { return data }
        return try vault.content(at: path)
    }

    public func text(at path: String) throws -> String? {
        try content(at: path).map { String(decoding: $0, as: UTF8.self) }
    }

    public func contains(_ path: String) -> Bool { pending[path] != nil || vault.record(at: path).map { !$0.deleted } == true }

    nonisolated public static func isPage(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    nonisolated public static func title(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return isPage(name) ? String(name.dropLast(3)) : name
    }

    // MARK: Changing

    /// Saves a page's text (or an attachment's bytes) and re-indexes it.
    public func write(_ data: Data, at path: String) throws {
        if try content(at: path) == data { return }
        if isSyncing {
            pending[path] = data
        } else {
            try vault.write(data, at: path)
        }
        try reindex(path, data: data)
        onChange?([:])
    }

    public func write(text: String, at path: String) throws { try write(Data(text.utf8), at: path) }

    /// A new, empty page titled `title` in `folder`, numbered if the title is taken. Returns its path.
    @discardableResult
    public func createPage(titled title: String = "Untitled", in folder: String = "", text: String = "") throws -> String {
        let clean = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        var path = Self.join(folder, base + ".md")
        var n = 2
        while contains(path) { path = Self.join(folder, "\(base) \(n).md"); n += 1 }
        try write(text: text, at: path)
        return path
    }

    /// Renames or moves a file, and rewrites the links to it across the vault (SPEC §7). Waits
    /// for a running pass. Returns how many pages had links rewritten.
    @discardableResult
    public func move(from old: String, to new: String) async throws -> Int {
        guard old != new else { return 0 }
        await untilIdle()
        guard !contains(new) else { throw CocoaError(.fileWriteFileExists) }
        let before = LinkResolver(files: paths)
        let linking = try index.pagesLinking(to: old)
        try vault.move(from: old, to: new)
        try index.renameFile(from: old, to: new)
        let after = LinkResolver(files: paths)

        var rewritten = 0
        for page in linking {
            let source = page == old ? new : page
            guard let text = try vault.text(at: source) else { continue }
            var document = MarkdownDocument(source: text)
            let result = document.rewriteLinks(toRenamed: old, as: new, linkingPage: source, before: before, after: after)
            guard result.rewritten > 0 else { continue }
            let updated = document.serialized()
            try vault.write(text: updated, at: source)
            try index.upsertPage(source, source: updated)
            rewritten += 1
        }
        onChange?([old: new])
        return rewritten
    }

    /// "Link it": turns the unlinked mentions of `path` in the page `source` into wiki links
    /// (`AtlasMarkdown.linkingMentions`). `name` is the title or alias that was mentioned
    /// (`VaultIndex.Mention.name`); the page's title by default. Returns how many were linked.
    @discardableResult
    public func linkMentions(of path: String, in source: String, name: String? = nil) throws -> Int {
        guard let text = try text(at: source) else { return 0 }
        let resolver = LinkResolver(files: paths)
        var target = resolver.linkTarget(for: path)
        // The shortest target resolves from the vault's root; make sure it does from `source` too.
        if resolver.resolve(target, from: source) != path { target = Self.isPage(path) ? String(path.dropLast(3)) : path }
        guard let (linked, count) = AtlasMarkdown.linkingMentions(of: name ?? Self.title(of: path), as: target, in: text) else { return 0 }
        try write(text: linked, at: source)
        return count
    }

    /// Deletes a file. Waits for a running pass.
    public func delete(at path: String) async throws {
        await untilIdle()
        try vault.delete(at: path)
        try index.removeFile(path)
        onChange?([:])
    }

    // MARK: Sync

    /// One sync pass, then the edits held back during it. Returns nil if a pass was already
    /// running (its result will include this call's changes, or the next pass's will).
    @discardableResult
    public func sync() async throws -> SyncReport? {
        guard !isSyncing else { return nil }
        isSyncing = true
        var report = SyncReport()
        do {
            report = try await engine.sync()
        } catch {
            try finishPass(report)
            throw error
        }
        try finishPass(report)
        lastSync = Date()
        return report
    }

    private func finishPass(_ report: SyncReport) throws {
        defer {
            isSyncing = false
            for waiter in idleWaiters { waiter.resume() }
            idleWaiters = []
        }
        var moved: [String: String] = [:]
        for move in report.moved {
            try index.renameFile(from: move.from, to: move.to)
            moved[move.from] = move.to
        }
        for path in report.removed + report.deletedRemotely { try index.removeFile(path) }
        let changed = report.updated + report.merged + report.restored + report.conflicts.flatMap { [$0.path, $0.copy] }
        for path in Set(changed) where vault.record(at: path) != nil { try reindex(path) }
        conflicts += report.conflicts

        // Held-back edits, following any move the pass made.
        let held = pending
        pending = [:]
        for (path, data) in held {
            let target = moved[path] ?? path
            try vault.write(data, at: target)
            try reindex(target, data: data)
        }
        if !moved.isEmpty || !changed.isEmpty || !report.removed.isEmpty || !held.isEmpty { onChange?(moved) }
    }

    /// Whether anything is waiting to be synced.
    public var hasUnsyncedChanges: Bool {
        !pending.isEmpty || vault.records.contains { $0.dirty || $0.deleted || $0.fileID == nil || $0.path != $0.basePath }
    }

    private func untilIdle() async {
        guard isSyncing else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Index

    private func reindex(_ path: String, data: Data? = nil) throws {
        if Self.isPage(path) {
            guard let data = try data ?? vault.content(at: path) else { return }
            try index.upsertPage(path, source: String(decoding: data, as: UTF8.self))
        } else {
            try index.addFile(path)
        }
    }

    nonisolated static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }
}

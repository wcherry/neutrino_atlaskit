import Foundation

/// A file in the vault's Drive folder tree, as the server lists it.
public struct RemoteFile: Equatable, Sendable {
    public var id: String
    /// Vault-relative path, `/`-separated, built from the Drive folder names.
    public var path: String
    /// Drive's `content_version`: bumped by every content write.
    public var version: Int

    public init(id: String, path: String, version: Int) {
        self.id = id
        self.path = path
        self.version = version
    }
}

public enum VaultRemoteError: Error, Equatable {
    /// A guarded write lost the race: the server's content moved on (Drive's 409
    /// `CONTENT_VERSION_CONFLICT`).
    case conflict
    /// The file is gone (deleted or trashed on another device).
    case notFound
}

/// The vault on the server: a Drive folder tree whose files hold encrypted content. The Drive
/// adapter does the HTTP, the folders, and the encryption with NeutrinoCrypto. Sync only sees
/// plaintext bytes and paths.
public protocol VaultRemote {
    /// Every file in the vault.
    func list() async throws -> [RemoteFile]
    /// A file's content, and the `content_version` that content is.
    func download(_ id: String) async throws -> (data: Data, version: Int)
    /// Creates a file at `path`, making any folders it needs.
    func create(at path: String, data: Data) async throws -> RemoteFile
    /// Replaces a file's content if the server is still at `expectedVersion` (else
    /// `VaultRemoteError.conflict`). Returns the new version.
    func replace(_ id: String, data: Data, expectedVersion: Int) async throws -> Int
    /// Renames or moves a file, making any folders it needs.
    func move(_ id: String, to path: String) async throws
    /// Moves a file to the trash.
    func delete(_ id: String) async throws
}

/// What one sync pass did, so the app can update the index (`VaultIndex`) and tell the user
/// about conflicts.
public struct SyncReport: Equatable, Sendable {
    public struct Move: Equatable, Sendable { public var from: String; public var to: String }
    public struct Conflict: Equatable, Sendable {
        /// The page, now holding the server's version.
        public var path: String
        /// This device's version, saved alongside.
        public var copy: String
    }

    /// Files whose local content changed: pulled, merged, or the page side of a conflict.
    public var updated: [String] = []
    /// Files uploaded or pushed.
    public var uploaded: [String] = []
    /// Local edits merged with remote edits, line by line.
    public var merged: [String] = []
    /// Files deleted locally because they were deleted elsewhere.
    public var removed: [String] = []
    /// Files deleted on the server because they were deleted here.
    public var deletedRemotely: [String] = []
    /// Files moved locally to follow a move elsewhere.
    public var moved: [Move] = []
    /// Both sides changed the same lines: both versions kept.
    public var conflicts: [Conflict] = []
    /// Files edited here but deleted elsewhere: uploaded again rather than lost.
    public var restored: [String] = []

    public init() {}
}

/// Two-way sync between a `Vault` and its `VaultRemote`.
///
/// One `sync()` pass lists the server and reconciles every file. It never discards a change:
/// - an edit here and an edit there are merged line by line (`ThreeWayMerge`);
/// - when that's impossible, the server's version keeps the page and this device's goes to a
///   conflicted copy beside it;
/// - an edit to a file deleted elsewhere brings the file back.
///
/// Each file's outcome is committed only after the server accepted it. A pass interrupted by a
/// network error leaves everything consistent, and the next pass carries on from there.
public struct VaultSync {
    public let vault: Vault
    public let remote: VaultRemote
    /// When conflicted copies are stamped with. Injected so tests are deterministic.
    public var now: () -> Date = Date.init

    public init(vault: Vault, remote: VaultRemote) {
        self.vault = vault
        self.remote = remote
    }

    /// Runs on the caller's actor (`isolation`), so an app calling it from the main actor reads
    /// and writes the vault there, as its UI does. It suspends only at network calls.
    @discardableResult
    public func sync(isolation: isolated (any Actor)? = #isolation) async throws -> SyncReport {
        var report = SyncReport()
        let listing = try await resolvingDuplicatePaths(try await remote.list())
        var byID: [String: RemoteFile] = [:]
        for file in listing { byID[file.id] = file }
        var seen = Set<String>()

        // 1. Files this device has synced before. Tracked by file id, not path: an earlier step
        // in this pass may have moved a record aside, and it must still be reconciled, once.
        for id in vault.records.compactMap(\.fileID) {
            if byID[id] != nil { seen.insert(id) }
            guard let current = vault.record(fileID: id) else { continue }  // forgotten earlier in this pass
            if let file = byID[id] {
                try await reconcile(current, with: file, report: &report)
            } else {
                try await reconcileDeletedRemotely(current, report: &report)
            }
        }

        // 2. Files the server has that this device doesn't know: new elsewhere. One record per
        // file id, always: a second would share the first's merge base.
        for file in listing where !seen.contains(file.id) && vault.record(fileID: file.id) == nil {
            if let local = vault.record(at: file.path), local.fileID == nil {
                // Created on both sides at the same path: adopt it if the content matches,
                // otherwise keep both.
                seen.insert(file.id)
                try await adoptOrKeepBoth(local, file, report: &report)
            } else {
                try makeRoom(at: file.path, for: file.id)
                try await pull(file, into: file.path, report: &report)
            }
        }

        // 3. Files created on this device (conflicted copies from step 1 and 2 included).
        for record in vault.records where record.fileID == nil && !record.deleted {
            try await upload(record, report: &report)
        }
        return report
    }

    // MARK: - Synced files

    private func reconcile(_ record: SyncRecord, with file: RemoteFile, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        var record = record
        if record.deleted {
            if file.version == record.baseVersion {
                try await ignoringNotFound { try await remote.delete(file.id) }
                try vault.forget(record.path)
                report.deletedRemotely.append(record.path)
            } else {
                // Edited elsewhere after this device deleted it: the edit wins.
                try vault.forget(record.path)
                try makeRoom(at: file.path, for: file.id)
                try await pull(file, into: file.path, report: &report)
            }
            return
        }

        // Paths. A move on one side follows to the other; if both moved, the server's wins.
        let movedHere = record.path != record.basePath
        let movedThere = file.path != record.basePath
        if movedThere, file.path != record.path {
            try makeRoom(at: file.path, for: file.id)
            try vault.relocate(from: record.path, to: file.path)
            report.moved.append(.init(from: record.path, to: file.path))
            record.path = file.path
            record.basePath = file.path
            try vault.commit(record, content: nil, base: nil)
        } else if movedHere {
            try await remote.move(file.id, to: record.path)
            record.basePath = record.path
            try vault.commit(record, content: nil, base: nil)
        }

        // Content.
        let changedThere = file.version != record.baseVersion
        switch (record.dirty, changedThere) {
        case (false, false):
            return
        case (false, true):
            try await pull(file, into: record.path, report: &report)
        case (true, false):
            do {
                try await push(record, expectedVersion: file.version, report: &report)
            } catch VaultRemoteError.conflict {
                try await merge(record, report: &report)
            }
        case (true, true):
            try await merge(record, report: &report)
        }
    }

    private func reconcileDeletedRemotely(_ record: SyncRecord, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        if record.deleted || !record.dirty {
            try vault.forget(record.path)
            if !record.deleted { report.removed.append(record.path) }
        } else {
            // Edited here, deleted elsewhere: upload it again rather than lose the edit.
            var fresh = record
            fresh.fileID = nil
            fresh.baseVersion = nil
            fresh.basePath = nil
            try vault.commit(fresh, content: nil, base: nil)
            report.restored.append(record.path)
        }
    }

    // MARK: - Transfers

    private func pull(_ file: RemoteFile, into path: String, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        let (data, version) = try await remote.download(file.id)
        let record = SyncRecord(path: path, fileID: file.id, baseVersion: version, basePath: file.path, dirty: false)
        try vault.commit(record, content: data, base: Self.keepsBase(path) ? data : nil)
        report.updated.append(path)
    }

    private func push(_ record: SyncRecord, expectedVersion: Int, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        guard let id = record.fileID, let data = try vault.content(at: record.path) else { return }
        let version = try await remote.replace(id, data: data, expectedVersion: expectedVersion)
        var record = record
        record.baseVersion = version
        record.dirty = false
        try vault.commit(record, content: nil, base: Self.keepsBase(record.path) ? data : nil)
        report.uploaded.append(record.path)
    }

    private func upload(_ record: SyncRecord, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        guard let data = try vault.content(at: record.path) else { return }
        let file = try await remote.create(at: record.path, data: data)
        let synced = SyncRecord(path: record.path, fileID: file.id, baseVersion: file.version, basePath: file.path, dirty: false)
        try vault.commit(synced, content: nil, base: Self.keepsBase(record.path) ? data : nil)
        report.uploaded.append(record.path)
    }

    /// Both sides changed the file. Merge the text line by line and push the result; if that
    /// isn't possible, the server's version takes the page and this device's goes to a copy.
    private func merge(_ record: SyncRecord, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        guard let id = record.fileID, let local = try vault.content(at: record.path) else { return }
        for _ in 0..<3 {
            let (theirs, version) = try await remote.download(id)
            if Self.keepsBase(record.path), let base = try vault.base(fileID: id),
               let merged = ThreeWayMerge.merge(base: String(decoding: base, as: UTF8.self),
                                                local: String(decoding: local, as: UTF8.self),
                                                remote: String(decoding: theirs, as: UTF8.self)) {
                let data = Data(merged.utf8)
                do {
                    let newVersion = try await remote.replace(id, data: data, expectedVersion: version)
                    var synced = record
                    synced.baseVersion = newVersion
                    synced.dirty = false
                    try vault.commit(synced, content: data, base: data)
                    report.merged.append(record.path)
                    report.updated.append(record.path)
                    return
                } catch VaultRemoteError.conflict {
                    continue  // It moved again while we merged: merge with the newer version.
                }
            }
            try keepBoth(record, local: local, theirs: theirs, version: version, report: &report)
            return
        }
        // Still racing after three tries: keep both rather than loop.
        let (theirs, version) = try await remote.download(id)
        try keepBoth(record, local: local, theirs: theirs, version: version, report: &report)
    }

    private func keepBoth(_ record: SyncRecord, local: Data, theirs: Data, version: Int, report: inout SyncReport) throws {
        let copy = conflictedCopyPath(for: record.path)
        try vault.write(local, at: copy)  // a new local file; step 3 uploads it
        var synced = record
        synced.baseVersion = version
        synced.dirty = false
        try vault.commit(synced, content: theirs, base: Self.keepsBase(record.path) ? theirs : nil)
        report.conflicts.append(.init(path: record.path, copy: copy))
        report.updated.append(record.path)
    }

    /// The same path created here and elsewhere before either synced.
    private func adoptOrKeepBoth(_ local: SyncRecord, _ file: RemoteFile, report: inout SyncReport, isolation: isolated (any Actor)? = #isolation) async throws {
        let (theirs, version) = try await remote.download(file.id)
        let mine = try vault.content(at: local.path)
        if mine != theirs, let mine {
            let copy = conflictedCopyPath(for: local.path)
            try vault.write(mine, at: copy)
            report.conflicts.append(.init(path: local.path, copy: copy))
        }
        let record = SyncRecord(path: local.path, fileID: file.id, baseVersion: version, basePath: file.path, dirty: false)
        try vault.commit(record, content: theirs, base: Self.keepsBase(local.path) ? theirs : nil)
        report.updated.append(local.path)
    }

    // MARK: - Path collisions

    /// Drive allows two files with the same name in a folder; the vault doesn't. When the server
    /// lists several files at one path, the one with the smallest id keeps it and the others are
    /// moved to a name made from their id. Every device computes the same names, so devices that
    /// notice at the same time agree instead of moving files back and forth.
    private func resolvingDuplicatePaths(_ listing: [RemoteFile], isolation: isolated (any Actor)? = #isolation) async throws -> [RemoteFile] {
        var byPath: [String: [RemoteFile]] = [:]
        for file in listing { byPath[file.path, default: []].append(file) }
        var out: [RemoteFile] = []
        for (path, files) in byPath {
            let sorted = files.sorted { $0.id < $1.id }
            out.append(sorted[0])
            for var file in sorted.dropFirst() {
                let aside = Self.asidePath(for: path, fileID: file.id)
                try await ignoringNotFound { try await remote.move(file.id, to: aside) }
                file.path = aside
                out.append(file)
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Clears `path` for the server file `incomingID`. A different local file there is one this
    /// device moved or created and hasn't pushed yet: the server's claim wins, and the local file
    /// steps aside (to a name made from its id, or a conflicted-copy name if it has none). Its
    /// move then reaches the server on the next pass.
    private func makeRoom(at path: String, for incomingID: String) throws {
        guard let occupant = vault.record(at: path), !occupant.deleted, occupant.fileID != incomingID else { return }
        if occupant.deleted { return }
        let aside = occupant.fileID.map { Self.asidePath(for: path, fileID: $0) } ?? conflictedCopyPath(for: path)
        try vault.relocate(from: path, to: aside)
    }

    /// `Folder/Title (conflicted copy f123).md`: the same on every device.
    static func asidePath(for path: String, fileID: String) -> String {
        let (stem, ext) = splitExtension(path)
        return "\(stem) (conflicted copy \(fileID))\(ext)"
    }

    static func splitExtension(_ path: String) -> (String, String) {
        let dot = path.lastIndex(of: ".").flatMap { path[$0...].contains("/") ? nil : $0 }
        return (dot.map { String(path[..<$0]) } ?? path, dot.map { String(path[$0...]) } ?? "")
    }

    // MARK: - Helpers

    /// Only text pages keep a base copy: it is what a three-way merge needs, and attachments
    /// aren't merged.
    static func keepsBase(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// `Folder/Title (conflicted copy 2026-10-29 1405).md`, numbered if that's taken.
    func conflictedCopyPath(for path: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: now())
        let (stem, ext) = Self.splitExtension(path)
        var candidate = "\(stem) (conflicted copy \(stamp))\(ext)"
        var n = 2
        while vault.record(at: candidate) != nil {
            candidate = "\(stem) (conflicted copy \(stamp) \(n))\(ext)"
            n += 1
        }
        return candidate
    }

    private func ignoringNotFound(_ body: () async throws -> Void) async throws {
        do { try await body() } catch VaultRemoteError.notFound {}
    }
}

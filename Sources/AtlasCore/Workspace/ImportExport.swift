import Foundation

/// A folder of Markdown and attachments read from disk: an Obsidian vault, or an Atlas export.
public struct FolderSnapshot: Sendable {
    /// Paths relative to the folder, with `/`, and each file's bytes.
    public var files: [(path: String, data: Data)]
    /// Files left out because they're larger than `maxFileSize`.
    public var tooLarge: [String]

    /// Larger files are left out (and listed in `tooLarge`). Drive takes them, but a vault of
    /// pages is no place for a disk image, and a mistaken folder choice shouldn't upload one.
    public static let maxFileSize = 100 * 1024 * 1024

    /// Reads every file under `folder`. Skips hidden files and folders, so Obsidian's
    /// `.obsidian` settings and `.trash`, `.git` and `.DS_Store` stay out. Also skips symbolic
    /// links, so nothing outside the folder is read.
    public static func read(_ folder: URL) throws -> FolderSnapshot {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var files: [(String, Data)] = [], tooLarge: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            let path = parts.dropFirst(base.count).joined(separator: "/").precomposedStringWithCanonicalMapping
            if (values.fileSize ?? 0) > maxFileSize { tooLarge.append(path); continue }
            files.append((path, try Data(contentsOf: url)))
        }
        files.sort { $0.0 < $1.0 }
        return FolderSnapshot(files: files, tooLarge: tooLarge.sorted())
    }

    /// Writes the files under `folder`, creating it and any subfolders. Refuses a folder that
    /// already has files in it, so an export never mixes with or overwrites anything.
    public func write(to folder: URL) throws {
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(atPath: folder.path), !existing.filter({ !$0.hasPrefix(".") }).isEmpty {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path])
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files {
            // Paths come from the vault; never let one climb out of the folder.
            guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !path.hasPrefix("/") else { continue }
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
        }
    }
}

/// What an import did.
public struct ImportReport: Equatable, Sendable {
    public var imported: [String] = []
    /// Already in the vault with the same content.
    public var unchanged: [String] = []
    /// In the vault with other content: the imported file went beside it. Old path to new.
    public var renamed: [String: String] = [:]
    public var tooLarge: [String] = []
    /// Wiki-link targets that resolve to no file after the import, with how many links use them.
    public var unresolvedLinks: [(target: String, count: Int)] = []

    public static func == (a: ImportReport, b: ImportReport) -> Bool {
        a.imported == b.imported && a.unchanged == b.unchanged && a.renamed == b.renamed && a.tooLarge == b.tooLarge
            && a.unresolvedLinks.map(\.target) == b.unresolvedLinks.map(\.target) && a.unresolvedLinks.map(\.count) == b.unresolvedLinks.map(\.count)
    }
}

extension VaultWorkspace {
    /// Imports a folder of Markdown and attachments, such as an Obsidian vault, into `folder`
    /// of this vault (its root by default). Every file keeps its bytes: Atlas Markdown reads
    /// Obsidian's dialect as it is (SPEC §1), and links resolve the way Obsidian resolves them.
    /// A file already here with the same content is skipped; one with other content is
    /// imported beside it as `Name (imported).md`, so nothing in the vault is overwritten.
    public func importFiles(_ snapshot: FolderSnapshot, into folder: String = "") throws -> ImportReport {
        var report = ImportReport(tooLarge: snapshot.tooLarge)
        // One change notice for the whole import, not one per file.
        let notify = onChange
        onChange = nil
        defer {
            onChange = notify
            if !report.imported.isEmpty { notify?([:]) }
        }
        try index.batch {
            for (relative, data) in snapshot.files {
                var path = Self.join(folder, relative)
                if let existing = try content(at: path) {
                    if existing == data { report.unchanged.append(path); continue }
                    let (renamed, alreadyThere) = try importedName(for: path, data: data)
                    if alreadyThere { report.unchanged.append(renamed); continue }
                    report.renamed[path] = renamed
                    path = renamed
                }
                try write(data, at: path)
                report.imported.append(path)
            }
        }
        report.unresolvedLinks = try index.unresolvedTargets()
        return report
    }

    /// Every file in the vault, decrypted: what an export writes. Markdown pages are the
    /// files as they are, so the export is the vault, readable by any Markdown editor.
    public func exportFiles() throws -> FolderSnapshot {
        FolderSnapshot(files: try paths.compactMap { path in try content(at: path).map { (path, $0) } }, tooLarge: [])
    }

    /// The first free `Name (imported N)` beside `path`, or an earlier import's copy that
    /// already holds `data` (so importing the same folder twice adds nothing).
    private func importedName(for path: String, data: Data) throws -> (path: String, alreadyThere: Bool) {
        let ns = path as NSString
        let ext = ns.pathExtension, stem = ((ns.lastPathComponent as NSString).deletingPathExtension)
        let folder = ns.deletingLastPathComponent
        var n = 1
        while true {
            let suffix = n == 1 ? " (imported)" : " (imported \(n))"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.isEmpty ? name : folder + "/" + name
            guard contains(candidate) else { return (candidate, false) }
            if try content(at: candidate) == data { return (candidate, true) }
            n += 1
        }
    }
}

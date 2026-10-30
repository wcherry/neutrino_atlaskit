import Foundation

/// What sync knows about one file of the vault.
public struct SyncRecord: Codable, Equatable, Sendable {
    /// Where the file is now, locally (vault-relative, `/`-separated, with its extension).
    public var path: String
    /// The Drive file it is synced with; nil until its first upload.
    public var fileID: String?
    /// The server `content_version` this device last synced the file at.
    public var baseVersion: Int?
    /// The path the server had at that sync. Differs from `path` after a local move.
    public var basePath: String?
    /// Changed locally since the last sync.
    public var dirty: Bool
    /// Deleted locally; the deletion hasn't reached the server yet.
    public var deleted: Bool

    public init(path: String, fileID: String? = nil, baseVersion: Int? = nil, basePath: String? = nil, dirty: Bool = false, deleted: Bool = false) {
        self.path = path
        self.fileID = fileID
        self.baseVersion = baseVersion
        self.basePath = basePath
        self.dirty = dirty
        self.deleted = deleted
    }
}

/// Where a vault keeps its bytes on this device. `SealedDiskStorage` seals everything, so no
/// plaintext reaches the disk (neutrino-atlas.md, constraint 1).
public protocol VaultStorage: AnyObject {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
    /// Appends one entry to the journal.
    func appendToJournal(_ entry: Data) throws
    /// Every complete journal entry, oldest first. An entry torn by a crash mid-append (one that
    /// runs past the end) is dropped, so later appends stay readable. A complete entry that
    /// won't open throws: that is a wrong key or corruption, and nothing may be discarded.
    func readJournal() throws -> [Data]
    func clearJournal() throws
}

/// The local copy of a vault: every file's current content, the content it had at its last
/// sync (the base of a three-way merge), and its sync record.
///
/// All local edits go through here, so sync always knows what changed. Not thread-safe:
/// confine an instance to one actor or queue.
public final class Vault {
    private let storage: VaultStorage
    private var manifest: Manifest
    /// Drive file id → local path. Not persisted: rebuilt on load, and kept current by
    /// `setRecord`, the only way records change.
    private var pathByFileID: [String: String] = [:]

    /// The persisted map from paths to blobs, and the sync records.
    struct Manifest: Codable {
        var records: [String: SyncRecord] = [:]          // by path
        var content: [String: String] = [:]              // path → blob key
        var base: [String: String] = [:]                 // fileID → blob key
    }

    /// One change to the manifest, as appended to the journal. Values are absolute (nil
    /// removes), so replaying an entry twice is harmless.
    struct Delta: Codable {
        var records: [String: SyncRecord?] = [:]
        var content: [String: String?] = [:]
        var base: [String: String?] = [:]
        var isEmpty: Bool { records.isEmpty && content.isEmpty && base.isEmpty }
    }

    private static let manifestKey = "manifest"
    /// Journal entries before the manifest is rewritten in full and the journal cleared.
    static let compactionThreshold = 1_000
    private var pending = Delta()
    private var journalLength = 0

    public init(storage: VaultStorage) throws {
        self.storage = storage
        if let data = try storage.read(Self.manifestKey) {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } else {
            manifest = Manifest()
        }
        let journal = try storage.readJournal()
        for entry in journal {
            let delta = try JSONDecoder().decode(Delta.self, from: entry)
            for (path, record) in delta.records { manifest.records[path] = record }
            for (path, key) in delta.content { manifest.content[path] = key }
            for (id, key) in delta.base { manifest.base[id] = key }
        }
        journalLength = journal.count
        for (path, record) in manifest.records { if let id = record.fileID { pathByFileID[id] = path } }
    }

    /// Sets or removes the record at `path`, keeping the file-id index current. With
    /// `setContentKey` and `setBaseKey`, the only ways the manifest changes: each change is also
    /// added to the pending journal entry.
    private func setRecord(_ record: SyncRecord?, at path: String) {
        if let old = manifest.records[path], let id = old.fileID, pathByFileID[id] == path { pathByFileID[id] = nil }
        manifest.records[path] = record
        if let id = record?.fileID { pathByFileID[id] = path }
        pending.records[path] = .some(record)
    }

    private func setContentKey(_ key: String?, at path: String) {
        manifest.content[path] = key
        pending.content[path] = .some(key)
    }

    private func setBaseKey(_ key: String?, fileID: String) {
        manifest.base[fileID] = key
        pending.base[fileID] = .some(key)
    }

    // MARK: - Reading

    /// Every live file's path, sorted.
    public var paths: [String] { manifest.records.values.filter { !$0.deleted }.map(\.path).sorted() }

    public func content(at path: String) throws -> Data? {
        guard let record = manifest.records[path], !record.deleted, let key = manifest.content[path] else { return nil }
        return try storage.read(key)
    }

    public func text(at path: String) throws -> String? {
        try content(at: path).map { String(decoding: $0, as: UTF8.self) }
    }

    public var records: [SyncRecord] { manifest.records.values.sorted { $0.path < $1.path } }

    public func record(at path: String) -> SyncRecord? { manifest.records[path] }

    /// The record synced with Drive file `fileID`, wherever it is now. There is at most one.
    public func record(fileID: String) -> SyncRecord? {
        pathByFileID[fileID].flatMap { manifest.records[$0] }
    }

    // MARK: - Local edits

    /// Creates or replaces a file's content.
    public func write(_ data: Data, at path: String) throws {
        let key = UUID().uuidString
        try storage.write(data, for: key)
        let old = manifest.content[path]
        setContentKey(key, at: path)
        var record = manifest.records[path] ?? SyncRecord(path: path)
        record.dirty = true
        record.deleted = false
        setRecord(record, at: path)
        try save(thenRemove: [old])
    }

    public func write(text: String, at path: String) throws { try write(Data(text.utf8), at: path) }

    /// Deletes a file. A never-synced file just disappears; a synced one leaves a tombstone until
    /// the deletion reaches the server.
    public func delete(at path: String) throws {
        guard var record = manifest.records[path] else { return }
        let old = manifest.content[path]
        setContentKey(nil, at: path)
        if record.fileID == nil {
            setRecord(nil, at: path)
        } else {
            record.deleted = true
            setRecord(record, at: path)
        }
        try save(thenRemove: [old])
    }

    /// Renames or moves a file. Its content and sync state move with it.
    public func move(from old: String, to new: String) throws {
        guard old != new, var record = manifest.records[old], !record.deleted, manifest.records[new] == nil else { return }
        setRecord(nil, at: old)
        record.path = new
        setRecord(record, at: new)
        let key = manifest.content[old]
        setContentKey(nil, at: old)
        setContentKey(key, at: new)
        try save()
    }

    // MARK: - For sync

    func base(fileID: String) throws -> Data? {
        guard let key = manifest.base[fileID] else { return nil }
        return try storage.read(key)
    }

    /// After a successful sync of a file: its content (`nil` to keep what's there), its base,
    /// and its record, all at once.
    func commit(_ record: SyncRecord, content: Data?, base: Data?) throws {
        var stale: [String?] = []
        if let content {
            let key = UUID().uuidString
            try storage.write(content, for: key)
            stale.append(manifest.content[record.path])
            setContentKey(key, at: record.path)
        }
        if let fileID = record.fileID, let base {
            let key = UUID().uuidString
            try storage.write(base, for: key)
            stale.append(manifest.base[fileID])
            setBaseKey(key, fileID: fileID)
        }
        setRecord(record, at: record.path)
        try save(thenRemove: stale)
    }

    /// Moves a record (and its content) to another path as part of sync, without marking it dirty.
    func relocate(from old: String, to new: String) throws {
        guard old != new, var record = manifest.records[old] else { return }
        setRecord(nil, at: old)
        record.path = new
        setRecord(record, at: new)
        if let key = manifest.content[old] {
            setContentKey(nil, at: old)
            setContentKey(key, at: new)
        }
        try save()
    }

    /// Forgets a file entirely: content, base and record.
    func forget(_ path: String) throws {
        guard let record = manifest.records[path] else { return }
        setRecord(nil, at: path)
        var stale = [manifest.content[path]]
        setContentKey(nil, at: path)
        if let fileID = record.fileID {
            stale.append(manifest.base[fileID])
            setBaseKey(nil, fileID: fileID)
        }
        try save(thenRemove: stale)
    }

    /// Commits the pending change by appending it to the journal, then removes blobs no
    /// longer referenced. In that order: a crash in between leaves an unreferenced blob, never a
    /// manifest pointing at a missing one. Each change costs one small journal entry; the full
    /// manifest is only rewritten every `compactionThreshold` entries.
    private func save(thenRemove stale: [String?] = []) throws {
        if !pending.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try storage.appendToJournal(try encoder.encode(pending))
            pending = Delta()
            journalLength += 1
            if journalLength >= Self.compactionThreshold { try compact() }
        }
        for key in stale.compactMap({ $0 }) { try storage.remove(key) }
    }

    /// Writes the whole manifest and clears the journal. A crash between the two replays
    /// entries the manifest already holds, which is harmless.
    private func compact() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try storage.write(try encoder.encode(manifest), for: Self.manifestKey)
        try storage.clearJournal()
        journalLength = 0
    }
}

/// Vault storage in a directory, every blob sealed. File names are random, so the directory
/// shows neither titles nor structure.
public final class SealedDiskStorage: VaultStorage {
    private let directory: URL
    private let sealer: IndexSealer

    public init(directory: URL, sealedWith sealer: IndexSealer) throws {
        self.directory = directory
        self.sealer = sealer
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        // Keys are UUIDs or "manifest"; nothing derived from a title.
        directory.appendingPathComponent(key)
    }

    public func read(_ key: String) throws -> Data? {
        guard let sealed = try? Data(contentsOf: url(key)) else { return nil }
        return try sealer.open(sealed)
    }

    public func write(_ data: Data, for key: String) throws {
        // Atomic, so a crash mid-write leaves the old version rather than a torn one.
        try sealer.seal(data).write(to: url(key), options: [.atomic])
    }

    public func remove(_ key: String) throws {
        try? FileManager.default.removeItem(at: url(key))
    }

    private var journalURL: URL { directory.appendingPathComponent("journal") }

    /// Each entry is a 4-byte big-endian length, then the sealed entry.
    public func appendToJournal(_ entry: Data) throws {
        let sealed = try sealer.seal(entry)
        var length = UInt32(sealed.count).bigEndian
        let record = Data(bytes: &length, count: 4) + sealed
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            try Data().write(to: journalURL)
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: record)
    }

    public func readJournal() throws -> [Data] {
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        var entries: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let start = offset + 4
            // Torn: the entry runs past the end, which is what a crash mid-append leaves.
            guard length > 0, start + length <= data.count else { break }
            // A complete entry that won't open is a wrong key or real corruption, not a torn
            // write: throw, and never cut the journal.
            entries.append(try sealer.open(Data(data[data.startIndex + start..<data.startIndex + start + length])))
            offset = start + length
        }
        if offset < data.count {
            // A torn tail: cut it off so the next append isn't written after garbage.
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
        }
        return entries
    }

    public func clearJournal() throws {
        try? FileManager.default.removeItem(at: journalURL)
    }
}

/// Vault storage in memory, for tests and previews.
public final class MemoryStorage: VaultStorage {
    public private(set) var blobs: [String: Data] = [:]
    public private(set) var journal: [Data] = []
    public init() {}
    public func read(_ key: String) throws -> Data? { blobs[key] }
    public func write(_ data: Data, for key: String) throws { blobs[key] = data }
    public func remove(_ key: String) throws { blobs[key] = nil }
    public func appendToJournal(_ entry: Data) throws { journal.append(entry) }
    public func readJournal() throws -> [Data] { journal }
    public func clearJournal() throws { journal = [] }
}

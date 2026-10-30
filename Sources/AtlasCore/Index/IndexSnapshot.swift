import Foundation

/// Seals and opens the index snapshot at rest. AtlasCore has no cryptography of its own
/// (root CLAUDE.md, rule 5): the app implements this with NeutrinoCrypto, using a key from the
/// user's keyring, so the index is as private as the pages it was built from.
public protocol IndexSealer {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

extension VaultIndex {
    public enum SnapshotError: Error, Equatable {
        /// Not an index snapshot.
        case notASnapshot
        /// Written by another schema version: rebuild the index from the pages.
        case schemaVersion(found: Int, expected: Int)
    }

    private static let magic = Data("ATLASIDX".utf8)

    /// The whole index as one sealed blob, to save to disk. The format is `ATLASIDX`, then the
    /// schema version as 4 big-endian bytes, then the sealed SQLite database.
    public func snapshot(sealedWith sealer: IndexSealer) throws -> Data {
        var version = UInt32(Self.schemaVersion).bigEndian
        return Self.magic + Data(bytes: &version, count: 4) + (try sealer.seal(try db.serialized()))
    }

    /// An index loaded from a snapshot. Throws `SnapshotError.schemaVersion` for a snapshot
    /// from another version, and whatever the sealer throws for one that doesn't open (wrong key
    /// or tampered with). In both cases the app rebuilds the index from the pages.
    public convenience init(snapshot: Data, sealedWith sealer: IndexSealer) throws {
        guard snapshot.count >= Self.magic.count + 4, snapshot.prefix(Self.magic.count) == Self.magic else {
            throw SnapshotError.notASnapshot
        }
        let versionBytes = snapshot.dropFirst(Self.magic.count).prefix(4)
        let version = Int(versionBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard version == Self.schemaVersion else { throw SnapshotError.schemaVersion(found: version, expected: Self.schemaVersion) }
        try self.init()
        try db.load(try sealer.open(Data(snapshot.dropFirst(Self.magic.count + 4))))
        try restoreFileSet()
    }
}

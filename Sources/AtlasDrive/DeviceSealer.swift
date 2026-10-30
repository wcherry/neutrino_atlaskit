import AtlasCore
import Foundation
import NeutrinoCrypto

/// Seals what Atlas keeps on this device (the vault's files and journal, the index snapshot)
/// with a key that never leaves it. NeutrinoCrypto's file encryption, with that key as the file
/// key: AtlasCore has no crypto of its own (root CLAUDE.md, rule 5).
///
/// The key is the app's to keep, in the Keychain under its own prefix. It is not the account's
/// keyring: losing it loses only this device's copy, which the next sync downloads again.
public struct DeviceSealer: IndexSealer {
    private let key: [UInt8]

    /// A sealer for a key from `newKey()`. Nil if the key isn't one.
    public init?(key: [UInt8]) {
        guard key.count == DriveFileCrypto.newDEK().count else { return nil }
        self.key = key
    }

    public static func newKey() -> [UInt8] { DriveFileCrypto.newDEK() }

    public func seal(_ plaintext: Data) throws -> Data {
        try DriveFileCrypto.encrypt(plaintext, dek: key)
    }

    public func open(_ sealed: Data) throws -> Data {
        try DriveFileCrypto.decrypt(sealed, dek: key)
    }
}

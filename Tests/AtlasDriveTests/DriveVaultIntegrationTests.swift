import AtlasCore
import Foundation
import NeutrinoCrypto
import XCTest
@testable import AtlasDrive

/// Against a real Neutrino server. Set `ATLAS_TEST_SERVER` (e.g. `http://localhost:8080`) to run;
/// otherwise skipped. `scripts/test-against-server.sh` builds and starts one from `../neutrino`.
/// Every test registers its own user, so they can run against a shared dev server.
final class DriveVaultIntegrationTests: XCTestCase {
    private struct Token: AccessTokenSource {
        let value: String
        func accessToken(forceRefresh: Bool) async throws -> String { value }
    }

    private struct Account {
        let baseURL: URL
        let token: Token
        var keyring: Keyring
    }

    private var server: URL!

    override func setUpWithError() throws {
        guard let url = ProcessInfo.processInfo.environment["ATLAS_TEST_SERVER"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set ATLAS_TEST_SERVER to run against a Neutrino server")
        }
        server = url
    }

    // MARK: Helpers

    private func call(_ method: String, _ path: String, token: String? = nil, json: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else {
            throw NSError(domain: "server", code: status, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func newKeyPair(version: Int) -> KeyringEntry {
        let secret = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return KeyringEntry(version: version, publicKey: KeyringCoder.publicKey(fromSecret: secret)!, secretKey: secret,
                            createdAt: ISO8601DateFormatter().string(from: Date()), retiredAt: nil)
    }

    /// A new user with a published key, as a fresh device would have after encryption setup.
    private func newAccount() async throws -> Account {
        let email = "atlas-\(UUID().uuidString.prefix(8))@example.com"
        let password = "Correct-horse-\(UUID().uuidString.prefix(6))!"
        let user = try await call("POST", "/api/v1/auth/register", json: ["email": email, "password": password, "name": "Atlas test"])
        let login = try await call("POST", "/api/v1/auth/login", json: ["email": email, "password": password])
        let token = login["accessToken"] as! String
        let key = newKeyPair(version: 1)
        let published = try await call("POST", "/api/v1/auth/keys", token: token, json: ["publicKey": Base64URL.encode(key.publicKey)])
        XCTAssertEqual(published["version"] as? Int, 1)
        return Account(baseURL: server, token: Token(value: token), keyring: Keyring(userId: user["id"] as! String, entries: [key]))
    }

    private func remote(_ account: Account, vault: String) -> DriveVaultRemote {
        DriveVaultRemote(baseURL: account.baseURL, vaultFolderID: vault, keys: account.keyring, tokens: account.token)
    }

    private func rawContent(_ account: Account, fileID: String) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent("/api/v1/drive/files/\(fileID)"))
        request.setValue("Bearer \(account.token.value)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: request).0
    }

    // MARK: The adapter

    func testRoundTripIsEncryptedAndGuarded() async throws {
        let account = try await newAccount()
        let vault = try await DriveVaultRemote.createVault(named: "Atlas test vault", baseURL: server, tokens: account.token)
        let drive = remote(account, vault: vault)

        let text = Data("# Secret roadmap\n\nThe plan.\n".utf8)
        let file = try await drive.create(at: "Projects/Q4/Roadmap.md", data: text)
        XCTAssertEqual(file.version, 1)
        let listed = try await drive.list()
        XCTAssertEqual(listed, [RemoteFile(id: file.id, path: "Projects/Q4/Roadmap.md", version: 1)])

        // A second client with only the keyring reads it back.
        let other = remote(account, vault: vault)
        _ = try await other.list()
        let (downloaded, version) = try await other.download(file.id)
        XCTAssertEqual(downloaded, text)
        XCTAssertEqual(version, 1)

        // The server holds ciphertext.
        let stored = try await rawContent(account, fileID: file.id)
        XCTAssertNil(stored.range(of: Data("Secret".utf8)))
        XCTAssertNotEqual(stored, text)

        // Guarded writes.
        let replaced = try await drive.replace(file.id, data: Data("v2\n".utf8), expectedVersion: 1)
        XCTAssertEqual(replaced, 2)
        do {
            _ = try await other.replace(file.id, data: Data("stale\n".utf8), expectedVersion: 1)
            XCTFail("a stale write must be rejected")
        } catch VaultRemoteError.conflict {}
        let current = try await other.download(file.id)
        XCTAssertEqual(current.data, Data("v2\n".utf8))

        // Move into a folder that doesn't exist yet, then delete.
        try await drive.move(file.id, to: "Archive/Roadmap 2026.md")
        let moved = try await other.list()
        XCTAssertEqual(moved.map(\.path), ["Archive/Roadmap 2026.md"])
        try await drive.delete(file.id)
        let empty = try await other.list()
        XCTAssertEqual(empty, [])
    }

    func testKeyRotationKeepsOldFilesReadable() async throws {
        var account = try await newAccount()
        let vault = try await DriveVaultRemote.createVault(named: "Rotation", baseURL: server, tokens: account.token)
        let old = try await remote(account, vault: vault).create(at: "Old.md", data: Data("sealed to v1\n".utf8))

        // Rotate: publish v2, retire v1.
        let v1 = account.keyring.entries[0]
        let v2 = newKeyPair(version: 2)
        let published = try await call("POST", "/api/v1/auth/keys", token: account.token.value, json: ["publicKey": Base64URL.encode(v2.publicKey)])
        XCTAssertEqual(published["version"] as? Int, 2)
        let retired = KeyringEntry(version: 1, publicKey: v1.publicKey, secretKey: v1.secretKey, createdAt: v1.createdAt, retiredAt: v2.createdAt)
        account.keyring = Keyring(userId: account.keyring.userId, entries: [retired, v2])

        let drive = remote(account, vault: vault)
        let oldContent = try await drive.download(old.id)
        XCTAssertEqual(oldContent.data, Data("sealed to v1\n".utf8))
        let new = try await drive.create(at: "New.md", data: Data("sealed to v2\n".utf8))
        let key = try await call("GET", "/api/v1/drive/files/\(new.id)/key", token: account.token.value)
        XCTAssertEqual(key["keyVersion"] as? Int, 2)
        let newContent = try await remote(account, vault: vault).download(new.id)
        XCTAssertEqual(newContent.data, Data("sealed to v2\n".utf8))
    }

    // MARK: Sync over the real server

    func testTwoDevicesSyncThroughDrive() async throws {
        let account = try await newAccount()
        let vaultID = try await DriveVaultRemote.createVault(named: "Two devices", baseURL: server, tokens: account.token)
        let a = VaultSync(vault: try Vault(storage: MemoryStorage()), remote: remote(account, vault: vaultID))
        let b = VaultSync(vault: try Vault(storage: MemoryStorage()), remote: remote(account, vault: vaultID))

        try a.vault.write(text: "# Plan\n\nOne\nTwo\nThree\n", at: "Plan.md")
        try a.vault.write(text: "Gone soon\n", at: "Inbox/Scratch.md")
        try a.vault.write(Data([0, 1, 2, 255]), at: "Attachments/diagram.png")
        try await a.sync()
        let pulled = try await b.sync()
        XCTAssertEqual(Set(pulled.updated), ["Plan.md", "Inbox/Scratch.md", "Attachments/diagram.png"])
        XCTAssertEqual(try b.vault.content(at: "Attachments/diagram.png"), Data([0, 1, 2, 255]))

        // Edits to different lines merge through a real 409.
        try a.vault.write(text: "# Plan\n\nOne (A)\nTwo\nThree\n", at: "Plan.md")
        try b.vault.write(text: "# Plan\n\nOne\nTwo\nThree (B)\n", at: "Plan.md")
        try await a.sync()
        let merged = try await b.sync()
        XCTAssertEqual(merged.merged, ["Plan.md"])
        try await a.sync()
        XCTAssertEqual(try a.vault.text(at: "Plan.md"), "# Plan\n\nOne (A)\nTwo\nThree (B)\n")

        // A clash keeps both; a move and a delete propagate.
        try a.vault.write(text: "# Plan\n\nOne by A\nTwo\nThree (B)\n", at: "Plan.md")
        try b.vault.write(text: "# Plan\n\nOne by B\nTwo\nThree (B)\n", at: "Plan.md")
        try a.vault.move(from: "Plan.md", to: "Projects/Plan.md")
        try a.vault.delete(at: "Inbox/Scratch.md")
        try await a.sync()
        let clash = try await b.sync()
        XCTAssertEqual(clash.conflicts.count, 1)
        XCTAssertEqual(clash.removed, ["Inbox/Scratch.md"])
        try await a.sync()
        try await b.sync()

        let pathsA = a.vault.paths, pathsB = b.vault.paths
        XCTAssertEqual(pathsA, pathsB)
        XCTAssertTrue(pathsA.contains("Projects/Plan.md"))
        XCTAssertFalse(pathsA.contains("Inbox/Scratch.md"))
        let texts = try pathsA.compactMap { try a.vault.text(at: $0) }
        XCTAssertTrue(texts.contains { $0.contains("One by A") })
        XCTAssertTrue(texts.contains { $0.contains("One by B") })
        let quietA = try await a.sync(), quietB = try await b.sync()
        XCTAssertEqual(quietA, SyncReport())
        XCTAssertEqual(quietB, SyncReport())
    }

    /// Random edits and syncs on two devices, end to end. Kept short: it's a real server.
    func testRandomEditsConvergeOverTheRealServer() async throws {
        let account = try await newAccount()
        let vaultID = try await DriveVaultRemote.createVault(named: "Random", baseURL: server, tokens: account.token)
        let devices = try (0..<2).map { _ in VaultSync(vault: try Vault(storage: MemoryStorage()), remote: remote(account, vault: vaultID)) }
        var rng = SystemRandomNumberGenerator()
        var token = 0
        for _ in 0..<40 {
            let d = devices.randomElement(using: &rng)!
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                token += 1
                if d.vault.record(at: "Page \(token % 5).md") == nil { try d.vault.write(text: "t\(token)\n", at: "Page \(token % 5).md") }
            case 1, 2:
                guard let path = d.vault.paths.randomElement(using: &rng) else { continue }
                token += 1
                try d.vault.write(text: (try d.vault.text(at: path) ?? "") + "t\(token)\n", at: path)
            case 3:
                guard let path = d.vault.paths.randomElement(using: &rng) else { continue }
                try d.vault.move(from: path, to: "Folder \(Int.random(in: 0..<2, using: &rng))/\((path as NSString).lastPathComponent)")
            default:
                try await d.sync()
            }
        }
        for _ in 0..<4 { for d in devices { try await d.sync() } }
        let contents = try devices.map { d in Dictionary(uniqueKeysWithValues: try d.vault.paths.map { ($0, try d.vault.text(at: $0) ?? "") }) }
        XCTAssertEqual(contents[0], contents[1])
        let server = try await remote(account, vault: vaultID).list()
        XCTAssertEqual(Set(server.map(\.path)), Set(contents[0].keys))
        for d in devices {
            let report = try await d.sync()
            XCTAssertEqual(report, SyncReport())
        }
    }
}

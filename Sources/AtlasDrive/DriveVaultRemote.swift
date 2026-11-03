import AtlasCore
import Foundation
import NeutrinoCore
import NeutrinoCrypto

/// The user's key pairs: the active one to seal new files' keys to, and older versions to open
/// files sealed before a rotation.
///
/// A `Keyring` is one: the app reads it from `KeyringStore` (which is main-actor isolated) and
/// hands sync this immutable snapshot, so sync never touches the Keychain. After a key rotation,
/// make a new remote with the new keyring.
public protocol VaultKeys: Sendable {
    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)?
    func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8])
    /// Every key pair held, for a file key filed under the wrong version (`HTTP.openFileKey`).
    var allKeyPairs: [(version: Int, publicKey: [UInt8], secretKey: [UInt8])] { get }
}

extension Keyring: VaultKeys {
    public var allKeyPairs: [(version: Int, publicKey: [UInt8], secretKey: [UInt8])] {
        entries.map { ($0.version, $0.publicKey, $0.secretKey) }
    }

    public func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        active.map { ($0.publicKey, $0.secretKey, $0.version) }
    }

    public func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard let entry = entry(forVersion: version) else { throw KeyringError.missingVersion(version) }
        return (entry.publicKey, entry.secretKey)
    }
}

/// A bearer token for the Neutrino API. The app backs this with `AuthService`; `forceRefresh`
/// is set after a 401.
public protocol AccessTokenSource {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public enum DriveVaultError: Error, Equatable {
    /// The account has no key pair on this device: set up encryption first.
    case noActiveKey
    /// The server answered with an unexpected status.
    case http(status: Int, code: String?)
    /// A response that doesn't parse as expected.
    case badResponse(String)
    /// A file's key opens with none of the account's keys held here: it was sealed to a key this
    /// device doesn't have.
    case unreadableKey(file: String, keyVersion: Int)
}

/// A vault on Neutrino Drive (SPEC-free: this is transport). The vault is a Drive folder; its
/// subfolders and files mirror the vault's paths with real names (neutrino-atlas.md,
/// constraint 1). Every file's content is end-to-end encrypted with NeutrinoCrypto, exactly as
/// Drive's other clients do it:
/// - a fresh DEK per file, sealed to the account's active public key (`PUT /files/{id}/key`
///   semantics, sent with the upload);
/// - content encrypted with the DEK;
/// - `encrypted_metadata` holding the name and MIME type.
///
/// Writes are guarded by `content_version` (`?expectedContentVersion=`): a 409 becomes
/// `VaultRemoteError.conflict` for `VaultSync` to merge.
///
/// Not thread-safe: use from the actor that runs sync.
public final class DriveVaultRemote: VaultRemote {
    public let baseURL: URL
    public let vaultFolderID: String
    private let keys: VaultKeys
    private let tokens: AccessTokenSource
    private let session: URLSession

    /// Folder ids by vault path; "" is the vault folder itself.
    private var folderIDs: [String: String]
    /// Folders whose child folders have been listed, so `ensureFolder` doesn't create a duplicate.
    private var listedFolders: Set<String> = []
    /// File names by id, which autosave needs.
    private var names: [String: String] = [:]
    /// Opened DEKs by file id.
    private var deks: [String: [UInt8]] = [:]

    public init(baseURL: URL, vaultFolderID: String, keys: VaultKeys, tokens: AccessTokenSource, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.vaultFolderID = vaultFolderID
        self.keys = keys
        self.tokens = tokens
        self.session = session
        self.folderIDs = ["": vaultFolderID]
    }

    /// Creates a vault: a new folder in the root of the user's Drive.
    public static func createVault(named name: String, baseURL: URL, tokens: AccessTokenSource, session: URLSession = .shared) async throws -> String {
        let http = HTTP(baseURL: baseURL, tokens: tokens, session: session)
        let folder: FolderDTO = try await http.json("POST", "/api/v1/drive/folders", body: ["name": name])
        return folder.id
    }

    /// The folders at the root of the user's Drive: where a vault can be chosen from. The root
    /// has no id of its own; the user's id addresses it.
    public static func rootFolders(userID: String, baseURL: URL, tokens: AccessTokenSource, session: URLSession = .shared) async throws -> [(id: String, name: String)] {
        let http = HTTP(baseURL: baseURL, tokens: tokens, session: session)
        let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(userID)")
        return contents.folders.map { ($0.id, $0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var http: HTTP { HTTP(baseURL: baseURL, tokens: tokens, session: session) }

    // MARK: - VaultRemote

    public func list() async throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        var queue: [(id: String, path: String)] = [(vaultFolderID, "")]
        folderIDs = ["": vaultFolderID]
        listedFolders = []
        while !queue.isEmpty {
            let (id, path) = queue.removeFirst()
            let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(id)")
            listedFolders.insert(path)
            for folder in contents.folders {
                let childPath = Self.join(path, folder.name)
                folderIDs[childPath] = folder.id
                queue.append((folder.id, childPath))
            }
            for file in contents.files {
                names[file.id] = file.name
                files.append(RemoteFile(id: file.id, path: Self.join(path, file.name), version: file.contentVersion))
            }
        }
        return files
    }

    public func download(_ id: String) async throws -> (data: Data, version: Int) {
        // The version is read before and after the content: a write landing in between would pair
        // new bytes with an old version, so retry until both agree.
        for _ in 0..<3 {
            let before: FileInfoDTO = try await http.json("GET", "/api/v1/drive/files/\(id)/info")
            names[id] = before.name
            let dek: [UInt8]
            do { dek = try await self.dek(for: id) } catch DriveVaultError.unreadableKey { throw VaultRemoteError.unreadable }
            let ciphertext = try await http.data("GET", "/api/v1/drive/files/\(id)")
            let after: FileInfoDTO = try await http.json("GET", "/api/v1/drive/files/\(id)/info")
            guard before.contentVersion == after.contentVersion else { continue }
            names[id] = after.name
            do {
                let chunkSize = try after.encryptedMetadata.map { try DriveFileCrypto.decryptMetadata($0, dek: dek).chunkSize } ?? nil
                return (try DriveFileCrypto.decrypt(ciphertext, dek: dek, chunkSize: chunkSize), after.contentVersion)
            } catch let error as DriveFileCryptoError {
                AtlasLog.drive.error("\(after.name) (\(id)): its key opens but its content doesn't decrypt (\(String(describing: error)))")
                throw VaultRemoteError.unreadable
            }
        }
        throw VaultRemoteError.conflict
    }

    public func create(at path: String, data: Data) async throws -> RemoteFile {
        guard let active = keys.activeKeyPair() else { throw DriveVaultError.noActiveKey }
        let (parent, name) = Self.split(path)
        let folderID = try await ensureFolder(parent)
        let dek = DriveFileCrypto.newDEK()
        let mime = Self.mimeType(for: name)
        var form = MultipartFormBody()
        form.appendField(name: "folder_id", value: folderID)
        form.appendField(name: "encrypted_metadata", value: try DriveFileCrypto.encryptMetadata(.init(name: name, mimeType: mime), dek: dek))
        form.appendField(name: "mime_type", value: mime)
        form.appendField(name: "encrypted_file_key", value: try DriveFileCrypto.seal(dek: dek, toPublicKey: active.publicKey))
        form.appendField(name: "key_version", value: String(active.version))
        form.appendFile(name: "file", fileName: name, mimeType: "application/octet-stream", data: try DriveFileCrypto.encrypt(data, dek: dek))
        let file: FileDTO = try await http.json("POST", "/api/v1/drive/files/upload", multipart: form)
        deks[file.id] = dek
        names[file.id] = name
        return RemoteFile(id: file.id, path: path, version: file.contentVersion)
    }

    public func replace(_ id: String, data: Data, expectedVersion: Int) async throws -> Int {
        let dek = try await dek(for: id)
        var form = MultipartFormBody()
        // No `metadata` part: autosave would apply its title as a rename, and the name is managed
        // by `move`.
        form.appendFile(name: "file", fileName: names[id] ?? "file", mimeType: "application/octet-stream",
                        data: try DriveFileCrypto.encrypt(data, dek: dek))
        let file: FileDTO = try await http.json("PUT", "/api/v1/drive/files/\(id)/autosave",
                                                 query: [URLQueryItem(name: "expectedContentVersion", value: String(expectedVersion))],
                                                 multipart: form)
        return file.contentVersion
    }

    public func move(_ id: String, to path: String) async throws {
        let (parent, name) = Self.split(path)
        let folderID = try await ensureFolder(parent)
        let _: FileDTO = try await http.json("PATCH", "/api/v1/drive/files/\(id)", body: ["name": name, "folderId": folderID])
        names[id] = name
    }

    public func delete(_ id: String) async throws {
        try await http.empty("DELETE", "/api/v1/drive/files/\(id)")
        deks[id] = nil
        names[id] = nil
    }

    // MARK: - Keys and folders

    private func dek(for id: String) async throws -> [UInt8] {
        if let cached = deks[id] { return cached }
        let dek = try await http.openFileKey(of: id, named: names[id], keys: keys)
        deks[id] = dek
        return dek
    }

    /// The id of the folder at vault path `path`, creating it and any parents that don't exist.
    private func ensureFolder(_ path: String) async throws -> String {
        if let id = folderIDs[path] { return id }
        let (parentPath, name) = Self.split(path)
        let parentID = try await ensureFolder(parentPath)
        if !listedFolders.contains(parentPath) {
            let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(parentID)")
            listedFolders.insert(parentPath)
            for folder in contents.folders { folderIDs[Self.join(parentPath, folder.name)] = folder.id }
            if let id = folderIDs[path] { return id }
        }
        let folder: FolderDTO = try await http.json("POST", "/api/v1/drive/folders", body: ["name": name, "parentId": parentID])
        folderIDs[path] = folder.id
        listedFolders.insert(path)  // brand new: no children
        return folder.id
    }

    // MARK: - Paths

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    /// `("Folder/Sub", "Page.md")` for `Folder/Sub/Page.md`; the parent is "" at the vault root.
    static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md": return "text/markdown"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "json", "canvas": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - HTTP

/// The few requests the adapter (and `NeutrinoNotes`) makes. Statuses map onto `VaultRemoteError` where sync cares
/// (409 is a lost race, 404 a file gone elsewhere); a 401 retries once with a fresh token.
struct HTTP {
    let baseURL: URL
    let tokens: AccessTokenSource
    let session: URLSession

    func json<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                            multipart: MultipartFormBody? = nil) async throws -> T {
        let data = try await send(method, path, query: query, body: body, multipart: multipart)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DriveVaultError.badResponse("\(method) \(path): \(error)") }
    }

    func data(_ method: String, _ path: String) async throws -> Data {
        try await send(method, path)
    }

    func empty(_ method: String, _ path: String) async throws {
        _ = try await send(method, path)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                      multipart: MultipartFormBody? = nil, retried: Bool = false) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let multipart {
            request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = multipart.finalized()
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AtlasLog.drive.error("\(method) \(path): \(error.localizedDescription)")
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            AtlasLog.drive.info("\(method) \(path) → \(status) (\(data.count) bytes)")
        } else {
            AtlasLog.drive.error("\(method) \(path) → \(status)\(retried ? " (retried)" : "")")
        }
        switch status {
        case 200..<300: return data
        case 401 where !retried: return try await send(method, path, query: query, body: body, multipart: multipart, retried: true)
        case 404: throw VaultRemoteError.notFound
        case 409: throw VaultRemoteError.conflict
        default:
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code
            throw DriveVaultError.http(status: status, code: code)
        }
    }
}

extension HTTP {
    /// A file's DEK, from the key Drive keeps sealed to the account. The version the key is filed
    /// under is tried first, then every other key held, newest first: iOS apps that unlocked from
    /// the key vault filed keys sealed to the active key as v1 on rotated accounts, which only that
    /// version's key can't open (the web client and NeutrinoShared's `openSealedDEK` do the same).
    /// A misfiled key is filed again under the version that opened it, so the next reader goes
    /// straight there. Throws `DriveVaultError.unreadableKey` when nothing held opens it.
    func openFileKey(of id: String, named name: String? = nil, keys: VaultKeys) async throws -> [UInt8] {
        let key: FileKeyDTO = try await json("GET", "/api/v1/drive/files/\(id)/key")
        let held = keys.allKeyPairs
        let order = held.filter { $0.version == key.keyVersion } + held.filter { $0.version != key.keyVersion }.sorted { $0.version > $1.version }
        for pair in order {
            guard let dek = try? DriveFileCrypto.openDEK(key.encryptedFileKey, publicKey: pair.publicKey, secretKey: pair.secretKey) else { continue }
            if pair.version != key.keyVersion {
                AtlasLog.drive.notice("Key for \(name ?? id) is filed as v\(key.keyVersion) but sealed to v\(pair.version): filing it as v\(pair.version)")
                do {
                    let _: FileKeyDTO = try await json("PUT", "/api/v1/drive/files/\(id)/key",
                                                       body: ["encryptedFileKey": key.encryptedFileKey, "keyVersion": pair.version])
                } catch {
                    // Reading goes on: the next reader just tries the keys again.
                    AtlasLog.drive.notice("Couldn't re-file the key for \(name ?? id): \(String(describing: error))")
                }
            }
            return dek
        }
        AtlasLog.drive.error("Key for \(name ?? id) (\(id)) opens with none of the \(held.count) key(s) held (versions \(held.map { String($0.version) }.joined(separator: ", "))); it's filed as v\(key.keyVersion)")
        throw DriveVaultError.unreadableKey(file: name ?? id, keyVersion: key.keyVersion)
    }
}

struct ErrorEnvelope: Decodable { struct Body: Decodable { let code: String? }; let error: Body }
struct FolderDTO: Decodable { let id: String; let name: String }
struct FileDTO: Decodable { let id: String; let name: String; let contentVersion: Int; let encryptedMetadata: String?; var mimeType: String? }
struct FolderContentsDTO: Decodable { let folders: [FolderDTO]; let files: [FileDTO] }
struct FileInfoDTO: Decodable {
    let name: String
    let contentVersion: Int
    let encryptedMetadata: String?
    var mimeType: String?
    var sizeBytes: Int?
    /// A path on the server, when the file has a cover thumbnail.
    var coverThumbnailUrl: String?
}
struct FileKeyDTO: Decodable { let encryptedFileKey: String; let keyVersion: Int }

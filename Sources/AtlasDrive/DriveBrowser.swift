import AtlasCore
import Foundation
import NeutrinoCore
import NeutrinoCrypto

/// Browses the user's Drive for images to put in a page (roadmap Phase 1, "images, file
/// attachments"), and reads the one picked. A picked image is copied into the vault, where sync
/// encrypts and uploads it as an attachment; nothing here writes to Drive or to disk.
public struct DriveBrowser {
    public let baseURL: URL
    private let keys: VaultKeys
    private let tokens: AccessTokenSource
    private let session: URLSession

    public init(baseURL: URL, keys: VaultKeys, tokens: AccessTokenSource, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.keys = keys
        self.tokens = tokens
        self.session = session
    }

    private var http: HTTP { HTTP(baseURL: baseURL, tokens: tokens, session: session) }

    public enum BrowseError: Error, Equatable {
        /// The file opened with neither reading: ciphertext this account's keys can't open.
        case unreadable(name: String)
    }

    /// A folder or an image in a Drive folder. Names are file names, which Drive keeps in plaintext.
    public struct Item: Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var isFolder: Bool

        public init(id: String, name: String, isFolder: Bool) {
            self.id = id
            self.name = name
            self.isFolder = isFolder
        }
    }

    /// The folders and images in a folder, folders first, each in Finder's order. The Drive's
    /// root folder's id is the user's id. Folders in `excluding` (the vault) are left out.
    public func images(in folderID: String, excluding: Set<String> = []) async throws -> [Item] {
        let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(folderID)",
                                                               query: [URLQueryItem(name: "type", value: "photo")])
        func byName(_ a: Item, _ b: Item) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let folders = contents.folders.filter { !excluding.contains($0.id) }.map { Item(id: $0.id, name: $0.name, isFolder: true) }
        let files = contents.files.map { Item(id: $0.id, name: $0.name, isFolder: false) }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// An image's bytes, decrypted in memory.
    public func read(_ item: Item) async throws -> Data {
        let content = try await http.driveContent(of: item.id, keys: keys)
        guard let dek = content.dek else { return content.stored }  // never encrypted
        if let body = try? DriveFileCrypto.decrypt(content.stored, dek: dek, chunkSize: content.chunkSize) { return body }
        if let text = String(data: content.stored, encoding: .utf8),
           let sealed = Data(base64URLEncoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let body = try? DriveFileCrypto.decrypt(sealed, dek: dek, chunkSize: content.chunkSize) {
            return body
        }
        throw BrowseError.unreadable(name: item.name)
    }
}

extension HTTP {
    /// A Drive file's stored bytes, with the key that opens them: nil for a file that has none,
    /// because it was never encrypted. `chunkSize` is from its encrypted metadata, for content
    /// encrypted in chunks (large uploads).
    func driveContent(of id: String, keys: VaultKeys) async throws -> (stored: Data, dek: [UInt8]?, chunkSize: Int?) {
        let stored = try await data("GET", "/api/v1/drive/files/\(id)")
        guard !stored.isEmpty else { return (stored, nil, nil) }
        let dek: [UInt8]
        do {
            dek = try await openFileKey(of: id, keys: keys)
        } catch VaultRemoteError.notFound {
            return (stored, nil, nil)
        }
        let info: FileInfoDTO? = try? await json("GET", "/api/v1/drive/files/\(id)/info")
        let chunkSize = info?.encryptedMetadata.flatMap { try? DriveFileCrypto.decryptMetadata($0, dek: dek).chunkSize } ?? nil
        return (stored, dek, chunkSize)
    }
}

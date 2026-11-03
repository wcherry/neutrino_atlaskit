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

    /// A folder or a file in a Drive folder. Names are file names, which Drive keeps in plaintext.
    public struct Item: Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var isFolder: Bool
        /// A file's type, as Drive has it: what it opens in (`NeutrinoAppLink.kind(forMIME:)`).
        public var mimeType: String?

        public init(id: String, name: String, isFolder: Bool, mimeType: String? = nil) {
            self.id = id
            self.name = name
            self.isFolder = isFolder
            self.mimeType = mimeType
        }
    }

    /// The folders and images in a folder, folders first, each in Finder's order. The Drive's
    /// root folder's id is the user's id. Folders in `excluding` (the vault) are left out.
    public func images(in folderID: String, excluding: Set<String> = []) async throws -> [Item] {
        try await contents(of: folderID, type: "photo", excluding: excluding)
    }

    /// The folders and files of every kind in a folder, the same way: for linking to them.
    public func files(in folderID: String, excluding: Set<String> = []) async throws -> [Item] {
        try await contents(of: folderID, type: nil, excluding: excluding)
    }

    private func contents(of folderID: String, type: String?, excluding: Set<String>) async throws -> [Item] {
        let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(folderID)",
                                                               query: type.map { [URLQueryItem(name: "type", value: $0)] } ?? [])
        func byName(_ a: Item, _ b: Item) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let folders = contents.folders.filter { !excluding.contains($0.id) }.map { Item(id: $0.id, name: $0.name, isFolder: true) }
        let files = contents.files.map { Item(id: $0.id, name: $0.name, isFolder: false, mimeType: $0.mimeType) }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// The largest image read whole to preview it, when it has no thumbnail.
    public static let largestPreviewRead = 25_000_000

    /// A picture of a file to show for a link to it (Show as Preview): its Drive cover thumbnail
    /// (an image or video's, made by the client that uploaded it), else for an image no bigger
    /// than `largestPreviewRead` the image itself, decrypted in memory. Nil for a file with
    /// neither, such as a document: the link shows as a chip.
    public func preview(of fileID: String) async throws -> Data? {
        let info: FileInfoDTO = try await http.json("GET", "/api/v1/drive/files/\(fileID)/info")
        if info.coverThumbnailUrl != nil {
            do {
                return try await http.data("GET", "/api/v1/drive/files/\(fileID)/thumbnail")
            } catch VaultRemoteError.notFound {
                // Listed but gone: fall through.
            }
        }
        guard info.mimeType?.lowercased().hasPrefix("image/") == true, (info.sizeBytes ?? 0) <= Self.largestPreviewRead else { return nil }
        return try await read(Item(id: fileID, name: info.name, isFolder: false, mimeType: info.mimeType))
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

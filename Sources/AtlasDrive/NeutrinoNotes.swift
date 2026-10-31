import AtlasCore
import Foundation
import NeutrinoCore
import NeutrinoCrypto

/// Reads the user's Neutrino Notes for import into a vault (roadmap Phase 1, "Import / export").
///
/// A note is a Drive file with the `text/markdown` type, named by its title, anywhere in the
/// user's Drive; its body is Markdown. `snapshot()` walks the Drive from its root with
/// `?type=note` (folders are listed whatever their contents), reads and decrypts every note, and
/// returns them at their Drive paths for `VaultWorkspace.importFiles`. Nothing is written to
/// Drive or to disk.
///
/// Bodies are read the way the web editor reads them: the DEK sealed to the account opens the
/// content, whether it was saved as raw ciphertext or, by an older client, as its base64url text.
/// A note with no key, or whose stored bytes are plain note text despite a key (it predates
/// encryption and hasn't been saved since), is read as it is.
public struct NeutrinoNotes {
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

    public enum NotesError: Error, Equatable {
        /// A note's body opened with neither reading: ciphertext this account's keys can't open.
        case unreadable(path: String)
    }

    /// One note found in Drive.
    public struct Note: Equatable, Sendable {
        public var id: String
        /// Its Drive folders and title, as a page path (`Folder/Title.md`).
        public var path: String
    }

    /// Every note in the Drive rooted at `userID`, by Drive path, leaving out the folders in
    /// `excluding` and everything under them: the vault itself, whose pages are Markdown too.
    public func list(userID: String, excluding: Set<String> = []) async throws -> [Note] {
        var notes: [Note] = []
        var queue: [(id: String, path: String)] = [(userID, "")]
        while !queue.isEmpty {
            let (id, path) = queue.removeFirst()
            let contents: FolderContentsDTO = try await http.json("GET", "/api/v1/drive/folders/\(id)",
                                                                   query: [URLQueryItem(name: "type", value: "note")])
            for folder in contents.folders where !excluding.contains(folder.id) {
                queue.append((folder.id, Self.join(path, Self.clean(folder.name))))
            }
            for file in contents.files where file.mimeType.map({ NeutrinoAppLink.kind(forMIME: $0) == .note }) ?? true {
                notes.append(Note(id: file.id, path: Self.join(path, Self.pageName(file.name))))
            }
        }
        return notes.sorted { $0.path < $1.path }
    }

    /// A note's body, decrypted.
    public func read(_ note: Note) async throws -> Data {
        let stored = try await http.data("GET", "/api/v1/drive/files/\(note.id)")
        guard !stored.isEmpty else { return stored }
        let dek: [UInt8]
        do {
            let key: FileKeyDTO = try await http.json("GET", "/api/v1/drive/files/\(note.id)/key")
            let pair = try keys.keyPair(forVersion: key.keyVersion)
            dek = try DriveFileCrypto.openDEK(key.encryptedFileKey, publicKey: pair.publicKey, secretKey: pair.secretKey)
        } catch VaultRemoteError.notFound {
            return stored  // never encrypted
        }
        let info: FileInfoDTO? = try? await http.json("GET", "/api/v1/drive/files/\(note.id)/info")
        let chunkSize = info?.encryptedMetadata.flatMap { try? DriveFileCrypto.decryptMetadata($0, dek: dek).chunkSize } ?? nil
        if let text = String(data: stored, encoding: .utf8), let sealed = Data(base64URLEncoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let body = try? DriveFileCrypto.decrypt(sealed, dek: dek, chunkSize: chunkSize) {
            return body
        }
        if let body = try? DriveFileCrypto.decrypt(stored, dek: dek, chunkSize: chunkSize) { return body }
        guard Self.looksLikeNoteText(stored) else { throw NotesError.unreadable(path: note.path) }
        return stored
    }

    /// Every note, read, as a folder snapshot to import. `progress` is called after each note
    /// with how many are done and how many there are.
    public func snapshot(userID: String, excluding: Set<String> = [], progress: ((Int, Int) -> Void)? = nil) async throws -> FolderSnapshot {
        let notes = try await list(userID: userID, excluding: excluding)
        var files: [(path: String, data: Data)] = []
        for (i, note) in notes.enumerated() {
            files.append((note.path, try await read(note)))
            progress?(i + 1, notes.count)
        }
        return FolderSnapshot(files: files, tooLarge: [])
    }

    // MARK: - Names

    /// A note's file name: its title plus `.md`, unless it already ends in `.md`.
    static func pageName(_ name: String) -> String {
        let clean = clean(name)
        let title = clean.isEmpty ? "Untitled note" : clean
        return title.lowercased().hasSuffix(".md") ? title : title + ".md"
    }

    /// A Drive name as a path segment: no `/`, and not hidden (a leading `.` would keep it out
    /// of an export and an Obsidian vault).
    static func clean(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    /// Plain note text: UTF-8 with no control characters but tab and line breaks. Ciphertext
    /// that fails to open almost never passes, which is what makes showing it safe.
    static func looksLikeNoteText(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !text.unicodeScalars.contains { $0.properties.generalCategory == .control && !"\t\n\r".unicodeScalars.contains($0) }
    }
}

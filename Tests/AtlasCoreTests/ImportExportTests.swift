import Foundation
import XCTest
@testable import AtlasCore

@MainActor
final class ImportExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// An Obsidian vault: pages in folders, an attachment, settings and trash that stay behind,
    /// and a link out of the folder that isn't followed.
    private func obsidianVault() throws -> URL {
        let vault = root.appendingPathComponent("My Vault")
        if FileManager.default.fileExists(atPath: vault.path) { return vault }
        try put("Home.md", "# Home\r\n\r\nSee [[Plan]] and ![[diagram.png]] and [[Missing]].\r\n", in: vault)
        try put("Projects/Plan.md", "---\naliases: [Roadmap]\n---\n- [ ] ship #work\n", in: vault)
        try put("attachments/diagram.png", "\u{89}PNG", in: vault)
        try put(".obsidian/app.json", "{}", in: vault)
        try put(".trash/Old.md", "old", in: vault)
        try put("outside.md", "secret", in: root)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("outside.md"))
        return vault
    }

    func testReadingAnObsidianVault() throws {
        let snapshot = try FolderSnapshot.read(try obsidianVault())
        XCTAssertEqual(snapshot.files.map(\.path), ["Home.md", "Projects/Plan.md", "attachments/diagram.png"])
        XCTAssertEqual(snapshot.files[0].data, Data("# Home\r\n\r\nSee [[Plan]] and ![[diagram.png]] and [[Missing]].\r\n".utf8), "bytes as they are")
    }

    func testImportKeepsBytesResolvesLinksAndNeverOverwrites() throws {
        let w = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        try w.write(text: "mine\n", at: "Home.md")
        var changes = 0
        w.onChange = { _ in changes += 1 }
        let report = try w.importFiles(try FolderSnapshot.read(try obsidianVault()))
        XCTAssertEqual(changes, 1, "one notice for the import")
        XCTAssertEqual(report.imported, ["Home (imported).md", "Projects/Plan.md", "attachments/diagram.png"])
        XCTAssertEqual(report.renamed, ["Home.md": "Home (imported).md"])
        XCTAssertEqual(try w.text(at: "Home.md"), "mine\n")
        XCTAssertEqual(try w.text(at: "Home (imported).md"), "# Home\r\n\r\nSee [[Plan]] and ![[diagram.png]] and [[Missing]].\r\n")
        XCTAssertEqual(try w.index.backlinks(to: "Projects/Plan.md").map(\.source), ["Home (imported).md"])
        XCTAssertEqual(try w.index.backlinks(to: "attachments/diagram.png").map(\.source), ["Home (imported).md"])
        XCTAssertEqual(try w.index.quickSwitch("roadmap").first?.path, "Projects/Plan.md", "aliases from frontmatter")
        XCTAssertEqual(report.unresolvedLinks.map(\.target), ["Missing"])

        // Importing again changes nothing.
        let again = try w.importFiles(try FolderSnapshot.read(try obsidianVault()))
        XCTAssertEqual(again.imported, [])
        XCTAssertEqual(Set(again.unchanged), ["Home (imported).md", "Projects/Plan.md", "attachments/diagram.png"])
    }

    func testImportIntoAFolder() throws {
        let w = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        let report = try w.importFiles(try FolderSnapshot.read(try obsidianVault()), into: "Obsidian")
        XCTAssertEqual(report.imported.first, "Obsidian/Home.md")
        XCTAssertEqual(try w.index.backlinks(to: "Obsidian/Projects/Plan.md").map(\.source), ["Obsidian/Home.md"], "links resolve by name, wherever the vault lands")
    }

    func testExportIsTheVaultAsFilesAndImportsBackTheSame() throws {
        let w = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        _ = try w.importFiles(try FolderSnapshot.read(try obsidianVault()))
        let out = root.appendingPathComponent("Export")
        try w.exportFiles().write(to: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Projects/Plan.md"), encoding: .utf8), "---\naliases: [Roadmap]\n---\n- [ ] ship #work\n")
        XCTAssertThrowsError(try w.exportFiles().write(to: out), "never into a folder with files in it")

        let back = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        _ = try back.importFiles(try FolderSnapshot.read(out))
        XCTAssertEqual(back.paths, w.paths)
        for path in w.paths { XCTAssertEqual(try back.content(at: path), try w.content(at: path)) }
    }

    func testTooLargeFilesAreLeftOut() throws {
        let vault = root.appendingPathComponent("Big")
        try put("Small.md", "ok", in: vault)
        let big = vault.appendingPathComponent("movie.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FolderSnapshot.maxFileSize + 1))
        try handle.close()
        let snapshot = try FolderSnapshot.read(vault)
        XCTAssertEqual(snapshot.files.map(\.path), ["Small.md"])
        XCTAssertEqual(snapshot.tooLarge, ["movie.mov"])
    }
}

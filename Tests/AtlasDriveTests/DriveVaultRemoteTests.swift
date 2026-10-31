import XCTest
@testable import AtlasDrive

final class DriveVaultRemoteTests: XCTestCase {
    func testPaths() {
        XCTAssertEqual(DriveVaultRemote.split("Page.md").parent, "")
        XCTAssertEqual(DriveVaultRemote.split("A/B/Page.md").parent, "A/B")
        XCTAssertEqual(DriveVaultRemote.split("A/B/Page.md").name, "Page.md")
        XCTAssertEqual(DriveVaultRemote.join("", "Page.md"), "Page.md")
        XCTAssertEqual(DriveVaultRemote.join("A", "Page.md"), "A/Page.md")
        XCTAssertEqual(DriveVaultRemote.mimeType(for: "Note.MD"), "text/markdown")
        XCTAssertEqual(DriveVaultRemote.mimeType(for: "x.bin"), "application/octet-stream")
    }

    func testNoteNamesAndText() {
        XCTAssertEqual(NeutrinoNotes.pageName("Q4 plan"), "Q4 plan.md")
        XCTAssertEqual(NeutrinoNotes.pageName("README.MD"), "README.MD")
        XCTAssertEqual(NeutrinoNotes.pageName("a/b"), "a-b.md")
        XCTAssertEqual(NeutrinoNotes.pageName(".hidden"), "hidden.md", "a hidden name would be left out of an export")
        XCTAssertEqual(NeutrinoNotes.pageName("  "), "Untitled note.md")
        XCTAssertTrue(NeutrinoNotes.looksLikeNoteText(Data("# Title\n\tTabbed\r\n".utf8)))
        XCTAssertFalse(NeutrinoNotes.looksLikeNoteText(Data([0x00, 0x41])))
        XCTAssertFalse(NeutrinoNotes.looksLikeNoteText(Data([0xFF, 0xFE, 0x41])))
    }
}

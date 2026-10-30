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
}

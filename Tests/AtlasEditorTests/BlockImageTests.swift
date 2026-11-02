import AtlasCore
import XCTest
@testable import AtlasEditor

final class BlockImageTests: XCTestCase {
    /// The image each block of `text` shows, in order; nil for a block that shows none.
    private func images(_ text: String) -> [BlockImage?] {
        AtlasMarkdown.syntax(of: text).blocks.map { MarkdownEditing.blockImage($0, in: text) }
    }

    func testAnImageOnItsOwnLineIsShown() {
        XCTAssertEqual(images("![[photo.png]]"), [BlockImage(source: .embed(WikiLinkReference(target: "photo.png")), width: nil)])
        XCTAssertEqual(images("![[Assets/Diagram.JPEG]]")[0]?.source, .embed(WikiLinkReference(target: "Assets/Diagram.JPEG")))
        XCTAssertEqual(images("![A cat](cats/my%20cat.png)"), [BlockImage(source: .path("cats/my cat.png"), width: nil)])
        XCTAssertEqual(images("Intro\n\n![[a.gif]]\n\nAfter").map { $0 != nil }, [false, true, false])
    }

    func testTheWidthHint() {
        XCTAssertEqual(images("![[photo.png|300]]")[0]?.width, 300)
        XCTAssertEqual(images("![[photo.png|300x200]]")[0]?.width, 300)
        XCTAssertNil(images("![[photo.png|A caption]]")[0]?.width)
        XCTAssertNotNil(images("![[photo.png|A caption]]")[0])
    }

    func testOthersStayLinks() {
        XCTAssertNil(images("See ![[photo.png]] here")[0], "inside a sentence")
        XCTAssertNil(images("![[Page]]")[0], "a page embed")
        XCTAssertNil(images("![[talk.pdf]]")[0], "not an image")
        XCTAssertNil(images("![x](https://example.com/a.png)")[0], "a web image would tell its server")
        XCTAssertNil(images("![x](//cdn.example.com/a.png)")[0])
        XCTAssertNil(images("![x](data:image/png;base64,AAAA)")[0])
        XCTAssertNil(images("- ![[photo.png]]")[0], "in a list item")
        XCTAssertNil(images("![[a.png]] ![[b.png]]")[0], "two images")
    }
}

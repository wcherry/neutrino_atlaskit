import AtlasCore
import XCTest
@testable import AtlasEditor

final class InsertImagesTests: XCTestCase {
    /// Inserts embeds at the cursor (or selection) marked by `|` (or `|…|`); the result has a `|`
    /// where the cursor ends.
    private func insert(_ targets: [String], _ marked: String) -> String? {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        let start = parts[0].utf16.count
        let end = parts.count > 2 ? start + parts[1].utf16.count : start
        guard let edit = MarkdownEditing.insertEmbeds(targets, in: text, selection: start..<end) else { return nil }
        let out = NSMutableString(string: edit.applied(to: text))
        out.insert("|", at: edit.selection.upperBound)
        return out as String
    }

    func testEachImageIsABlockOfItsOwn() {
        XCTAssertEqual(insert(["a.png"], "|"), "![[a.png]]|")
        XCTAssertEqual(insert(["a.png"], "Intro|"), "Intro\n\n![[a.png]]|")
        XCTAssertEqual(insert(["a.png"], "Intro\n|"), "Intro\n\n![[a.png]]|")
        XCTAssertEqual(insert(["a.png"], "Intro\n\n|\n\nAfter"), "Intro\n\n![[a.png]]|\n\nAfter")
        XCTAssertEqual(insert(["a.png"], "|\nAfter"), "![[a.png]]|\n\nAfter", "not run into the line below")
        XCTAssertEqual(insert(["a.png"], "One |two"), "One \n\n![[a.png]]|\n\ntwo", "splits a paragraph")
        XCTAssertEqual(insert(["a.png", "b c.jpg"], "|"), "![[a.png]]\n\n![[b c.jpg]]|")
        XCTAssertEqual(insert(["a.png"], "  |  "), "![[a.png]]|", "an empty line's spaces go")
        XCTAssertEqual(insert(["a.png"], "Keep |this| text"), "Keep \n\n![[a.png]]|\n\n text", "replaces the selection")
        XCTAssertNil(insert([], "|"))
    }

    func testTheInsertedImageShows() {
        let text = "Intro\n\n![[a.png]]\n\nAfter"
        XCTAssertNotNil(MarkdownEditing.blockImage(AtlasMarkdown.syntax(of: text).blocks[1], in: text))
    }

    func testImageTypesFromTheirBytes() {
        XCTAssertEqual(ImageImport.fileExtension(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), "png")
        XCTAssertEqual(ImageImport.fileExtension(of: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(ImageImport.fileExtension(of: Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(ImageImport.fileExtension(of: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "webp")
        XCTAssertEqual(ImageImport.fileExtension(of: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "heic")
        XCTAssertEqual(ImageImport.fileExtension(of: Data([0x49, 0x49, 0x2A, 0x00])), "tiff")
        XCTAssertNil(ImageImport.fileExtension(of: Data("%PDF-1.7".utf8)))
        XCTAssertNil(ImageImport.fileExtension(of: Data()))
    }
}

import AtlasCore
import XCTest
@testable import AtlasEditor

final class FilePreviewTests: XCTestCase {
    private let isFileLink: (String) -> Bool = { $0.contains("/open/") }

    /// Applies Show as Preview (or Chip) at the `|` in `marked`; the result has a `|` at the cursor.
    private func set(_ preview: Bool, _ marked: String) -> String? {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        guard let edit = MarkdownEditing.setPreview(preview, linkAt: parts[0].utf16.count, in: text,
                                                    syntax: AtlasMarkdown.syntax(of: text), isFileLink: isFileLink) else { return nil }
        let out = NSMutableString(string: edit.applied(to: text))
        out.insert("|", at: edit.selection.upperBound)
        return out as String
    }

    func testAPreviewIsAFileLinkShownAsAnImage() {
        let text = "![Q4 plan](https://www.getneutrino.app/open/doc/a)"
        let block = AtlasMarkdown.syntax(of: text).blocks[0]
        XCTAssertEqual(MarkdownEditing.blockImage(block, in: text, allowingURL: isFileLink)?.source, .url("https://www.getneutrino.app/open/doc/a"))
        XCTAssertNil(MarkdownEditing.blockImage(block, in: text), "a web image isn't fetched unless the app vouches for it")
        let web = "![x](https://example.com/a.png)"
        XCTAssertNil(MarkdownEditing.blockImage(AtlasMarkdown.syntax(of: web).blocks[0], in: web, allowingURL: isFileLink))
    }

    func testShowAsPreviewAndBack() {
        let link = "[Q4](https://g/open/doc/a)"
        XCTAssertEqual(set(true, "[Q|4](https://g/open/doc/a)"), "!" + link + "|", "on a line of its own: the `!` is added")
        XCTAssertEqual(set(false, "![Q|4](https://g/open/doc/a)"), link + "|", "and taken off")
        XCTAssertEqual(set(true, "See [Q|4](https://g/open/doc/a) now.\nNext"), "See now.\n\n!" + link + "|\n\nNext",
                       "in a sentence: it moves below, a block with blank lines around, or the next line would join it")
        XCTAssertEqual(set(true, "See [Q|4](https://g/open/doc/a)."), "See.\n\n!" + link + "|")
        XCTAssertNil(set(true, "![Q|4](https://g/open/doc/a)"), "already a preview")
        XCTAssertNil(set(true, "[A |site](https://example.com)"), "not a file link")
    }

    func testFileLinkAtTheCursor() {
        let text = "a [Q4](https://g/open/doc/a) b"
        let syntax = AtlasMarkdown.syntax(of: text)
        XCTAssertEqual(MarkdownEditing.fileLink(at: 4, in: syntax, isFileLink: isFileLink)?.isPreview, false)
        XCTAssertNil(MarkdownEditing.fileLink(at: 0, in: syntax, isFileLink: isFileLink))
    }

    func testBlocksGoOnLinesOfTheirOwn() {
        let text = "Intro"
        let edit = MarkdownEditing.insertBlocks(["![A](u)", "![B](v)"], in: text, selection: 5..<5)
        XCTAssertEqual(edit?.applied(to: text), "Intro\n\n![A](u)\n\n![B](v)")
    }
}

import AtlasCore
import XCTest
@testable import AtlasEditor

final class PastedLinkTests: XCTestCase {
    private let url = "https://www.getneutrino.app/open/note/n1"

    func testACopiedLinkPastesWithItsTitle() {
        // What Neutrino Notes' "Copy link" writes.
        XCTAssertEqual(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\">Q4 plan</a>"), "[Q4 plan](\(url))")
        // Chrome wraps what a page writes in a <meta>; single quotes and extra attributes are fine.
        XCTAssertEqual(MarkdownEditing.pastedLink(plain: url + "\n", html: "<meta charset='utf-8'><a class=\"x\" href='\(url)' target=\"_blank\"><b>Q4</b>  plan</a>"),
                       "[Q4 plan](\(url))")
        XCTAssertEqual(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\">Ideas &amp; [draft] &lt;1&gt; &#8212; \\</a>"),
                       "[Ideas & \\[draft\\] <1> — \\\\](\(url))", "entities decoded, brackets and backslashes escaped")
        XCTAssertEqual(MarkdownEditing.pastedLink(plain: "https://x.y/a(b)", html: "<a href=\"https://x.y/a(b)\">Paren</a>"),
                       "[Paren](<https://x.y/a(b)>)")
        XCTAssertEqual(MarkdownEditing.pastedLink(plain: "https://x.y/?a=1&b=2", html: "<a href=\"https://x.y/?a=1&amp;b=2\">Q</a>"),
                       "[Q](https://x.y/?a=1&b=2)")
    }

    func testAnythingElseIsAnOrdinaryPaste() {
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: nil))
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"https://other\">Q4 plan</a>"), "the text isn't that link")
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: "<p>See <a href=\"\(url)\">Q4 plan</a> soon</p>"), "a paragraph with a link in it")
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\">a</a><a href=\"\(url)\">b</a>"))
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\">\(url)</a>"), "no title to add")
        XCTAssertNil(MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\"> </a>"))
        XCTAssertNil(MarkdownEditing.pastedLink(plain: "javascript:alert(1)", html: "<a href=\"javascript:alert(1)\">x</a>"))
        XCTAssertNil(MarkdownEditing.pastedLink(plain: "two words", html: "<a href=\"two words\">x</a>"))
    }

    func testPastingReplacesTheSelectionButNotInCode() {
        let html = "<a href=\"\(url)\">Q4 plan</a>"
        let text = "See X now\n\n```\ncode\n```\n"
        let edit = MarkdownEditing.pasteLink(plain: url, html: html, in: text, selection: 4..<5, syntax: AtlasMarkdown.syntax(of: text))
        XCTAssertEqual(edit?.applied(to: text), "See [Q4 plan](\(url)) now\n\n```\ncode\n```\n")
        XCTAssertEqual(edit?.selection.lowerBound, 4 + "[Q4 plan](\(url))".utf16.count)
        let inCode = (text as NSString).range(of: "code\n").location + 2
        XCTAssertNil(MarkdownEditing.pasteLink(plain: url, html: html, in: text, selection: inCode..<inCode, syntax: AtlasMarkdown.syntax(of: text)))
    }

    func testTheResultParsesAsALink() {
        let pasted = MarkdownEditing.pastedLink(plain: url, html: "<a href=\"\(url)\">Ideas [draft] \\ *x*</a>")!
        let paragraph = AtlasMarkdown.parse(pasted).children.first
        guard case .paragraph(_, let kids)? = paragraph, case .link(let dest, _, let label)? = kids.first, kids.count == 1 else {
            return XCTFail("\(String(describing: paragraph))")
        }
        XCTAssertEqual(dest, url)
        XCTAssertEqual(MarkdownNode.paragraph(blockId: nil, children: label).plainText, "Ideas [draft] \\ *x*", "shown as written")
    }
}

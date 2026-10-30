import AtlasCore
import XCTest
@testable import AtlasEditor

final class MarkdownStylerTests: XCTestCase {
    /// The text of every hidden run on the page, for a cursor at `cursor`.
    private func hidden(_ source: String, cursor: Int, mode: EditorMode = .livePreview) -> [String] {
        let ns = source as NSString
        return AtlasMarkdown.syntax(of: source).blocks
            .flatMap { MarkdownStyler.runs(for: $0, selection: cursor..<cursor, mode: mode) }
            .filter(\.style.hidden)
            .map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
    }

    private func style(_ source: String, at offset: Int, cursor: Int = 0) -> TextStyle {
        let block = AtlasMarkdown.syntax(of: source).blocks.first { $0.range.contains(offset) }!
        return MarkdownStyler.runs(for: block, selection: cursor..<cursor, mode: .livePreview).first { $0.range.contains(offset) }!.style
    }

    func testSyntaxHidesAwayFromTheCursorAndShowsInsideItsConstruct() {
        let page = "# Title\n\nSome **bold** and [[Page|alias]].\n"
        // Cursor at the very end: nothing it touches.
        XCTAssertEqual(hidden(page, cursor: page.utf16.count), ["# ", "**", "**", "[[Page|", "]]"])
        // In the strong: its own `**` show; the heading's and the link's stay hidden.
        let inBold = (page as NSString).range(of: "bold").location + 1
        XCTAssertEqual(hidden(page, cursor: inBold), ["# ", "[[Page|", "]]"])
        // Touching the construct's edge counts, so the cursor never walks through hidden text.
        let afterLink = (page as NSString).range(of: "]].").location + 2
        XCTAssertEqual(hidden(page, cursor: afterLink), ["# ", "**", "**"])
        // Source mode hides nothing.
        XCTAssertEqual(hidden(page, cursor: page.utf16.count, mode: .source), [])
    }

    func testStructureStaysVisible() {
        let page = "- [ ] task\n> quote\n\n```\ncode\n```\n"
        XCTAssertEqual(hidden(page, cursor: page.utf16.count), [])
    }

    func testStyles() {
        let page = "## Head\n\n**b** _i_ `c` ==h== #tag [l](u)\n"
        let ns = page as NSString
        func at(_ s: String) -> TextStyle { style(page, at: ns.range(of: s).location) }
        XCTAssertEqual(at("Head").font, .heading(2))
        XCTAssertTrue(at("Head").bold)
        XCTAssertTrue(at("b*").bold)
        XCTAssertTrue(at("i_").italic)
        XCTAssertEqual(at("c`").font, .monospace)
        XCTAssertTrue(at("h=").highlight)
        XCTAssertEqual(at("#tag").color, .tag)
        XCTAssertEqual(at("l]").color, .link)
    }

    func testRunsCoverTheBlockWithoutGaps() {
        let page = "A **b _c_ d** e [x](y) `z`\n"
        let block = AtlasMarkdown.syntax(of: page).blocks[0]
        let runs = MarkdownStyler.runs(for: block, selection: 0..<0, mode: .livePreview)
        XCTAssertEqual(runs.first?.range.lowerBound, block.range.lowerBound)
        XCTAssertEqual(runs.last?.range.upperBound, block.range.upperBound)
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
    }
}

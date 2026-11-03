import AtlasCore
import XCTest
@testable import AtlasEditor

final class BlockDragTests: XCTestCase {
    private func blocks(_ text: String) -> [String] {
        MarkdownEditing.dragBlocks(in: text, syntax: AtlasMarkdown.syntax(of: text)).map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }

    /// Drags block number `from` to before block number `to` (nil: the end); the result has `|` at the cursor.
    private func drag(_ text: String, _ from: Int, before to: Int?) -> String? {
        let all = MarkdownEditing.dragBlocks(in: text, syntax: AtlasMarkdown.syntax(of: text))
        guard let edit = MarkdownEditing.moveBlock(all[from], before: to.map { all[$0].lowerBound }, in: text) else { return nil }
        let out = NSMutableString(string: edit.applied(to: text))
        out.insert("|", at: edit.selection.lowerBound)
        return out as String
    }

    func testTheBlocksAHandleMoves() {
        let page = "---\ntitle: A\n---\n# Plan\n\nIntro line one\nline two\n\n- a\n  - a1\n- b\n\n```\ncode\n```\n"
        XCTAssertEqual(blocks(page), ["# Plan", "Intro line one\nline two", "- a\n  - a1", "- b", "```\ncode\n```"],
                       "the frontmatter stays; a list's items move one by one, with their nested items")
    }

    func testParagraphsKeepABlankLineEachSide() {
        let page = "One\n\nTwo\n\nThree"
        XCTAssertEqual(drag(page, 2, before: 0), "|Three\n\nOne\n\nTwo")
        XCTAssertEqual(drag(page, 0, before: nil), "Two\n\nThree\n\n|One")
        XCTAssertEqual(drag(page, 0, before: 2), "Two\n\n|One\n\nThree")
        XCTAssertEqual(drag("One\n\nTwo\n", 0, before: nil), "Two\n\n|One\n", "the final newline stays last")
        XCTAssertNil(drag(page, 1, before: 1), "onto itself")
        XCTAssertNil(drag(page, 1, before: 2), "where it already is")
    }

    func testListItemsMoveAmongTheirSiblings() {
        let list = "- a\n  - a1\n- b\n- c"
        XCTAssertEqual(drag(list, 0, before: nil), "- b\n- c\n|- a\n  - a1")
        XCTAssertEqual(drag(list, 2, before: 0), "|- c\n- a\n  - a1\n- b")
        // Out of the list, it's set apart from the paragraphs around it.
        XCTAssertEqual(drag("Intro\n\n- a\n- b", 2, before: 0), "|- b\n\nIntro\n\n- a")
        XCTAssertEqual(drag("Intro\n\n- a\n- b", 1, before: 0), "|- a\n\nIntro\n\n- b", "nothing left joined together")
    }

    func testCodeMovesWhole() {
        let page = "Text\n\n```\nx\n\ny\n```"
        XCTAssertEqual(drag(page, 1, before: 0), "|```\nx\n\ny\n```\n\nText")
    }

    func testTheEditIsOnlyWhatChanged() {
        let page = "Keep\n\nOne\n\nTwo"
        let all = MarkdownEditing.dragBlocks(in: page, syntax: AtlasMarkdown.syntax(of: page))
        let edit = MarkdownEditing.moveBlock(all[2], before: all[1].lowerBound, in: page)!
        XCTAssertGreaterThanOrEqual(edit.range.lowerBound, 6, "\"Keep\" is untouched")
        XCTAssertEqual(edit.applied(to: page), "Keep\n\nTwo\n\nOne")
    }

    func testEveryMoveKeepsEveryLine() {
        let pages = [
            "# A\n\nOne\ntwo\n\n- x\n  - x1\n- y\n\n> quote\n\n```\nc\n```\n",
            "---\nt: 1\n---\nP\n\n1. a\n2. b\n\n| h |\n| - |\n| v |",
            "- [ ] task\n- [x] done\n\nAfter",
        ]
        for page in pages {
            let all = MarkdownEditing.dragBlocks(in: page, syntax: AtlasMarkdown.syntax(of: page))
            let lines = page.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.sorted()
            for from in all.indices {
                for to in Array(all.indices).map(Optional.some) + [nil] {
                    guard let edit = MarkdownEditing.moveBlock(all[from], before: to.map { all[$0].lowerBound }, in: page) else { continue }
                    let moved = edit.applied(to: page)
                    XCTAssertEqual(moved.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.sorted(), lines,
                                   "\(from) → \(String(describing: to)) in \(page)")
                    XCTAssertFalse(moved.contains("\n\n\n"), "no doubled blank lines: \(moved)")
                    XCTAssertEqual(MarkdownEditing.dragBlocks(in: moved, syntax: AtlasMarkdown.syntax(of: moved)).count, all.count,
                                   "nothing ran together: \(moved)")
                }
            }
        }
    }
}

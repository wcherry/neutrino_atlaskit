import AtlasCore
import XCTest
@testable import AtlasEditor

final class MoveLinesTests: XCTestCase {
    /// Moves the lines of text with the cursor (or selection) marked by `|` (or `|…|`), and
    /// returns the result with the new selection marked the same way. Nil if nothing moves.
    private func move(_ direction: MoveDirection, _ marked: String) -> String? {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        let start = parts[0].utf16.count
        let end = parts.count > 2 ? start + parts[1].utf16.count : start
        guard let edit = MarkdownEditing.moveLines(direction, in: text, selection: start..<end, syntax: AtlasMarkdown.syntax(of: text)) else { return nil }
        let out = NSMutableString(string: edit.applied(to: text))
        out.insert("|", at: edit.selection.upperBound)
        if !edit.selection.isEmpty { out.insert("|", at: edit.selection.lowerBound) }
        return out as String
    }

    func testMovesALineKeepingTheCursor() {
        XCTAssertEqual(move(.up, "one\ntw|o\nthree"), "tw|o\none\nthree")
        XCTAssertEqual(move(.down, "one\ntw|o\nthree"), "one\nthree\ntw|o")
        XCTAssertEqual(move(.up, "one\n|"), "|\none")
    }

    func testStopsAtTheEdges() {
        XCTAssertNil(move(.up, "o|ne\ntwo"))
        XCTAssertNil(move(.down, "one\ntw|o"))
        XCTAssertNil(move(.up, "only|"))
    }

    func testMovesEverySelectedLine() {
        XCTAssertEqual(move(.up, "zero\n|one\ntwo|\nthree"), "|one\ntwo|\nzero\nthree")
        XCTAssertEqual(move(.down, "zero\n|one\ntwo|\nthree"), "zero\nthree\n|one\ntwo|")
        // A selection ending at the start of a line doesn't take that line.
        XCTAssertEqual(move(.down, "|one\n|two\nthree"), "two\n|one\n|three")
    }

    func testAListItemTakesItsNestedItems() {
        let list = "- a\n- b|\n  - b1\n  - b2\n- c"
        XCTAssertEqual(move(.up, list), "- b|\n  - b1\n  - b2\n- a\n- c")
        XCTAssertEqual(move(.down, list), "- a\n- c\n- b|\n  - b1\n  - b2")
    }

    func testAListItemPassesASiblingWithItsNestedItems() {
        XCTAssertEqual(move(.up, "- a\n  - a1\n  - a2\n- b|"), "- b|\n- a\n  - a1\n  - a2")
        XCTAssertEqual(move(.down, "- b|\n- a\n  - a1\n- c"), "- a\n  - a1\n- b|\n- c")
        // A nested item moves among its siblings.
        XCTAssertEqual(move(.down, "- a\n  - a|1\n  - a2\n- b"), "- a\n  - a2\n  - a|1\n- b")
    }

    func testCodeAndMathBlocksMoveAndArePassedWhole() {
        let code = "before\n```\nx = 1\n```\nafter|"
        XCTAssertEqual(move(.up, code), "before\nafter|\n```\nx = 1\n```")
        XCTAssertEqual(move(.down, "befor|e\n```\nx = 1\n```\nafter"), "```\nx = 1\n```\nbefor|e\nafter")
        XCTAssertEqual(move(.up, "before\n$$\nx|\n$$"), "$$\nx|\n$$\nbefore")
    }

    func testFrontmatterStaysFirst() {
        let page = "---\ntitle: A\n---\nfirs|t\nsecond"
        XCTAssertNil(move(.up, page))
        XCTAssertEqual(move(.down, page), "---\ntitle: A\n---\nsecond\nfirs|t")
        XCTAssertNil(move(.down, "---\ntitle: |A\n---\nbody"))
    }
}

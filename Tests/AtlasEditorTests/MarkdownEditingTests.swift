import AtlasCore
import XCTest
@testable import AtlasEditor

final class MarkdownEditingTests: XCTestCase {
    /// Applies a command to text with the cursor (or selection) marked by `|` (or `|…|`), and
    /// returns the result with a `|` where the new selection ends. Nil if there is no edit.
    private func run(_ marked: String, _ command: (String, Range<Int>, PageSyntax) -> TextEdit?) -> String? {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        let start = parts[0].utf16.count
        let end = parts.count > 2 ? start + parts[1].utf16.count : start
        guard let edit = command(text, start..<end, AtlasMarkdown.syntax(of: text)) else { return nil }
        let out = edit.applied(to: text) as NSString
        let sel = edit.selection
        return out.replacingCharacters(in: NSRange(location: sel.upperBound, length: 0), with: "|")
    }

    private func newline(_ s: String) -> String? { run(s) { MarkdownEditing.newline(in: $0, selection: $1, syntax: $2) } }
    private func indent(_ s: String) -> String? { run(s) { MarkdownEditing.indent(in: $0, selection: $1, syntax: $2) } }
    private func outdent(_ s: String) -> String? { run(s) { MarkdownEditing.outdent(in: $0, selection: $1, syntax: $2) } }

    func testReturnContinuesListsTasksAndQuotes() {
        XCTAssertEqual(newline("- one|"), "- one\n- |")
        XCTAssertEqual(newline("  * one|"), "  * one\n  * |")
        XCTAssertEqual(newline("1. one|"), "1. one\n2. |")
        XCTAssertEqual(newline("9) one|"), "9) one\n10) |")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("> quote|"), "> quote\n> |")
        XCTAssertEqual(newline("> - in a quote|"), "> - in a quote\n> - |")
        XCTAssertEqual(newline("- one  |"), "- one\n- |")
        // Splitting an item in the middle carries the rest down.
        XCTAssertEqual(newline("- one|two"), "- one\n- |two")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(newline("- one\n- |"), "- one\n|")
        XCTAssertEqual(newline("- [ ] |"), "|")
        XCTAssertEqual(newline("> |"), "|")
        XCTAssertEqual(newline("> > |"), "> |")
        XCTAssertEqual(newline("> - |"), "> |")
    }

    func testReturnIsPlainElsewhere() {
        XCTAssertNil(newline("plain|"))
        XCTAssertNil(newline("|- before the marker"))
        XCTAssertNil(newline("```\n- in code|\n```"))
        XCTAssertNil(run("- o|n|e") { MarkdownEditing.newline(in: $0, selection: $1, syntax: $2) })
    }

    func testTabIndentsUnderTheItemAbove() {
        XCTAssertEqual(indent("- one\n- tw|o"), "- one\n  - tw|o")
        XCTAssertEqual(indent("1. one\n2. tw|o"), "1. one\n   2. tw|o")
        XCTAssertNil(indent("not a list|"))
        XCTAssertEqual(outdent("- one\n  - tw|o"), "- one\n- tw|o")
        XCTAssertEqual(outdent("1. one\n   - a\n     - b|"), "1. one\n   - a\n   - b|")
        XCTAssertNil(outdent("- top|"))
    }

    func testTabIndentsEverySelectedItem() {
        let edit = MarkdownEditing.indent(in: "- a\n- b\n- c", selection: 4..<11, syntax: AtlasMarkdown.syntax(of: "- a\n- b\n- c"))!
        XCTAssertEqual(edit.applied(to: "- a\n- b\n- c"), "- a\n  - b\n  - c")
        XCTAssertEqual(edit.selection, 6..<15)
    }

    func testTaskToggleChangesOneCharacter() {
        let text = "- [ ] buy milk\n- [x] done\n"
        let syntax = AtlasMarkdown.syntax(of: text)
        let tick = MarkdownEditing.toggleTask(at: 3, in: text, syntax: syntax)!
        XCTAssertEqual(tick.applied(to: text), "- [x] buy milk\n- [x] done\n")
        XCTAssertEqual(tick.range.count, 1)
        let untick = MarkdownEditing.toggleTask(at: 20, onLine: true, in: text, syntax: syntax)!
        XCTAssertEqual(untick.applied(to: text), "- [ ] buy milk\n- [ ] done\n")
        XCTAssertNil(MarkdownEditing.toggleTask(at: 10, in: text, syntax: syntax), "a click on the text isn't a click on the box")
    }

    func testWrapAndUnwrap() {
        XCTAssertEqual(run("a |word| b") { t, s, _ in MarkdownEditing.toggleWrap("**", in: t, selection: s) }, "a **word|** b")
        XCTAssertEqual(run("a **|word|** b") { t, s, _ in MarkdownEditing.toggleWrap("**", in: t, selection: s) }, "a word| b")
        XCTAssertEqual(run("a |**word**| b") { t, s, _ in MarkdownEditing.toggleWrap("**", in: t, selection: s) }, "a word| b")
        XCTAssertEqual(run("a |b") { t, s, _ in MarkdownEditing.toggleWrap("_", in: t, selection: s) }, "a _|_b")
    }
}

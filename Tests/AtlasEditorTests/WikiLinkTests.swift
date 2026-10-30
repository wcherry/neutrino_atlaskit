import AtlasCore
import XCTest
@testable import AtlasEditor

final class WikiLinkTests: XCTestCase {
    private let page = "See [[Plan|the plan]], ![[Chart.png]] and [docs](https://x.y).\n"
    private func offset(of s: String) -> Int { (page as NSString).range(of: s).location }

    func testTheLinkAtAnOffset() {
        let syntax = AtlasMarkdown.syntax(of: page)
        XCTAssertEqual(MarkdownEditing.link(at: offset(of: "the plan"), in: syntax)?.target, .wiki(WikiLinkReference(target: "Plan", alias: "the plan")))
        XCTAssertEqual(MarkdownEditing.link(at: offset(of: "Chart"), in: syntax)?.target, .wiki(WikiLinkReference(target: "Chart.png")))
        XCTAssertEqual(MarkdownEditing.link(at: offset(of: "docs"), in: syntax)?.target, .url("https://x.y"))
        XCTAssertNil(MarkdownEditing.link(at: 1, in: syntax))
    }

    func testAClickOpensALinkShownAsALink() {
        let syntax = AtlasMarkdown.syntax(of: page)
        let at = offset(of: "the plan")
        let elsewhere = 0..<0, inside = (at + 2)..<(at + 2)
        XCTAssertNotNil(MarkdownEditing.shouldOpenLink(at: at, in: syntax, selection: elsewhere, mode: .livePreview, commandKey: false))
        XCTAssertNil(MarkdownEditing.shouldOpenLink(at: at, in: syntax, selection: inside, mode: .livePreview, commandKey: false), "editing it, a click places the cursor")
        XCTAssertNil(MarkdownEditing.shouldOpenLink(at: at, in: syntax, selection: elsewhere, mode: .source, commandKey: false))
        XCTAssertNotNil(MarkdownEditing.shouldOpenLink(at: at, in: syntax, selection: inside, mode: .source, commandKey: true), "⌘-click always follows")
    }

    /// `|` marks the cursor.
    private func context(_ marked: String) -> LinkCompletionContext? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return MarkdownEditing.linkCompletionContext(in: text, cursor: cursor, syntax: AtlasMarkdown.syntax(of: text))
    }

    func testCompletionStartsAfterAnUnclosedDoubleBracket() {
        XCTAssertEqual(context("See [[Pla|")?.query, "Pla")
        XCTAssertEqual(context("See [[Pla|")?.range, 6..<9)
        XCTAssertEqual(context("[[|")?.query, "")
        XCTAssertEqual(context("![[Ima|")?.query, "Ima")
        XCTAssertEqual(context("[[Two words|]]")?.query, "Two words")
        XCTAssertNil(context("[[Done]] and |"))
        XCTAssertNil(context("[[Page#^blo|"), "a block reference has nothing to complete")
        XCTAssertNil(context("`[[code|`"))
        XCTAssertNil(context("[[one\ntwo|"))
        XCTAssertNil(context("plain|"))
    }

    func testAfterAHashTheHeadingIsCompleted() {
        XCTAssertEqual(context("See [[Plan#Go|"), LinkCompletionContext(range: 11..<13, query: "Go", page: "Plan"))
        XCTAssertEqual(context("[[ Projects/Plan #|"), LinkCompletionContext(range: 18..<18, query: "", page: "Projects/Plan"))
        XCTAssertEqual(context("[[#Goa|"), LinkCompletionContext(range: 3..<6, query: "Goa", page: ""), "this page")
        XCTAssertEqual(context("[[Plan#C# tips|")?.query, "C# tips", "a heading keeps its inner #")

        let open = "See [[Plan#Go"
        let edit = MarkdownEditing.accept(LinkCompletion(title: "Goals", target: "Goals"), in: context(open + "|")!, text: open)
        XCTAssertEqual(edit.applied(to: open), "See [[Plan#Goals]]")
    }

    func testAnAnchorIsFoundByHeadingOrBlockId() {
        let page = "# Plan\n\nIntro ^intro\n\n> ## Goals [v2]\n\n- one\n- two ^second\n\n## Goals\n"
        let syntax = AtlasMarkdown.syntax(of: page)
        func at(_ heading: String? = nil, _ block: String? = nil) -> String? {
            syntax.anchor(heading: heading, blockId: block, in: page).map { (page as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
        }
        XCTAssertEqual(at("plan"), "# Plan", "case doesn't matter")
        XCTAssertEqual(at("Goals v2"), "## Goals [v2]", "brackets can't be in a link, so they're left out; the first match wins")
        XCTAssertEqual(at("Goals"), "## Goals")
        XCTAssertEqual(at(nil, "intro"), "Intro ^intro")
        XCTAssertEqual(at(nil, "second"), "- two ^second", "an id on a list item names the item")
        XCTAssertNil(at("Missing"))
        XCTAssertNil(at(nil, "Intro"), "block ids are case-sensitive")
        XCTAssertEqual(AtlasMarkdown.headingLinkText(" Goals  [v2] | ^x "), "Goals v2 x")
    }

    func testAcceptingClosesTheLinkOnce() {
        let open = "See [[Pla"
        let c1 = MarkdownEditing.linkCompletionContext(in: open, cursor: 9, syntax: AtlasMarkdown.syntax(of: open))!
        let e1 = MarkdownEditing.accept(LinkCompletion(title: "Plan", target: "Projects/Plan"), in: c1, text: open)
        XCTAssertEqual(e1.applied(to: open), "See [[Projects/Plan]]")
        XCTAssertEqual(e1.selection, 21..<21)

        let closed = "See [[Pla]] now"
        let c2 = MarkdownEditing.linkCompletionContext(in: closed, cursor: 9, syntax: AtlasMarkdown.syntax(of: closed))!
        let e2 = MarkdownEditing.accept(LinkCompletion(title: "Plan", target: "Plan"), in: c2, text: closed)
        XCTAssertEqual(e2.applied(to: closed), "See [[Plan]] now")
        XCTAssertEqual(e2.selection, 12..<12)
    }
}

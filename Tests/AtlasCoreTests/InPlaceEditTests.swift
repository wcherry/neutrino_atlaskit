import XCTest
@testable import AtlasCore

/// SPEC §8.2: ticking a task and rewriting links change only the bytes of that construct.
final class InPlaceEditTests: XCTestCase {
    // MARK: Tasks

    func testTogglingATaskChangesOneCharacter() {
        // Non-canonical everywhere, to prove nothing else is rewritten.
        let source = "* [ ] one\n*   [X] two\n\n> 1) [ ] quoted\n\n- parent\n\t- [ ] tab-indented child\n"
        var doc = MarkdownDocument(source: source)
        XCTAssertEqual(doc.taskCount, 4)

        XCTAssertEqual(doc.setTask(at: 0, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.serialized(), "* [x] one\n*   [X] two\n\n> 1) [ ] quoted\n\n- parent\n\t- [ ] tab-indented child\n")
        XCTAssertEqual(doc.setTask(at: 1, checked: false), .inPlaceExact)
        XCTAssertEqual(doc.setTask(at: 2, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.setTask(at: 3, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.serialized(), "* [x] one\n*   [ ] two\n\n> 1) [x] quoted\n\n- parent\n\t- [x] tab-indented child\n")
        XCTAssertEqual(doc.tree, AtlasMarkdown.parse(doc.serialized()))
    }

    func testTogglingKeepsCRLFAndIsANoOpWhenAlreadySet() {
        var doc = MarkdownDocument(source: "- [x] done\r\n- [ ] open\r\n")
        XCTAssertEqual(doc.setTask(at: 0, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.setTask(at: 1, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.serialized(), "- [x] done\r\n- [x] open\r\n")
    }

    /// cmark-gfm gets both of these wrong; the converter reads the checkbox from the source.
    func testTaskStateComesFromTheCheckbox() {
        let tree = AtlasMarkdown.parse("- [ ] see [x] here\n> - [X] quoted\n")
        guard case .root(let kids) = tree, case .list(_, _, _, _, let items)? = kids.first,
              case .blockquote(_, let quoted)? = kids.last, case .list(_, _, _, _, let quotedItems)? = quoted.first else {
            return XCTFail("unexpected tree \(tree)")
        }
        XCTAssertEqual(items.first, .listItem(checked: false, spread: false, children: [.paragraph(blockId: nil, children: [.text(value: "see [x] here")])]))
        XCTAssertEqual(quotedItems.first, .listItem(checked: true, spread: false, children: [.paragraph(blockId: nil, children: [.text(value: "quoted")])]))
        XCTAssertEqual(AtlasMarkdown.parse("> - \\[ ] escaped\n").children.first,
                       .blockquote(blockId: nil, children: [.list(ordered: false, start: nil, spread: false, blockId: nil, children: [
                           .listItem(checked: nil, spread: false, children: [.paragraph(blockId: nil, children: [.text(value: "[ ] escaped")])])])]))
    }

    func testTasksInsideCalloutsAndAcrossBlocks() {
        var doc = MarkdownDocument(source: "Intro.\n\n> [!todo] Week\n> - [ ] plan\n> - [ ] ship\n\nEnd.\n")
        XCTAssertEqual(doc.taskCount, 2)
        XCTAssertEqual(doc.setTask(at: 1, checked: true), .inPlaceExact)
        XCTAssertEqual(doc.serialized(), "Intro.\n\n> [!todo] Week\n> - [ ] plan\n> - [x] ship\n\nEnd.\n")
    }

    // MARK: Links

    private func renameRoadmap(in source: String, to newPath: String = "Plans/Roadmap 2027.md",
                               files: [String] = ["Roadmap.md", "Inbox.md", "Other.md"]) -> (String, LinkRewriteResult) {
        var doc = MarkdownDocument(source: source)
        let after = files.map { $0 == "Roadmap.md" ? newPath : $0 }
        let result = doc.rewriteLinks(toRenamed: "Roadmap.md", as: newPath, linkingPage: "Inbox.md",
                                      before: LinkResolver(files: files), after: LinkResolver(files: after))
        XCTAssertEqual(doc.tree, AtlasMarkdown.parse(doc.serialized()), "the document's tree must match its bytes")
        return (doc.serialized(), result)
    }

    func testWikiLinksKeepEverythingButTheTarget() {
        let (out, result) = renameRoadmap(in: "See [[ Roadmap #Phase 2| the plan ]], [[roadmap#^summary]], ![[Roadmap]] and [[Other]].\n")
        XCTAssertEqual(out, "See [[ Roadmap 2027 #Phase 2| the plan ]], [[Roadmap 2027#^summary]], ![[Roadmap 2027]] and [[Other]].\n")
        XCTAssertEqual(result, LinkRewriteResult(rewritten: 3, inPlace: true, exact: true))
    }

    func testSamePageLinksCodeAndOtherBlocksAreUntouched() {
        let source = "# Roadmap\n\nJump to [[#Roadmap]]. Code: `[[Roadmap]]`.\n\n```\n[[Roadmap]]\n```\n\n* untouched _list_\n\nLink [[Roadmap]].\n"
        let (out, result) = renameRoadmap(in: source)
        XCTAssertEqual(out, source.replacingOccurrences(of: "Link [[Roadmap]].", with: "Link [[Roadmap 2027]]."))
        XCTAssertEqual(result.rewritten, 1)
        XCTAssertTrue(result.inPlace)
    }

    func testWikiLinksInTablesKeepTheEscapedSeparator() {
        let (out, _) = renameRoadmap(in: "| Page | Why |\n|:-|-|\n| [[Roadmap\\|plan]] | x |\n")
        XCTAssertEqual(out, "| Page | Why |\n|:-|-|\n| [[Roadmap 2027\\|plan]] | x |\n")
    }

    func testMarkdownLinksKeepTheirStyleAndFragment() {
        let source = "[a](Roadmap.md#Phase%202) [b](<Roadmap.md>) [c](Road%6Dap.md) [d](https://x.com/Roadmap.md) [e](Old/../Roadmap.md)\n"
        let (out, result) = renameRoadmap(in: source, files: ["Roadmap.md", "Inbox.md"])
        // A plain path gets angle brackets once it has a space; a percent-encoded one stays
        // encoded. External links aren't touched, and nor is `..`, which §7 doesn't resolve.
        XCTAssertEqual(out, "[a](<Roadmap 2027.md#Phase%202>) [b](<Roadmap 2027.md>) [c](Roadmap%202027.md) [d](https://x.com/Roadmap.md) [e](Old/../Roadmap.md)\n")
        XCTAssertEqual(result.rewritten, 3)
        XCTAssertTrue(result.inPlace)
    }

    func testReferenceDefinitionsInGapsAreRewritten() {
        let (out, result) = renameRoadmap(in: "See [the plan][r] and [[Roadmap]].\n\n[r]: Roadmap.md \"Plan\"\n\nEnd.\n")
        XCTAssertEqual(out, "See [the plan][r] and [[Roadmap 2027]].\n\n[r]: <Roadmap 2027.md> \"Plan\"\n\nEnd.\n")
        XCTAssertEqual(result, LinkRewriteResult(rewritten: 2, inPlace: true, exact: true))
    }

    func testDefinitionsAtTheStartOfAParagraphAndStrayBracketsAreHandled() {
        // The definition is inside the paragraph's lines, not a gap. The first `](P.md)` has no `[`.
        let (out, result) = renameRoadmap(in: "[r]:Roadmap.md\n[r] and ](Roadmap.md) then [x](Roadmap.md)\n")
        XCTAssertEqual(out, "[r]:<Roadmap 2027.md>\n[r] and ](Roadmap.md) then [x](<Roadmap 2027.md>)\n")
        XCTAssertEqual(result, LinkRewriteResult(rewritten: 2, inPlace: true, exact: true))
    }

    func testAmbiguousNamesGetTheShortestUniqueTarget() {
        // After the move there is a Roadmap.md at the root again, so the bare name would be wrong.
        var doc = MarkdownDocument(source: "[[Projects/Roadmap]]\n")
        let before = LinkResolver(files: ["Projects/Roadmap.md", "Inbox.md"])
        let after = LinkResolver(files: ["Archive/Roadmap.md", "Roadmap.md", "Inbox.md"])
        doc.rewriteLinks(toRenamed: "Projects/Roadmap.md", as: "Archive/Roadmap.md", linkingPage: "Inbox.md", before: before, after: after)
        XCTAssertEqual(doc.serialized(), "[[Archive/Roadmap]]\n")
    }
}

import XCTest
@testable import AtlasCore

/// Source preservation while editing (SPEC §8.1): only the edited block's bytes change.
final class DocumentEditingTests: XCTestCase {
    private func paragraph(_ text: String) -> MarkdownNode {
        .paragraph(blockId: nil, children: [.text(value: text)])
    }

    func testReplacingABlockChangesOnlyThatBlock() {
        // Non-canonical everywhere: setext heading, `*` bullets, Obsidian tab indentation,
        // underscore emphasis, two blank lines. None of it may be touched by an edit elsewhere.
        let source = "Title\n=====\n\n* one\n\t* nested\n\n\nOld _text_ here.\n\nLast.\n"
        var doc = MarkdownDocument(source: source)
        XCTAssertEqual(doc.blocks.count, 4)
        XCTAssertTrue(doc.replaceBlock(at: 2, with: paragraph("New text.")))
        XCTAssertEqual(doc.serialized(), "Title\n=====\n\n* one\n\t* nested\n\n\nNew text.\n\nLast.\n")
    }

    func testEditsUseTheFilesLineEndingsAndKeepItsBOM() {
        var doc = MarkdownDocument(source: "\u{FEFF}# A\r\n\r\nold\r\n")
        XCTAssertEqual(doc.lineEnding, "\r\n")
        doc.replaceBlock(at: 0, with: .heading(depth: 1, children: [.text(value: "B")]))
        doc.replaceBlock(at: 1, with: .paragraph(blockId: nil, children: [.text(value: "one\ntwo")]))
        XCTAssertEqual(doc.serialized(), "\u{FEFF}# B\r\n\r\none\r\ntwo\r\n")
    }

    func testInsertAndRemove() {
        var doc = MarkdownDocument(source: "A\n\nB\n")
        doc.insertBlock(paragraph("Middle"), at: 1)
        XCTAssertEqual(doc.serialized(), "A\n\nMiddle\n\nB\n")
        doc.insertBlock(paragraph("End"), at: 3)
        XCTAssertEqual(doc.serialized(), "A\n\nMiddle\n\nB\n\nEnd\n")
        doc.removeBlock(at: 1)
        XCTAssertEqual(doc.serialized(), "A\n\nB\n\nEnd\n")
        doc.removeBlock(at: 2)
        XCTAssertEqual(doc.serialized(), "A\n\nB\n")
        XCTAssertEqual(doc.tree, AtlasMarkdown.parse(doc.serialized()))
    }

    func testInsertingIntoAnEmptyPage() {
        var doc = MarkdownDocument(source: "")
        doc.insertBlock(paragraph("First"), at: 0)
        XCTAssertEqual(doc.serialized(), "First\n")
    }

    func testAListInsertedAfterAListUsesTheOtherMarker() {
        var doc = MarkdownDocument(source: "- a\n")
        let list = MarkdownNode.list(ordered: false, start: nil, spread: false, blockId: nil,
                                     children: [.listItem(checked: nil, spread: false, children: [paragraph("b")])])
        doc.insertBlock(list, at: 1)
        XCTAssertEqual(doc.serialized(), "- a\n\n* b\n")
        XCTAssertEqual(AtlasMarkdown.parse(doc.serialized()).children.count, 2)
    }

    func testEditedTextIsEscapedOnlyWhereNeeded() {
        var doc = MarkdownDocument(source: "x\n")
        doc.replaceBlock(at: 0, with: paragraph("Literal [[Page]], #tag, ==mark==, $5$ and 2 * 3 * 4."))
        XCTAssertEqual(doc.serialized(), "Literal \\[[Page]], \\#tag, \\==mark==, \\$5$ and 2 * 3 * 4.\n")
    }

    func testReferenceDefinitionsInGapsSurviveEdits() {
        var doc = MarkdownDocument(source: "See [it][r].\n\n[r]: https://example.com\n\nEdit me.\n")
        XCTAssertEqual(doc.blocks.count, 2)
        doc.replaceBlock(at: 1, with: paragraph("Edited."))
        XCTAssertEqual(doc.serialized(), "See [it][r].\n\n[r]: https://example.com\n\nEdited.\n")
    }

    func testAThematicBreakInsertedAtTheTopIsNotFrontmatter() {
        var doc = MarkdownDocument(source: "Text\n\n---\n")
        doc.insertBlock(.thematicBreak, at: 0)
        XCTAssertEqual(doc.serialized(), "***\n\nText\n\n---\n")
        XCTAssertEqual(doc.tree, AtlasMarkdown.parse(doc.serialized()))
    }
}

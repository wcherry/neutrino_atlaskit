import XCTest
@testable import AtlasCore

/// Regressions found by fuzzing and differential testing, beyond the conformance corpus.

final class ParserRegressionTests: XCTestCase {
    private func text(_ source: String) -> String {
        func collect(_ n: MarkdownNode) -> String {
            switch n {
            case .text(let v), .inlineCode(let v), .html(let v), .code(_, _, let v, _): return v
            default: return n.children.map(collect).joined()
            }
        }
        return collect(AtlasMarkdown.parse(source))
    }

    /// cmark-gfm loses text around a `[^` that can't be a footnote, when footnotes are on.
    func testFootnoteLikeOpenersDoNotLoseText() {
        XCTAssertEqual(text("[^[x]]y\n"), "[^[x]]y")
        XCTAssertEqual(text("a [^[^b]] c\n"), "a [^[^b]] c")
        XCTAssertEqual(text("```\n[^[x]]y\n```\n"), "[^[x]]y")
        XCTAssertEqual(text("[^a\nb]x\n"), "[^a\nb]x")
        XCTAssertEqual(text("p [^ q] r\n"), "p [^ q] r")
        // ```]``` is a code span (value "]"), so the label isn't a footnote label and nothing is lost.
        XCTAssertEqual(text("[^```]```\nz]\n"), "[^]\nz]")
        // An unmatched backtick run is literal as a whole; the [^[ after it is still guarded.
        XCTAssertEqual(text("``[^[`]x]\n"), "``[^[`]x]")
        // A real footnote and a link whose text starts with ^ are unaffected.
        XCTAssertEqual(AtlasMarkdown.parse("A[^n].\n\n[^n]: B.\n"),
                       .root(children: [.paragraph(blockId: nil, children: [.text(value: "A"), .footnoteReference(identifier: "n", label: "n"), .text(value: ".")]),
                                        .footnoteDefinition(identifier: "n", label: "n", children: [.paragraph(blockId: nil, children: [.text(value: "B.")])])]))
        XCTAssertEqual(AtlasMarkdown.parse("[^a b](u)\n"),
                       .root(children: [.paragraph(blockId: nil, children: [.link(url: "u", title: nil, children: [.text(value: "^a b")])])]))
    }

    /// The parser marks things with private-use characters U+E000–U+E0FF. A user's own
    /// characters from that range must come through untouched, in code spans too, and must
    /// never crash the parser (fuzzing found both a crash and a corruption).
    func testPrivateUseCharactersAreKept() {
        XCTAssertEqual(text("\u{E000}^\n"), "\u{E000}^")
        XCTAssertEqual(text("a\u{E000}\u{E020}\u{E001}b\n"), "a\u{E000}\u{E020}\u{E001}b")
        XCTAssertEqual(text("`\u{E012}` \u{E011}#x\n"), "\u{E012} \u{E011}#x")
        XCTAssertEqual(text("`\u{2E3E}` \u{2E3C}\u{E020}\u{2E3D} \u{2E41}#x\n"), "\u{2E3E} \u{2E3C}\u{E020}\u{2E3D} \u{2E41}#x")
    }

    /// Escape markers and placeholders flank like the punctuation they replace: an escaped
    /// character or a wiki link next to `*` or `_` must not change what is emphasis.
    func testMarkersFlankLikePunctuation() {
        XCTAssertEqual(AtlasMarkdown.parse("*]*\\^\n"),
                       .root(children: [.paragraph(blockId: nil, children: [.emphasis(children: [.text(value: "]")]), .text(value: "^")])]))
        // As in `a*[x]*b`, a `*` between a letter and `[` can't open emphasis.
        XCTAssertEqual(AtlasMarkdown.parse("a*[[x]]*b\n"),
                       .root(children: [.paragraph(blockId: nil, children: [.text(value: "a*"), .wikiLink(WikiLinkReference(target: "x")), .text(value: "*b")])]))
        XCTAssertEqual(AtlasMarkdown.parse("*[[x]]*\n"),
                       .root(children: [.paragraph(blockId: nil, children: [.emphasis(children: [.wikiLink(WikiLinkReference(target: "x"))])])]))
    }

    /// swift-cmark's inline attributes (`^[text](attrs)`) are not GFM and must not apply.
    func testNoInlineAttributes() {
        XCTAssertEqual(text("^[text](a: 1) after\n"), "^[text](a: 1) after")
        XCTAssertEqual(text("^[][1]\n"), "^[][1]")
    }

    /// Smart punctuation must be off: `--` and quotes are kept as typed.
    func testNoSmartPunctuation() {
        XCTAssertEqual(text("\"quoted\" -- dash --- 'single'\n"), "\"quoted\" -- dash --- 'single'")
    }

    /// Table spans must be off: an empty cell is an empty cell, and `^` is text.
    func testNoTableSpans() {
        let tree = AtlasMarkdown.parse("| a | b |\n| --- | --- |\n| x |  |\n| ^ | y |\n")
        guard case .root(let kids) = tree, case .table(_, _, let rows)? = kids.first else { return XCTFail("no table") }
        XCTAssertEqual(rows.map { $0.children.count }, [2, 2, 2])
        XCTAssertEqual(rows[2].children.first, .tableCell(children: [.text(value: "^")]))
    }
}

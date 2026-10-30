import Foundation
import XCTest
@testable import AtlasCore

final class PageSyntaxTests: XCTestCase {
    /// Each span as `kind "text"`, in order.
    private func spans(_ source: String) -> [String] {
        let ns = source as NSString
        return AtlasMarkdown.syntax(of: source).spans.map { span in
            let text = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
            let kind: String
            if case .syntax(let role) = span.kind { kind = "\(role)" } else { kind = "\(span.kind)" }
            return "\(kind) \(text.debugDescription)"
        }
    }

    private func syntax(_ source: String, _ roles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let page = AtlasMarkdown.syntax(of: source)
        XCTAssertTrue(page.blocks.allSatisfy(\.isComplete), "incomplete: \(source.debugDescription)", file: file, line: line)
        XCTAssertEqual(spans(source), roles, file: file, line: line)
    }

    func testHeadingsAndEmphasis() {
        syntax("## A **b** _c_ ##", [
            ###"heading(level: 2) "## A **b** _c_ ##""###,
            ###"headingMarker "## ""###,
            ###"strong "**b**""###, ###"delimiter "**""###, ###"delimiter "**""###,
            ###"emphasis "_c_""###, ###"delimiter "_""###, ###"delimiter "_""###,
            ###"headingMarker " ##""###,
        ])
        syntax("Title\n===", [###"heading(level: 1) "Title\n===""###, ###"headingMarker "===""###])
    }

    func testInlineConstructs() {
        syntax(###"a `x` $y$ ==z== ~~w~~ \* &amp; #tag [[P|alias]] ![[E]] [l](u "t") <http://a.b>"###, [
            ###"inlineCode "`x`""###, ###"delimiter "`""###, ###"delimiter "`""###,
            ###"inlineMath "$y$""###, ###"delimiter "$""###, ###"delimiter "$""###,
            ###"highlight "==z==""###, ###"delimiter "==""###, ###"delimiter "==""###,
            ###"strikethrough "~~w~~""###, ###"delimiter "~~""###, ###"delimiter "~~""###,
            ###"escape "\\""###,
            ###"tag(name: "tag") "#tag""###,
            ###"wikiLink(AtlasCore.WikiLinkReference(target: "P", heading: nil, blockId: nil, alias: Optional("alias"))) "[[P|alias]]""###,
            ###"wikiBracket "[[""###, ###"wikiTarget "P|""###, ###"wikiBracket "]]""###,
            ###"embed(AtlasCore.WikiLinkReference(target: "E", heading: nil, blockId: nil, alias: nil)) "![[E]]""###,
            ###"wikiBracket "![[""###, ###"wikiBracket "]]""###,
            ###"link(url: "u") "[l](u \"t\")""###, ###"linkBracket "[""###, ###"linkBracket "]""###, ###"linkDestination "(u \"t\")""###,
            ###"link(url: "http://a.b") "<http://a.b>""###, ###"linkBracket "<""###, ###"linkBracket ">""###,
        ])
    }

    func testContainers() {
        syntax("> quote\n> more", [###"blockquote "> quote\n> more""###, ###"quoteMarker "> ""###, ###"quoteMarker "> ""###])
        syntax("- [ ] task\n  - [x] done\n1. one", [
            ###"listItem(ordered: false, checked: Optional(false)) "- [ ] task\n  - [x] done""###,
            ###"listMarker "-""###, ###"taskMarker(checked: false) "[ ]""###,
            ###"listItem(ordered: false, checked: Optional(true)) "- [x] done""###,
            ###"listMarker "-""###, ###"taskMarker(checked: true) "[x]""###,
            ###"listItem(ordered: true, checked: nil) "1. one""###, ###"listMarker "1.""###,
        ])
        syntax("> [!tip]+ Title\n> body ^b1", [
            ###"callout(type: "tip") "> [!tip]+ Title\n> body ^b1""###,
            ###"quoteMarker "> ""###, ###"calloutMarker "[!tip]+""###, ###"quoteMarker "> ""###, ###"blockId "^b1""###,
        ])
    }

    func testCodeMathTablesAndFrontmatter() {
        syntax("---\ntitle: x\n---\n\n```swift\nlet a = 1\n```\n\n$$\nx^2\n$$\n^m\n\n| a | b |\n|---|---|\n| 1 | **2** |", [
            ###"frontmatter "---\ntitle: x\n---""###, ###"frontmatterFence "---""###, ###"frontmatterFence "---""###,
            ###"codeBlock(language: Optional("swift")) "```swift\nlet a = 1\n```""###, ###"codeFence "```swift""###, ###"codeFence "```""###,
            ###"mathBlock "$$\nx^2\n$$""###, ###"mathFence "$$""###, ###"mathFence "$$""###, ###"blockId "^m""###,
            ###"table "| a | b |\n|---|---|\n| 1 | **2** |""###,
            ###"tablePipe "|""###, ###"tablePipe "|""###, ###"tablePipe "|""###, ###"tableDelimiterRow "|---|---|""###,
            ###"tablePipe "|""###, ###"tablePipe "|""###, ###"strong "**2**""###, ###"delimiter "**""###, ###"delimiter "**""###, ###"tablePipe "|""###,
        ])
    }

    func testOffsetsAreUTF16() {
        let source = "😀 **é**"
        let span = AtlasMarkdown.syntax(of: source).spans.first { $0.kind == .strong }!
        XCTAssertEqual(span.range, 3..<8)
    }

    func testReferenceDefinitionsAndLazyLines() {
        syntax("> [r]: /u\n> see [r]\nlazy", [
            ###"blockquote "> [r]: /u\n> see [r]\nlazy""###, ###"quoteMarker "> ""###, ###"quoteMarker "> ""###,
            ###"link(url: "/u") "[r]""###, ###"linkBracket "[""###, ###"linkBracket "]""###,
        ])
    }

    /// The editor maps the whole page after an edit, so a long page must stay fast. This one is
    /// 157k characters in 2,800 blocks, far beyond a usual page: about 45 ms in release on an
    /// M-series Mac, or 0.1 ms per section.
    func testALongPageIsFast() {
        let section = """
        ## Section with **bold**, _emphasis_ and a [[Wiki link|alias]]

        A paragraph with `code`, $math$, ==highlight==, #tag and [a link](https://example.com "t").
        It continues on a second line, with an escaped \\* and an &amp; entity.

        - [ ] a task with [[Another page]]
        - [x] done
          - nested item
        1. ordered

        > [!note] Callout
        > with a body

        | a | b |
        |---|---|
        | 1 | **2** |

        ```swift
        let x = 1
        ```


        """
        let page = String(repeating: section, count: 400)
        let start = Date()
        let syntax = AtlasMarkdown.syntax(of: page)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(syntax.blocks.allSatisfy(\.isComplete))
        XCTAssertLessThan(elapsed, 3, "mapping \(page.utf16.count) characters took \(elapsed) s")
        print("PageSyntax: \(page.utf16.count) characters, \(syntax.blocks.count) blocks, \(syntax.spans.count) spans in \(String(format: "%.1f", elapsed * 1000)) ms")
    }

    // MARK: Against the parser

    /// What a complete block's spans must contain: one per construct in its tree.
    private func expectedKinds(_ node: MarkdownNode, ordered: Bool = false, inline: Bool = false) -> [String] {
        func kids(_ k: [MarkdownNode], inline: Bool = true) -> [String] { k.flatMap { expectedKinds($0, inline: inline) } }
        switch node {
        case .yaml: return ["frontmatter"]
        case .heading(let d, let k): return ["\(SyntaxSpan.Kind.heading(level: d))"] + kids(k)
        case .blockquote(_, let k): return ["blockquote"] + kids(k, inline: false)
        case .callout(let t, _, let title, _, let k): return ["\(SyntaxSpan.Kind.callout(type: t))"] + kids(title ?? []) + kids(k, inline: false)
        case .list(let o, _, _, _, let items): return items.flatMap { expectedKinds($0, ordered: o) }
        case .listItem(let checked, _, let k): return ["\(SyntaxSpan.Kind.listItem(ordered: ordered, checked: checked))"] + kids(k, inline: false)
        case .code(let lang, _, _, _): return ["\(SyntaxSpan.Kind.codeBlock(language: lang))"]
        case .math: return ["mathBlock"]
        case .table(_, _, let rows): return ["table"] + rows.flatMap { $0.children.flatMap { kids($0.children) } }
        case .thematicBreak: return ["thematicBreak"]
        case .html: return [inline ? "inlineHTML" : "htmlBlock"]
        case .footnoteDefinition(let id, _, let k): return ["\(SyntaxSpan.Kind.footnoteDefinition(identifier: id))"] + kids(k, inline: false)
        case .strong(let k): return ["strong"] + kids(k)
        case .emphasis(let k): return ["emphasis"] + kids(k)
        case .delete(let k): return ["strikethrough"] + kids(k)
        case .highlight(let k): return ["highlight"] + kids(k)
        case .inlineCode: return ["inlineCode"]
        case .inlineMath: return ["inlineMath"]
        case .link(let url, _, let k): return ["\(SyntaxSpan.Kind.link(url: url))"] + kids(k)
        case .image(let url, _, _): return ["\(SyntaxSpan.Kind.image(url: url))"]
        case .wikiLink(let r): return ["\(SyntaxSpan.Kind.wikiLink(r))"]
        case .embed(let r): return ["\(SyntaxSpan.Kind.embed(r))"]
        case .tag(let n): return ["\(SyntaxSpan.Kind.tag(name: n))"]
        case .footnoteReference(let id, _): return ["\(SyntaxSpan.Kind.footnoteReference(identifier: id))"]
        case .root(let k), .paragraph(_, let k): return kids(k, inline: !(node.isRoot))
        case .text, .break, .tableRow, .tableCell: return node.children.flatMap { expectedKinds($0, inline: true) }
        }
    }

    /// For every complete block, its constructs are exactly the tree's, and every span is in
    /// the block and inside the page.
    private func checkAgainstTree(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> (complete: Int, total: Int) {
        let page = AtlasMarkdown.syntax(of: source)
        let length = source.utf16.count
        XCTAssertEqual(page.blocks.map(\.node), AtlasMarkdown.parse(source).children, file: file, line: line)
        for span in page.spans {
            XCTAssertTrue(span.range.lowerBound >= 0 && span.range.upperBound <= length, "span out of bounds in \(source.debugDescription)", file: file, line: line)
        }
        var complete = 0
        for block in page.blocks {
            let inside = block.spans
            for span in inside {
                XCTAssertGreaterThanOrEqual(span.range.lowerBound, block.range.lowerBound, "span leaves its block in \(source.debugDescription)", file: file, line: line)
                XCTAssertLessThanOrEqual(span.range.upperBound, block.range.upperBound, "span leaves its block in \(source.debugDescription)", file: file, line: line)
            }
            guard block.isComplete else { continue }
            complete += 1
            let found = inside.compactMap { span -> String? in
                if case .syntax = span.kind { return nil }
                return "\(span.kind)"
            }
            XCTAssertEqual(found.sorted(), expectedKinds(block.node).sorted(), "constructs differ in \(source.debugDescription)", file: file, line: line)
        }
        return (complete, page.blocks.count)
    }

    func testCorpusAlignsCompletely() throws {
        let corpus = ConformanceCorpusTests.corpus
        let manifest = try JSONDecoder().decode(ConformanceCorpusTests.Manifest.self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        var incomplete: [String] = []
        for c in manifest.cases {
            let source = try String(contentsOf: corpus.appendingPathComponent("cases/\(c.id)/input.md"), encoding: .utf8)
            let (complete, total) = checkAgainstTree(source)
            if complete < total { incomplete.append(c.id) }
        }
        XCTAssertEqual(incomplete, [], "cases with blocks that didn't align")
    }

    /// Random pages: no traps, spans in bounds, and complete blocks agree with the tree. Most
    /// blocks of such noise should still align.
    func testRandomPagesAgreeWithTheTree() {
        var state: UInt64 = 0x51A7
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = Array("[]!#=^$|\\`*_~<>-+.:() \t\n").map(String.init) + [
            "a", "x", "é", "😀", "- ", "1. ", "> ", "- [ ] ", "[[P]]", "[[P|a]]", "![[E]]", "#t", "==h==", "**b**", "_e_",
            "`c`", "$m$", "[l](u)", "[r]", "[r]: /u\n", "<http://a.b>", "www.x.com", "&amp;", "&copy;", "\\*", "```\n",
            "$$\n", "---\n", "| a | b |\n|---|---|\n", "> [!note] T\n", "[^1]", "[^1]: n\n", " ^id", "\n\n", "    ", "<b>", "\r\n",
        ]
        var complete = 0, total = 0
        for _ in 0..<3000 {
            let source = (0..<next(40)).map { _ in pieces[next(pieces.count)] }.joined()
            let (c, t) = checkAgainstTree(source)
            complete += c; total += t
        }
        XCTAssertGreaterThan(Double(complete), 0.995 * Double(total), "only \(complete) of \(total) random blocks aligned")
    }
}

private extension MarkdownNode {
    var isRoot: Bool { if case .root = self { return true }; return false }
}

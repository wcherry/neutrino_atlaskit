import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Parses preprocessed source with cmark-gfm and converts its tree to `MarkdownNode`.
///
/// cmark runs with exactly the GFM extensions SPEC §2 names: tables, task lists,
/// strikethrough, extended autolinks and footnotes. Smart punctuation and table spans are off,
/// because both change what standard GFM means.
///
/// Placeholder tokens and escape markers from `SourcePreprocessor` pass through untouched, as
/// ordinary text characters. The later passes deal with them.
enum CMarkConverter {
    static func convert(_ source: String) -> MarkdownNode {
        .root(children: convertTopLevel(source).map(\.node))
    }

    /// The top-level blocks, each with the 1-based source lines its content occupies.
    static func convertTopLevel(_ source: String) -> [(node: MarkdownNode, lines: ClosedRange<Int>)] {
        Conversion(source: source).run()
    }
}

/// One conversion. It keeps the source's lines because cmark's end lines are not always where
/// a node's content ends (see `contentEndLine`).
private struct Conversion {
    private typealias Node = UnsafeMutablePointer<cmark_node>
    let source: String
    let lines: [String]

    init(source: String) {
        self.source = source
        lines = SourcePreprocessor.splitLines(source).map(\.content)
    }

    func run() -> [(node: MarkdownNode, lines: ClosedRange<Int>)] {
        cmark_gfm_core_extensions_ensure_registered()
        let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES)!
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        source.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        let document = cmark_parser_finish(parser)!
        defer { cmark_node_free(document) }
        let top = topLevelInSourceOrder(document)
        var blocks: [(node: MarkdownNode, lines: ClosedRange<Int>)] = top.enumerated().map { i, n in
            let start = Int(cmark_node_get_start_line(n))
            let next = i + 1 < top.count ? cmark_node_get_start_line(top[i + 1]) : nil
            return (node(n), start...max(start, Int(contentEndLine(n, before: next))))
        }
        // cmark-gfm bug: when a table interrupts a paragraph, it splits off a new paragraph with
        // no source position (line 0), and reports the table as starting where the paragraph
        // did. The paragraph's lines are its own line count from there; the table follows.
        for i in blocks.indices where blocks[i].lines.lowerBound == 0 {
            let start = i + 1 < blocks.count ? blocks[i + 1].lines.lowerBound : (i > 0 ? blocks[i - 1].lines.upperBound + 1 : 1)
            let count = blocks[i].node.plainTextForFlanking.filter { $0 == "\n" }.count + 1
            blocks[i].lines = start...(start + count - 1)
            if i + 1 < blocks.count {
                let next = blocks[i + 1].lines
                blocks[i + 1].lines = (start + count)...max(start + count, next.upperBound)
            }
        }
        return blocks
    }

    /// cmark-gfm moves every footnote definition to the end of the document. SPEC §3.2 puts
    /// them back at the top level in source order, by the line each one starts on.
    private func topLevelInSourceOrder(_ document: Node) -> [Node] {
        let kids = childPointers(document)
        let definitions = kids.filter { cmark_node_get_type($0) == CMARK_NODE_FOOTNOTE_DEFINITION }
        guard !definitions.isEmpty else { return kids }
        var ordered = kids.filter { cmark_node_get_type($0) != CMARK_NODE_FOOTNOTE_DEFINITION }
        for definition in definitions {
            let line = cmark_node_get_start_line(definition)
            let at = ordered.firstIndex { cmark_node_get_start_line($0) > line } ?? ordered.endIndex
            ordered.insert(definition, at: at)
        }
        return ordered
    }

    private func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
    private func optional(_ p: UnsafePointer<CChar>?) -> String? {
        let s = string(p)
        return s.isEmpty ? nil : s
    }

    /// Drops the single trailing line ending cmark leaves on block literals, and makes all
    /// line endings `\n` (SPEC §3.1).
    private func blockValue(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if v.hasSuffix("\n") { v.removeLast() }
        return v
    }

    private func children(_ n: Node) -> [MarkdownNode] {
        var out: [MarkdownNode] = []
        var child = cmark_node_first_child(n)
        while let c = child {
            out.append(node(c))
            child = cmark_node_next(c)
        }
        return out
    }

    private func childPointers(_ n: Node) -> [Node] {
        var out: [Node] = []
        var child = cmark_node_first_child(n)
        while let c = child { out.append(c); child = cmark_node_next(c) }
        return out
    }

    private func node(_ n: Node) -> MarkdownNode {
        // cmark-gfm's type-string table has no entries for footnotes, so match those on the enum.
        // A reference's literal is the ordinal cmark assigns ("1"); its label is on the definition.
        switch cmark_node_get_type(n) {
        case CMARK_NODE_FOOTNOTE_DEFINITION:
            let label = string(cmark_node_get_literal(n))
            return .footnoteDefinition(identifier: footnoteIdentifier(label), label: label, children: children(n))
        case CMARK_NODE_FOOTNOTE_REFERENCE:
            let label = cmark_node_parent_footnote_def(n).map { string(cmark_node_get_literal($0)) } ?? string(cmark_node_get_literal(n))
            return .footnoteReference(identifier: footnoteIdentifier(label), label: label)
        default:
            break
        }

        let type = string(cmark_node_get_type_string(n))
        switch type {
        case "document":
            return .root(children: children(n))
        case "paragraph":
            return .paragraph(blockId: nil, children: children(n))
        case "heading":
            return .heading(depth: Int(cmark_node_get_heading_level(n)), children: children(n))
        case "thematic_break":
            return .thematicBreak
        case "block_quote":
            return .blockquote(blockId: nil, children: children(n))
        case "list":
            let ordered = cmark_node_get_list_type(n) == CMARK_ORDERED_LIST
            let items = childPointers(n)
            // mdast's list `spread` (§3.2): a blank line between two items. Blank lines inside an
            // item set that item's own `spread` instead. (CommonMark's "loose" is the two
            // together.) Worked out from line numbers rather than cmark's `tight` flag, which
            // is the CommonMark notion.
            let spread = hasBlankBetween(items)
            return .list(ordered: ordered, start: ordered ? Int(cmark_node_get_list_start(n)) : nil,
                         spread: spread, blockId: nil, children: items.map(node))
        case "item", "tasklist":
            let checked: Bool? = type == "tasklist" ? cmark_gfm_extensions_get_tasklist_item_checked(n) : nil
            return .listItem(checked: checked, spread: isSpread(n), children: children(n))
        case "code_block":
            let info = string(cmark_node_get_fence_info(n)).trimmingCharacters(in: .whitespaces)
            let value = blockValue(string(cmark_node_get_literal(n)))
            if info == SourcePreprocessor.mathInfo { return .math(meta: nil, value: value, blockId: nil) }
            var lang: String? = nil, meta: String? = nil
            if !info.isEmpty {
                let parts = info.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                lang = String(parts[0])
                if parts.count > 1 { meta = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            return .code(lang: lang, meta: meta, value: value, blockId: nil)
        case "html_block":
            return .html(value: blockValue(string(cmark_node_get_literal(n))))
        case "table":
            let columns = Int(cmark_gfm_extensions_get_table_columns(n))
            let raw = cmark_gfm_extensions_get_table_alignments(n)
            let align: [TableAlignment?] = (0..<columns).map { i in
                switch raw.map({ UInt8($0[i]) }) {
                case UInt8(ascii: "l"): return .left
                case UInt8(ascii: "r"): return .right
                case UInt8(ascii: "c"): return .center
                default: return nil
                }
            }
            return .table(align: align, blockId: nil, children: children(n))
        case "table_row", "table_header":
            return .tableRow(children: children(n))
        case "table_cell":
            return .tableCell(children: children(n))

        case "text":
            return .text(value: string(cmark_node_get_literal(n)))
        case "softbreak":
            return .text(value: "\n")
        case "linebreak":
            return .break
        case "code":
            return .inlineCode(value: string(cmark_node_get_literal(n)))
        case "html_inline":
            return .html(value: string(cmark_node_get_literal(n)))
        case "emph":
            return .emphasis(children: children(n))
        case "strong":
            return .strong(children: children(n))
        case "strikethrough":
            return .delete(children: children(n))
        case "link":
            return .link(url: string(cmark_node_get_url(n)), title: optional(cmark_node_get_title(n)), children: children(n))
        case "image":
            let alt = children(n).map(\.plainTextForFlanking).joined()
            return .image(url: string(cmark_node_get_url(n)), title: optional(cmark_node_get_title(n)), alt: alt)
        default:
            // Unknown extension output: keep its text rather than lose content.
            return .text(value: string(cmark_node_get_literal(n)))
        }
    }

    /// mdast's listItem `spread`: a blank line between two of the item's direct children.
    private func isSpread(_ item: Node) -> Bool {
        hasBlankBetween(childPointers(item))
    }

    /// Whether a blank line separates any two consecutive nodes.
    private func hasBlankBetween(_ nodes: [Node]) -> Bool {
        zip(nodes, nodes.dropFirst()).contains { a, b in
            let next = cmark_node_get_start_line(b)
            return next > contentEndLine(a, before: next) + 1
        }
    }

    /// The last line a node's content is on. cmark's end line is not always right:
    /// - for a container (a list item, or a nested list) it runs on through the blank lines after it;
    /// - for a setext heading it is the end of the *next* block;
    /// - a link reference definition leaves no node at all.
    ///
    /// So clamp it to before the next sibling's first line, then step back over blank source lines.
    private func contentEndLine(_ n: Node, before nextStart: Int32? = nil) -> Int32 {
        var end = cmark_node_get_end_line(n)
        if let nextStart { end = min(end, nextStart - 1) }
        let start = cmark_node_get_start_line(n)
        let depth = quoteDepth(n)
        while end > start, isBlank(line: end, insideQuotes: depth) { end -= 1 }
        return end
    }

    /// Whether a 1-based source line is blank for a node nested in `depth` blockquotes: empty
    /// once that many `>` markers are stripped. So `>` alone is blank inside a quote, but it is
    /// the quote's own content when seen from outside it.
    private func isBlank(line: Int32, insideQuotes depth: Int) -> Bool {
        guard line >= 1, Int(line) <= lines.count else { return true }
        var rest = Substring(lines[Int(line) - 1])
        for _ in 0..<depth {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == ">" else { break }
            rest = rest.dropFirst()
        }
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func quoteDepth(_ n: Node) -> Int {
        var depth = 0
        var p = cmark_node_parent(n)
        while let parent = p {
            if cmark_node_get_type(parent) == CMARK_NODE_BLOCK_QUOTE { depth += 1 }
            p = cmark_node_parent(parent)
        }
        return depth
    }

    /// SPEC §3.2: a footnote's identifier is its label lowercased.
    private func footnoteIdentifier(_ label: String) -> String {
        label.lowercased()
    }
}

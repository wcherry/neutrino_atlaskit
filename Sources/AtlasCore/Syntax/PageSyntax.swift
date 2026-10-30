import Foundation

/// Where each construct of a page sits in its source: what an editor needs to style Markdown in
/// place and, for Live Preview, to hide its syntax characters away from the cursor.
///
/// The tree decides *what* is there; this only finds *where*. Each top-level block's tree is
/// aligned against that block's text, character by character: delimiters, markers and escapes
/// become `.syntax` spans, and the constructs around them get spans of their own. A block is
/// `isComplete` when every character of its text was accounted for. Otherwise its spans stop
/// where alignment did, and the rest of the block is left plain. Wrong styling is the worst
/// that can happen: the text is never touched.
public struct PageSyntax: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public var node: MarkdownNode
        /// UTF-16 offsets into the page, from the block's first character to the end of its
        /// last line (the line ending excluded).
        public var range: Range<Int>
        /// Every character of the block's text was matched to its tree.
        public var isComplete: Bool
        /// The block's spans, ordered by start; a span that contains another comes first.
        public var spans: [SyntaxSpan]
    }

    /// In order. cmark-gfm lifts a footnote definition out of the quote or list item it was
    /// written in, so that definition's lines can also be inside the block before it.
    public var blocks: [Block]

    /// Every block's spans, ordered like `Block.spans`.
    public var spans: [SyntaxSpan] { blocks.flatMap(\.spans).sorted(by: SyntaxSpan.precedes) }
}

public struct SyntaxSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        // Blocks
        case frontmatter
        case heading(level: Int)
        case blockquote
        case callout(type: String)
        case listItem(ordered: Bool, checked: Bool?)
        case codeBlock(language: String?)
        case mathBlock
        case table
        case thematicBreak
        case htmlBlock
        case footnoteDefinition(identifier: String)
        // Inlines
        case strong, emphasis, strikethrough, highlight
        case inlineCode, inlineMath, inlineHTML
        case link(url: String)
        case image(url: String)
        case wikiLink(WikiLinkReference)
        case embed(WikiLinkReference)
        case tag(name: String)
        case footnoteReference(identifier: String)
        /// Characters that are Markdown syntax rather than content.
        case syntax(SyntaxRole)
    }

    public var kind: Kind
    /// UTF-16 offsets into the page, as `NSString` and TextKit count.
    public var range: Range<Int>

    public init(_ kind: Kind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    /// By start, and a span before the spans it contains.
    static func precedes(_ a: SyntaxSpan, _ b: SyntaxSpan) -> Bool {
        a.range.lowerBound != b.range.lowerBound ? a.range.lowerBound < b.range.lowerBound : a.range.upperBound > b.range.upperBound
    }
}

public enum SyntaxRole: Equatable, Sendable {
    /// `## ` and a closing `##`, or a setext underline.
    case headingMarker
    /// `>` and the space after it.
    case quoteMarker
    /// `-`, `*`, `+`, `1.` or `1)`.
    case listMarker
    /// `[ ]` or `[x]`.
    case taskMarker(checked: Bool)
    /// A code block's fence lines, info string included.
    case codeFence
    /// A math block's `$$` lines.
    case mathFence
    /// Frontmatter's `---` lines.
    case frontmatterFence
    /// `**`, `_`, `~~`, `==`, a code span's backticks, inline math's `$`.
    case delimiter
    /// A link's `[` and `]`, an image's `![` and `]`, an autolink's `<` and `>`, a footnote
    /// reference's `[^` and `]`.
    case linkBracket
    /// `(url "title")`, `[label]` or `[]` after a link's text.
    case linkDestination
    /// `[[`, `]]` and an embed's `![[`.
    case wikiBracket
    /// A wiki link's `Target|`, before an alias.
    case wikiTarget
    /// The backslash of an escape.
    case escape
    /// A callout's `[!type]` and fold sign.
    case calloutMarker
    case tablePipe
    case tableDelimiterRow
    /// A footnote definition's `[^label]:`.
    case footnoteLabel
    /// `^id` (SPEC §4.6).
    case blockId
    /// The backslash of a hard line break.
    case hardBreak
}

extension AtlasMarkdown {
    /// The page's syntax map: every top-level block, and where its constructs and syntax are.
    public static func syntax(of source: String) -> PageSyntax {
        let lines = SourcePreprocessor.splitLines(source)
        var lineStart = [0]
        lineStart.reserveCapacity(lines.count + 1)
        for l in lines { lineStart.append(lineStart.last! + l.content.utf16.count + l.ending.utf16.count) }

        var blocks: [PageSyntax.Block] = []
        for (node, range) in parseLayout(source) {
            let first = max(1, min(range.lowerBound, lines.count)), last = max(first, min(range.upperBound, lines.count))
            guard !lines.isEmpty, range.lowerBound <= lines.count else { continue }
            var text = ""
            for l in first...last { text += lines[l - 1].content; if l < last { text += lines[l - 1].ending } }
            var aligner = SyntaxAligner(text: text, offset: lineStart[first - 1])
            let complete = aligner.align(node)
            blocks.append(.init(node: node, range: lineStart[first - 1]..<(lineStart[first - 1] + text.utf16.count),
                                isComplete: complete, spans: aligner.spans.sorted(by: SyntaxSpan.precedes)))
        }
        return PageSyntax(blocks: blocks)
    }
}

/// Aligns one top-level block's tree with its text. Container prefixes (`>` and list-item
/// indentation) are consumed at the start of every line, as cmark does; a line without them
/// is a lazy continuation.
struct SyntaxAligner {
    private let c: [Character]
    /// `u16[k]` is the page offset of `c[k]`; one extra entry for the end.
    private let u16: [Int]
    private var i = 0
    private var prefixes: [Prefix] = []
    private(set) var spans: [SyntaxSpan] = []

    private enum Prefix { case quote, indent(Int) }
    private struct Mismatch: Error {}
    private struct State { var i: Int; var spans: Int; var prefixes: [Prefix] }

    init(text: String, offset: Int) {
        c = Array(text)
        var u = [offset]
        u.reserveCapacity(c.count + 1)
        for ch in c { u.append(u.last! + ch.utf16.count) }
        u16 = u
    }

    /// Aligns the block and reports whether every character was accounted for.
    mutating func align(_ node: MarkdownNode) -> Bool {
        if c.first == "\u{FEFF}" { i = 1 }
        do {
            try blocks([node])
        } catch {
            return false
        }
        // What's left can only be blank lines, and a quote's `>`-only lines.
        while i < c.count, c[i].isWhitespace || c[i] == ">" { i += 1 }
        return i == c.count
    }

    // MARK: Cursor

    private var state: State { State(i: i, spans: spans.count, prefixes: prefixes) }
    private mutating func restore(_ s: State) {
        i = s.i; spans.removeLast(spans.count - s.spans); prefixes = s.prefixes
    }

    private func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
    private var atEOL: Bool { i >= c.count || c[i].isNewline }
    private var restIsBlank: Bool {
        var k = i
        while k < c.count, c[k] == " " || c[k] == "\t" { k += 1 }
        return k >= c.count || c[k].isNewline
    }
    private func starts(with s: String, at k: Int) -> Bool {
        var k = k
        for ch in s { guard at(k) == ch else { return false }; k += 1 }
        return true
    }

    private mutating func skipSpaces() { while let ch = at(i), ch == " " || ch == "\t" { i += 1 } }
    private mutating func skipSpaces(upTo n: Int) { var k = 0; while k < n, at(i) == " " { i += 1; k += 1 } }
    private mutating func toEOL() { while i < c.count, !c[i].isNewline { i += 1 } }
    private mutating func expect(_ ch: Character) throws { guard at(i) == ch else { throw Mismatch() }; i += 1 }

    private mutating func mark(_ role: SyntaxRole, _ r: Range<Int>) {
        guard r.lowerBound < r.upperBound else { return }
        spans.append(SyntaxSpan(.syntax(role), u16[r.lowerBound]..<u16[r.upperBound]))
    }
    private mutating func span(_ kind: SyntaxSpan.Kind, from start: Int) {
        spans.append(SyntaxSpan(kind, u16[start]..<u16[i]))
    }

    /// Past a line ending and the container prefixes of the next line.
    private mutating func newline() throws {
        guard let ch = at(i), ch.isNewline else { throw Mismatch() }
        i += 1
        enterLine()
    }

    private mutating func enterLine() {
        for p in prefixes {
            switch p {
            case .quote:
                let save = i
                skipSpaces(upTo: 3)
                guard at(i) == ">" else { i = save; return }
                let start = i
                i += 1
                if at(i) == " " || at(i) == "\t" { i += 1 }
                mark(.quoteMarker, start..<i)
            case .indent(let width):
                var columns = 0
                while columns < width, let ch = at(i), ch == " " || ch == "\t" {
                    columns += ch == "\t" ? 4 - columns % 4 : 1
                    i += 1
                }
                if columns < width { return }
            }
        }
    }

    /// From the end of one block to the start of the next: the rest of the line, then any blank lines.
    private mutating func toNextBlock() {
        guard restIsBlank, i < c.count else { return }
        toEOL()
        guard (try? newline()) != nil else { return }
        while restIsBlank, i < c.count {
            let save = state
            toEOL()
            guard i < c.count else { restore(save); return }
            guard (try? newline()) != nil else { restore(save); return }
        }
    }

    private var lineLooksLikeReferenceDefinition: Bool {
        var k = i, n = 0
        while at(k) == " ", n < 3 { k += 1; n += 1 }
        guard at(k) == "[" else { return false }
        while let ch = at(k), !ch.isNewline {
            if ch == "]" { return at(k + 1) == ":" }
            k += 1
        }
        return false
    }

    // MARK: Blocks

    private mutating func blocks(_ kids: [MarkdownNode]) throws {
        for kid in kids {
            toNextBlock()
            while true {
                let save = state
                do {
                    try block(kid)
                    break
                } catch {
                    // A reference definition isn't in the tree; skip its line and try again.
                    restore(save)
                    guard lineLooksLikeReferenceDefinition else { throw error }
                    toEOL()
                    try newline()
                    toNextBlock()
                }
            }
        }
        // Definitions after the last block, or in a container with nothing else in it. A
        // footnote definition takes its continuation lines with it.
        while true {
            let save = state
            toNextBlock()
            guard lineLooksLikeReferenceDefinition else { restore(save); break }
            var k = i
            while at(k) == " " { k += 1 }
            let footnote = starts(with: "[^", at: k)
            toEOL()
            while footnote, i < c.count {
                let line = state
                guard (try? newline()) != nil, !restIsBlank else { restore(line); break }
                toEOL()
            }
        }
    }

    private mutating func block(_ node: MarkdownNode) throws {
        switch node {
        case .root(let kids):
            try blocks(kids)

        case .paragraph(let id, let kids):
            skipSpaces()
            try inlines(kids)
            if let id { try trailingBlockId(id) }
            skipSpaces()

        case .heading(let depth, let kids):
            let start = i
            skipSpaces(upTo: 3)
            var run = 0
            while at(i + run) == "#" { run += 1 }
            let atx = run > 0 && (at(i + run) == nil || at(i + run) == " " || at(i + run) == "\t" || at(i + run)!.isNewline)
            if atx {
                let m = i
                while at(i) == "#" { i += 1 }
                guard i - m == depth else { throw Mismatch() }
                skipSpaces()
                mark(.headingMarker, m..<i)
                try inlines(kids)
                let save = i
                skipSpaces()
                if at(i) == "#" {
                    while at(i) == "#" { i += 1 }
                    skipSpaces()
                    if atEOL { mark(.headingMarker, save..<i) } else { i = save }
                }
                skipSpaces()
            } else {
                try inlines(kids)
                skipSpaces()
                try newline()
                skipSpaces(upTo: 3)
                let m = i
                guard let ch = at(i), ch == "=" || ch == "-" else { throw Mismatch() }
                while at(i) == ch { i += 1 }
                skipSpaces()
                guard atEOL else { throw Mismatch() }
                mark(.headingMarker, m..<i)
            }
            span(.heading(level: depth), from: start)

        case .thematicBreak:
            let start = i
            toEOL()
            span(.thematicBreak, from: start)

        case .code(let lang, _, let value, let id):
            let start = i
            try codeBlock(value: value)
            span(.codeBlock(language: lang), from: start)
            if let id { standaloneBlockId(id) }

        case .math(_, _, let id):
            let start = i
            skipSpaces(upTo: 3)
            guard starts(with: "$$", at: i) else { throw Mismatch() }
            let f = i
            toEOL()
            mark(.mathFence, f..<i)
            while true {
                try newline()
                let line = i
                toEOL()
                if String(c[line..<i]).range(of: #"^ {0,3}\$\$[ \t]*$"#, options: .regularExpression) != nil {
                    mark(.mathFence, line..<i)
                    break
                }
            }
            span(.mathBlock, from: start)
            if let id { standaloneBlockId(id) }

        case .html(let value):
            let start = i
            toEOL()
            for _ in 0..<value.filter({ $0 == "\n" }).count { try newline(); toEOL() }
            span(.htmlBlock, from: start)

        case .blockquote(let id, let kids):
            let start = i
            try quoteMarker()
            prefixes.append(.quote)
            try blocks(kids)
            prefixes.removeLast()
            span(.blockquote, from: start)
            if let id { standaloneBlockId(id) }

        case .callout(let type, _, let title, let id, let kids):
            let start = i
            try quoteMarker()
            prefixes.append(.quote)
            skipSpaces()
            guard starts(with: "[!", at: i) else { throw Mismatch() }
            let m = i
            while let ch = at(i), ch != "]", !ch.isNewline { i += 1 }
            try expect("]")
            if at(i) == "+" || at(i) == "-" { i += 1 }
            mark(.calloutMarker, m..<i)
            skipSpaces()
            try inlines(title ?? [])
            var idUsed = false
            if let id {
                let save = state
                if (try? trailingBlockId(id)) != nil { idUsed = true } else { restore(save) }
            }
            try blocks(kids)
            prefixes.removeLast()
            span(.callout(type: type), from: start)
            if let id, !idUsed { standaloneBlockId(id) }

        case .list(let ordered, _, _, let id, let items):
            for item in items {
                toNextBlock()
                guard case .listItem(let checked, _, let kids) = item else { throw Mismatch() }
                try listItem(ordered: ordered, checked: checked, kids)
            }
            if let id { standaloneBlockId(id) }

        case .table(_, let id, let rows):
            let start = i
            for (r, row) in rows.enumerated() {
                if r > 0 { try newline() }
                if r == 1 {
                    let d = i
                    toEOL()
                    mark(.tableDelimiterRow, d..<i)
                    try newline()
                }
                try tableRow(row.children)
            }
            if rows.count == 1 {
                // A header with no body: the delimiter row still follows.
                try newline()
                let d = i
                toEOL()
                mark(.tableDelimiterRow, d..<i)
            }
            span(.table, from: start)
            if let id { standaloneBlockId(id) }

        case .footnoteDefinition(let identifier, _, let kids):
            let start = i
            // cmark-gfm lifts a definition out of the quote or list item it was written in, and
            // reports it at the top level from the container's markers.
            while let ch = at(i), " \t>-+*.)0123456789".contains(ch), !starts(with: "[^", at: i) { i += 1 }
            guard starts(with: "[^", at: i) else { throw Mismatch() }
            let m = i
            while let ch = at(i), ch != "]", !ch.isNewline { i += 1 }
            try expect("]")
            try expect(":")
            mark(.footnoteLabel, m..<i)
            skipSpaces()
            prefixes.append(.indent(4))
            try blocks(kids)
            prefixes.removeLast()
            span(.footnoteDefinition(identifier: identifier), from: start)

        case .yaml:
            let start = i
            toEOL()
            mark(.frontmatterFence, start..<i)
            var line = i
            while i < c.count {
                try newline()
                line = i
                toEOL()
            }
            mark(.frontmatterFence, line..<i)
            span(.frontmatter, from: start)

        case .listItem, .tableRow, .tableCell:
            throw Mismatch()

        default:
            // An inline at block level can't happen; align it anyway.
            try inline(node)
        }
    }

    private mutating func quoteMarker() throws {
        skipSpaces(upTo: 3)
        let m = i
        try expect(">")
        if at(i) == " " || at(i) == "\t" { i += 1 }
        mark(.quoteMarker, m..<i)
    }

    private mutating func codeBlock(value: String) throws {
        let save = i
        skipSpaces(upTo: 3)
        let lineCount = value.isEmpty ? 0 : value.filter({ $0 == "\n" }).count + 1
        guard let fenceChar = at(i), fenceChar == "`" || fenceChar == "~", starts(with: String(repeating: fenceChar, count: 3), at: i) else {
            // Indented.
            i = save
            toEOL()
            for _ in 1..<max(lineCount, 1) { try newline(); toEOL() }
            return
        }
        let f = i
        var n = 0
        while at(i) == fenceChar { i += 1; n += 1 }
        toEOL()
        mark(.codeFence, f..<i)
        // An empty value is no lines or one blank line; try both.
        for count in value.isEmpty ? [0, 1] : [lineCount] {
            let before = state
            var ok = true
            for _ in 0..<count {
                if (try? newline()) == nil { ok = false; break }
                toEOL()
            }
            if ok, closingFence(fenceChar, n) { return }
            restore(before)
        }
        // Unclosed: it runs to the end of its container.
        for _ in 0..<lineCount { try newline(); toEOL() }
    }

    private mutating func closingFence(_ ch: Character, _ n: Int) -> Bool {
        let save = state
        guard (try? newline()) != nil else { restore(save); return false }
        skipSpaces(upTo: 3)
        let f = i
        var m = 0
        while at(i) == ch { i += 1; m += 1 }
        skipSpaces()
        guard m >= n, atEOL else { restore(save); return false }
        mark(.codeFence, f..<i)
        return true
    }

    private mutating func listItem(ordered: Bool, checked: Bool?, _ kids: [MarkdownNode]) throws {
        let start = i
        var lead = 0
        while at(i) == " ", lead < 3 { i += 1; lead += 1 }
        let m = i
        if ordered {
            while let ch = at(i), ch.isASCII, ch.isNumber { i += 1 }
            guard i > m, at(i) == "." || at(i) == ")" else { throw Mismatch() }
            i += 1
        } else {
            guard let ch = at(i), ch == "-" || ch == "*" || ch == "+" else { throw Mismatch() }
            i += 1
        }
        mark(.listMarker, m..<i)
        let markerWidth = i - m
        var width: Int
        if restIsBlank {
            width = lead + markerWidth + 1
        } else {
            var spaces = 0, k = i
            while let ch = at(k), ch == " " || ch == "\t" { spaces += ch == "\t" ? 4 - (lead + markerWidth + spaces) % 4 : 1; k += 1 }
            if spaces >= 5 {
                width = lead + markerWidth + 1
                i += 1
            } else {
                width = lead + markerWidth + spaces
                i = k
            }
        }
        if let checked {
            let t = i
            guard at(i) == "[", let box = at(i + 1), box == " " || box == "x" || box == "X", at(i + 2) == "]" else { throw Mismatch() }
            i += 3
            mark(.taskMarker(checked: checked), t..<i)
            skipSpaces()
        }
        prefixes.append(.indent(width))
        try blocks(kids)
        prefixes.removeLast()
        span(.listItem(ordered: ordered, checked: checked), from: start)
    }

    private mutating func tableRow(_ cells: [MarkdownNode]) throws {
        skipSpaces()
        if at(i) == "|" { mark(.tablePipe, i..<(i + 1)); i += 1 }
        for cell in cells {
            skipSpaces()
            if atEOL {
                // GFM pads a short row with empty cells.
                guard cell.children.isEmpty else { throw Mismatch() }
                continue
            }
            try inlines(cell.children)
            skipSpaces()
            if at(i) == "|" { mark(.tablePipe, i..<(i + 1)); i += 1 } else if !atEOL { throw Mismatch() }
        }
        // GFM drops the cells beyond the header's count.
        toEOL()
    }

    private mutating func trailingBlockId(_ id: String) throws {
        skipSpaces()
        let m = i
        try expect("^")
        for ch in id { try expect(ch) }
        mark(.blockId, m..<i)
        skipSpaces()
        guard atEOL else { throw Mismatch() }
    }

    /// A `^id` paragraph after a block names it and leaves the tree (SPEC §4.6).
    private mutating func standaloneBlockId(_ id: String) {
        let save = state
        guard restIsBlank, i < c.count else { return }
        toEOL()
        guard (try? newline()) != nil else { restore(save); return }
        toNextBlock()
        if (try? trailingBlockId(id)) == nil { restore(save) }
    }

    // MARK: Inlines

    private mutating func inlines(_ nodes: [MarkdownNode]) throws {
        for n in nodes { try inline(n) }
    }

    private mutating func inline(_ node: MarkdownNode) throws {
        let start = i
        switch node {
        case .text(let value):
            let v = Array(value)
            var k = 0
            while k < v.count { k += try character(v, k) }

        case .break:
            skipSpaces()
            if at(i) == "\\" { mark(.hardBreak, i..<(i + 1)); i += 1 }
            try newline()
            skipSpaces()

        case .strong(let kids):
            try delimited(.strong, count: 2, kids) { $0 == "*" || $0 == "_" }
        case .emphasis(let kids):
            try delimited(.emphasis, count: 1, kids) { $0 == "*" || $0 == "_" }
        case .highlight(let kids):
            try delimited(.highlight, count: 2, kids) { $0 == "=" }
        case .delete(let kids):
            try delimited(.strikethrough, count: at(i + 1) == "~" ? 2 : 1, kids) { $0 == "~" }

        case .inlineCode:
            guard at(i) == "`" else { throw Mismatch() }
            var n = 0
            while at(i) == "`" { i += 1; n += 1 }
            mark(.delimiter, start..<i)
            while true {
                guard let ch = at(i) else { throw Mismatch() }
                if ch == "`" {
                    let r = i
                    var m = 0
                    while at(i) == "`" { i += 1; m += 1 }
                    if m == n { mark(.delimiter, r..<i); break }
                } else if ch.isNewline {
                    try newline()
                } else {
                    i += 1
                }
            }
            span(.inlineCode, from: start)

        case .inlineMath:
            guard at(i) == "$", let (end, _) = SourcePreprocessor.inlineMath(c, at: i) else { throw Mismatch() }
            let n = at(i + 1) == "$" ? 2 : 1
            mark(.delimiter, i..<(i + n))
            mark(.delimiter, (end - n)..<end)
            i = end
            span(.inlineMath, from: start)

        case .wikiLink(let ref), .embed(let ref):
            guard let ch = at(i), ch == "[" || ch == "!", let (end, _) = SourcePreprocessor.wikiLink(c, at: i) else { throw Mismatch() }
            let isEmbed = ch == "!"
            let open = i + (isEmbed ? 3 : 2)
            mark(.wikiBracket, i..<open)
            if ref.alias != nil, let bar = (open..<(end - 2)).first(where: { c[$0] == "|" }) {
                mark(.wikiTarget, open..<(bar + 1))
            }
            mark(.wikiBracket, (end - 2)..<end)
            i = end
            span(isEmbed ? .embed(ref) : .wikiLink(ref), from: start)

        case .tag(let name):
            try expect("#")
            for ch in name { try expect(ch) }
            span(.tag(name: name), from: start)

        case .footnoteReference(let identifier, _):
            guard starts(with: "[^", at: i) else { throw Mismatch() }
            mark(.linkBracket, i..<(i + 2))
            i += 2
            while let ch = at(i), ch != "]", !ch.isNewline { i += 1 }
            let close = i
            try expect("]")
            mark(.linkBracket, close..<i)
            span(.footnoteReference(identifier: identifier), from: start)

        case .html(let value):
            for ch in value {
                if ch.isNewline { try newline(); skipSpaces() } else { try expect(ch) }
            }
            span(.inlineHTML, from: start)

        case .link(let url, _, let kids):
            if at(i) == "[" {
                mark(.linkBracket, i..<(i + 1))
                i += 1
                try inlines(kids)
                let close = i
                try expect("]")
                mark(.linkBracket, close..<i)
                if at(i) == "(", let end = destinationEnd(from: i) {
                    mark(.linkDestination, i..<end); i = end
                } else if at(i) == "[", let end = labelEnd(from: i) {
                    mark(.linkDestination, i..<end); i = end
                }
            } else if at(i) == "<" {
                mark(.linkBracket, i..<(i + 1))
                while let ch = at(i), ch != ">", !ch.isNewline { i += 1 }
                let close = i
                try expect(">")
                mark(.linkBracket, close..<i)
            } else {
                // A GFM autolink: the text is the link.
                try inlines(kids)
            }
            span(.link(url: url), from: start)

        case .image(let url, _, _):
            guard starts(with: "![", at: i) else { throw Mismatch() }
            mark(.linkBracket, i..<(i + 2))
            i += 2
            var depth = 0
            while true {
                guard let ch = at(i) else { throw Mismatch() }
                if ch == "\\" { i += 2; continue }
                if ch == "[" { depth += 1 }
                if ch == "]" { if depth == 0 { break }; depth -= 1 }
                if ch.isNewline { try newline(); continue }
                i += 1
            }
            mark(.linkBracket, i..<(i + 1))
            i += 1
            if at(i) == "(", let end = destinationEnd(from: i) {
                mark(.linkDestination, i..<end); i = end
            } else if at(i) == "[", let end = labelEnd(from: i) {
                mark(.linkDestination, i..<end); i = end
            }
            span(.image(url: url), from: start)

        default:
            throw Mismatch()
        }
    }

    /// Matches `v[k]`, the next character of a text node, and returns how many of `v` it used:
    /// the character itself, an escape for it, or a character reference that decodes to it.
    private mutating func character(_ v: [Character], _ k: Int) throws -> Int {
        let ch = v[k]
        guard let s = at(i) else { throw Mismatch() }
        if s == "&", let end = entityEnd(from: i) {
            let entity = c[i..<end]
            // Kept as written (a GFM autolink's text, an unknown name): match it literally.
            if k + entity.count <= v.count, v[k..<(k + entity.count)].elementsEqual(entity) {
                i = end
                return entity.count
            }
            if Self.decode(String(entity)).map({ $0 == ch }) ?? (s != ch) {
                i = end
                return 1
            }
        }
        if ch.isNewline {
            // A soft line break: trailing spaces, the ending, the prefixes, leading spaces.
            skipSpaces()
            try newline()
            skipSpaces()
            return 1
        }
        if s == "\\", let next = at(i + 1), next == ch, next.isASCII, next.isPunctuation || next.isSymbol {
            mark(.escape, i..<(i + 1))
            i += 2
            return 1
        }
        guard s == ch else { throw Mismatch() }
        i += 1
        return 1
    }

    private mutating func delimited(_ kind: SyntaxSpan.Kind, count n: Int, _ kids: [MarkdownNode], _ allowed: (Character) -> Bool) throws {
        let start = i
        guard let d = at(i), allowed(d), (0..<n).allSatisfy({ at(i + $0) == d }) else { throw Mismatch() }
        i += n
        mark(.delimiter, start..<i)
        try inlines(kids)
        guard (0..<n).allSatisfy({ at(i + $0) == d }) else { throw Mismatch() }
        mark(.delimiter, i..<(i + n))
        i += n
        span(kind, from: start)
    }

    // MARK: Link pieces

    /// The end of `(destination "title")` starting at `k`.
    private func destinationEnd(from k: Int) -> Int? {
        var j = k + 1
        func skipWhitespace() { while let ch = at(j), ch.isWhitespace { j += 1 } }
        skipWhitespace()
        if at(j) == "<" {
            while let ch = at(j), ch != ">" { if ch == "\\" { j += 1 }; if ch.isNewline { return nil }; j += 1 }
            guard at(j) == ">" else { return nil }
            j += 1
        } else {
            var depth = 0
            while let ch = at(j) {
                if ch == "\\" { j += 2; continue }
                if ch.isWhitespace { break }
                if ch == "(" { depth += 1 }
                if ch == ")" { if depth == 0 { break }; depth -= 1 }
                j += 1
            }
        }
        skipWhitespace()
        if let open = at(j), open == "\"" || open == "'" || open == "(" {
            let close: Character = open == "(" ? ")" : open
            j += 1
            while let ch = at(j), ch != close { if ch == "\\" { j += 1 }; j += 1 }
            guard at(j) == close else { return nil }
            j += 1
            skipWhitespace()
        }
        return at(j) == ")" ? j + 1 : nil
    }

    /// The end of a reference label `[label]` (or `[]`) starting at `k`.
    private func labelEnd(from k: Int) -> Int? {
        var j = k + 1
        while let ch = at(j), ch != "]" {
            if ch == "\\" { j += 1 }
            if ch == "[" { return nil }
            j += 1
        }
        return at(j) == "]" ? j + 1 : nil
    }

    /// The end of a character reference (`&amp;`, `&#38;`, `&#x26;`) starting at `k`.
    private func entityEnd(from k: Int) -> Int? {
        var j = k + 1
        while let ch = at(j), j - k <= 32, ch.isASCII, ch.isLetter || ch.isNumber || ch == "#" { j += 1 }
        return j > k + 1 && at(j) == ";" ? j + 1 : nil
    }

    private static let entities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
    ]

    /// What a character reference decodes to, when that's known here. Nil for named references
    /// outside the short table above: the caller then assumes it decoded to the expected character.
    private static func decode(_ entity: String) -> Character? {
        let body = entity.dropFirst().dropLast()
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let hex = digits.first == "x" || digits.first == "X"
            guard let v = UInt32(hex ? String(digits.dropFirst()) : String(digits), radix: hex ? 16 : 10) else { return nil }
            return Unicode.Scalar(v).map(Character.init) ?? "\u{FFFD}"
        }
        return entities[String(body)]
    }
}

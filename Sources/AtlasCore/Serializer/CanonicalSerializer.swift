import Foundation

extension AtlasMarkdown {
    /// Writes a tree in canonical form (SPEC §8.3). Parsing the result gives the same tree back
    /// (§8.4). Output always uses `\n` line endings and ends with exactly one.
    public static func serializeCanonical(_ root: MarkdownNode) -> String {
        let blocks = root.children
        var written: [String] = []
        for (i, block) in blocks.enumerated() {
            written.append(serializeBlock(block, after: i > 0 ? blocks[i - 1] : nil, previousText: written.last, atFileStart: i == 0).text)
        }
        guard !written.isEmpty else { return "" }
        return written.joined(separator: "\n\n") + "\n"
    }

    /// One top-level block in canonical form, without a trailing line ending. `after` and
    /// `previousText` are the block before it, which decides list markers (§8.3) and is the
    /// context escapes are checked in.
    /// `exact` is false when no form of the block parses back to it: the text is the best
    /// effort (everything escaped), and reopening the page would give a slightly different tree.
    static func serializeBlock(_ block: MarkdownNode, after previous: MarkdownNode?, previousText: String?, atFileStart: Bool) -> (text: String, exact: Bool) {
        let resolver = EscapeResolver(block: block, previous: previous, previousText: previousText, atFileStart: atFileStart)
        let text = resolver.resolve()
        return (text, resolver.roundTrips(text))
    }
}

/// Decides which characters to escape (SPEC §8.3, "Escaping").
///
/// Candidates are the characters of the block's text that can be escaped:
/// - ASCII punctuation, escaped with `\`;
/// - spaces, tabs and line endings, escaped as decimal character references (`&#32;`, `&#9;`,
///   `&#10;`).
///
/// The pass: start from a version of the block that round-trips, with a set of candidates
/// escaped. Visit those candidates right to left. Unescape each one, and keep it unescaped
/// only if the block still parses back to the same tree. The candidates to its left are still
/// escaped at that point, so the result escapes the leftmost character of any construct that
/// needs breaking (`\[[x]]`, `\==mark==`).
///
/// Attempts, in order:
/// 1. Punctuation escaped, whitespace literal. Run the pass over punctuation.
/// 2. Everything escaped. Run the pass over all candidates. Escaping whitespace isn't neutral
///    (`&#32;` before `www.` stops it being an autolink), so whitespace is only considered
///    when attempt 1 can't round-trip.
/// 3. Attempts 1 and 2 again for each fallback form of autolinks: bare, then `[text](url)`.
/// 4. Everything escaped, with inline autolinks, as written.
private struct EscapeResolver {
    let block: MarkdownNode
    let previous: MarkdownNode?
    let previousText: String?
    let atFileStart: Bool

    func resolve() -> String {
        for form in AutolinkForm.allCases {
            if let text = attempt(autolinks: form) { return text }
        }
        return write(escaping: { _ in true }, autolinks: .inline).text
    }

    /// Attempts 1 and 2 for one autolink form, or nil if neither starting point round-trips.
    private func attempt(autolinks form: AutolinkForm) -> String? {
        let all = write(escaping: { _ in true }, autolinks: form)
        let punctuation = Set(0..<all.count).subtracting(all.whitespace)
        if roundTrips(write(escaping: { punctuation.contains($0) }, autolinks: form).text) {
            return pass(over: punctuation, escaped: punctuation, autolinks: form)
        }
        if roundTrips(all.text) {
            let everything = Set(0..<all.count)
            return pass(over: everything, escaped: everything, autolinks: form)
        }
        return nil
    }

    /// Unescapes `candidates` right to left, keeping each unescaped only if the block still
    /// round-trips.
    private func pass(over candidates: Set<Int>, escaped start: Set<Int>, autolinks form: AutolinkForm) -> String {
        var escaped = start
        for i in candidates.sorted(by: >) {
            escaped.remove(i)
            if !roundTrips(write(escaping: { escaped.contains($0) }, autolinks: form).text) { escaped.insert(i) }
        }
        return write(escaping: { escaped.contains($0) }, autolinks: form).text
    }

    private func write(escaping: @escaping (Int) -> Bool, autolinks: AutolinkForm) -> (text: String, count: Int, whitespace: Set<Int>) {
        var writer = BlockWriter(escape: escaping, autolinks: autolinks)
        let lines = writer.block(block, previous: previous, atFileStart: atFileStart)
        return (lines.joined(separator: "\n"), writer.candidateCount, writer.whitespaceCandidates)
    }

    /// Whether `text` parses back to `block`, in context: after the previous block (list
    /// markers, standalone block ids), and with the footnotes it refers to defined, so they
    /// aren't dropped as unused or unresolved.
    func roundTrips(_ text: String) -> Bool {
        var doc = ""
        var offset = 0
        if let previousText {
            doc += previousText + "\n\n"
            offset = AtlasMarkdown.parse(previousText + "\n").children.count
        }
        if case .footnoteDefinition(_, let label, _) = block {
            doc = "[^\(label ?? "")]\n\n" + doc
            offset += 1
        }
        doc += text + "\n"
        for label in footnoteLabels(in: block) { doc += "\n[^\(label)]: x\n" }
        let parsed = AtlasMarkdown.parse(doc).children
        return offset < parsed.count && parsed[offset] == block
    }

    private func footnoteLabels(in node: MarkdownNode) -> [String] {
        if case .footnoteReference(_, let label) = node { return [label ?? ""] }
        if case .callout(_, _, let title, _, let kids) = node {
            return ((title ?? []) + kids).flatMap(footnoteLabels)
        }
        return node.children.flatMap(footnoteLabels)
    }
}

/// Writes blocks and inlines in canonical form. Candidate characters for escaping are numbered
/// in the order they are written; `escape` says which to escape.
struct BlockWriter {
    let escape: (Int) -> Bool
    /// How links whose text is their url are written. `.angle` is canonical; the others are
    /// fallbacks for when it doesn't round-trip.
    var autolinks: AutolinkForm = .angle
    private(set) var candidateCount = 0
    /// The candidates escaped as character references: whitespace, and non-ASCII punctuation
    /// and symbols. Only considered once escaping punctuation alone can't round-trip.
    private(set) var whitespaceCandidates = Set<Int>()
    /// Set right after a bare `www.` link. cmark-gfm's autolink extension reads raw source, so a
    /// backslash written before the next whitespace would become part of the link. Until then,
    /// text is written as is and has no candidates.
    private var afterBareLink = false

    init(escape: @escaping (Int) -> Bool, autolinks: AutolinkForm = .angle) {
        self.escape = escape
        self.autolinks = autolinks
    }

    // MARK: Blocks

    /// A block's lines, without line endings.
    /// `atFileStart`: the block's first line is the file's first line. `afterParagraphLine`: the
    /// line above is a paragraph line with no blank line between. `inDashItem`: the block opens a
    /// `-` list item, on the marker's line. Each decides how a thematic break is written.
    mutating func block(_ node: MarkdownNode, previous: MarkdownNode?, atFileStart: Bool = false,
                        afterParagraphLine: Bool = false, inDashItem: Bool = false) -> [String] {
        var lines: [String]
        switch node {
        case .paragraph(let id, let kids):
            lines = inline(kids).components(separatedBy: "\n")
            if let id { lines[lines.count - 1] += " ^\(id)" }
            return lines
        case .heading(let depth, let kids):
            let text = inline(kids)
            if text.contains("\n"), depth <= 2 {
                // A heading whose text spans lines can only be written setext.
                let body = text.components(separatedBy: "\n")
                return body + [String(repeating: depth == 1 ? "=" : "-", count: 3)]
            }
            return [text.isEmpty ? String(repeating: "#", count: depth) : String(repeating: "#", count: depth) + " " + text]
        case .thematicBreak:
            // `---` would open frontmatter, read as a list item's own break, or underline a
            // setext heading in these places.
            return [atFileStart || afterParagraphLine || inDashItem ? "***" : "---"]
        case .code(let lang, let meta, let value, _):
            let info = Self.escapeEntitiesAndBackslashes([lang, meta].compactMap { $0 }.joined(separator: " "))
            // Backtick fences can't carry an info string containing a backtick: use tildes.
            let char: Character = info.contains("`") ? "~" : "`"
            let fence = String(repeating: char, count: max(3, SourcePreprocessor.longestRun(of: char, in: value) + 1))
            lines = [fence + info] + (value.isEmpty ? [] : value.components(separatedBy: "\n")) + [fence]
        case .math(_, let value, _):
            lines = ["$$"] + value.components(separatedBy: "\n") + ["$$"]
        case .html(let value):
            return value.components(separatedBy: "\n")
        case .yaml(let value):
            return ["---"] + (value.isEmpty ? [] : value.components(separatedBy: "\n")) + ["---"]
        case .blockquote(_, let kids):
            lines = kids.isEmpty ? [">"] : quote(blocks(kids, tight: false))
        case .callout(let type, let fold, let title, _, let kids):
            var head = "[!\(type)]" + (fold?.rawValue ?? "")
            if let title { head += " " + inline(title) }
            var body: [String] = [head]
            if case .paragraph? = kids.first {
                body += block(kids[0], previous: nil)
                let rest = blocks(Array(kids.dropFirst()), tight: false)
                if !rest.isEmpty { body += [""] + rest }
            } else if !kids.isEmpty {
                body += [""] + blocks(kids, tight: false)
            }
            lines = quote(body)
        case .list(let ordered, let start, let spread, _, let items):
            lines = list(ordered: ordered, start: start ?? 1, spread: spread, items: items, previous: previous)
        case .table(let align, _, let rows):
            lines = table(align: align, rows: rows)
        case .footnoteDefinition(_, let label, let kids):
            let inner = blocks(kids, tight: false)
            let head = "[^\(label ?? "")]:"
            guard let first = inner.first else { return [head] }
            lines = [head + " " + first] + inner.dropFirst().map { $0.isEmpty ? "" : "    " + $0 }
            return lines
        default:
            return [inline([node])]
        }
        // Standalone block id (§4.6): a blank line, then `^id`.
        if let id = node.blockId, !(node.isParagraph) { lines += ["", "^\(id)"] }
        return lines
    }

    /// Sibling blocks: one blank line between them, or none in a tight list item.
    mutating func blocks(_ kids: [MarkdownNode], tight: Bool, inDashItem: Bool = false) -> [String] {
        var out: [String] = []
        for (i, kid) in kids.enumerated() {
            if i > 0 && !tight { out.append("") }
            let afterParagraph = tight && i > 0 && kids[i - 1].isParagraph
            out += block(kid, previous: i > 0 ? kids[i - 1] : nil, afterParagraphLine: afterParagraph, inDashItem: inDashItem && i == 0)
        }
        return out
    }

    private func quote(_ lines: [String]) -> [String] {
        lines.map { $0.isEmpty ? ">" : "> " + $0 }
    }

    private mutating func list(ordered: Bool, start: Int, spread: Bool, items: [MarkdownNode], previous: MarkdownNode?) -> [String] {
        // Two adjacent lists of the same kind and marker would merge, so alternate.
        var alternate = false
        if case .list(let previousOrdered, _, _, _, _)? = previous, previousOrdered == ordered { alternate = true }
        var out: [String] = []
        for (i, item) in items.enumerated() {
            guard case .listItem(let checked, let itemSpread, let kids) = item else { continue }
            if i > 0 && spread { out.append("") }
            let marker = ordered ? "\(start + i)" + (alternate ? ")" : ".") : (alternate ? "*" : "-")
            let indent = String(repeating: " ", count: marker.count + 1)
            var inner = blocks(kids, tight: !itemSpread, inDashItem: marker == "-" && checked == nil)
            if let checked {
                let box = checked ? "[x]" : "[ ]"
                if inner.isEmpty { inner = [box] } else { inner[0] = box + " " + inner[0] }
            }
            guard let first = inner.first else { out.append(marker); continue }
            out.append(first.isEmpty ? marker : marker + " " + first)
            out += inner.dropFirst().map { $0.isEmpty ? "" : indent + $0 }
        }
        return out
    }

    private mutating func table(align: [TableAlignment?], rows: [MarkdownNode]) -> [String] {
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var out: [String] = []
        for (i, r) in rows.enumerated() {
            let cells = r.children.map { cell -> String in inline(cell.children, inTable: true) }
            out.append(row(cells))
            if i == 0 {
                out.append(row(align.map {
                    switch $0 {
                    case .left: return ":--"
                    case .right: return "--:"
                    case .center: return ":-:"
                    case nil: return "---"
                    }
                }))
            }
        }
        return out
    }

    // MARK: Inlines

    /// `delimiter` is the emphasis character of the enclosing emphasis or strong, if any.
    mutating func inline(_ nodes: [MarkdownNode], inTable: Bool = false, delimiter: Character? = nil) -> String {
        var out = ""
        for (i, node) in nodes.enumerated() {
            // An emphasis directly inside an emphasis or strong uses `_` (`**foo**` would read as
            // strong, `*]*!*^*` would pair the wrong delimiters), unless a neighbouring character
            // is a letter or digit, where `_` can't open or close. A strong keeps `*`:
            // `***x***` is emphasis around strong, and `__` can't open inside a word.
            var own: Character = "*"
            if delimiter == "*", case .emphasis = node {
                let left = i == 0 ? nil : nodes[i - 1].plainTextForFlanking.last
                let right = i == nodes.count - 1 ? nil : nodes[i + 1].plainTextForFlanking.first
                if !(left.map(\.isAlphanumeric) ?? false) && !(right.map(\.isAlphanumeric) ?? false) { own = "_" }
            }
            out += inline(node, inTable: inTable, delimiter: own, next: i + 1 < nodes.count ? nodes[i + 1] : nil)
        }
        return out
    }

    private mutating func inline(_ node: MarkdownNode, inTable: Bool, delimiter d: Character = "*", next: MarkdownNode? = nil) -> String {
        if case .text = node {} else { afterBareLink = false }
        switch node {
        case .text(let v):
            return text(v)
        case .emphasis(let k): return String(d) + inline(k, inTable: inTable, delimiter: d) + String(d)
        case .strong(let k): return String(repeating: d, count: 2) + inline(k, inTable: inTable, delimiter: d) + String(repeating: d, count: 2)
        case .delete(let k): return "~~" + inline(k, inTable: inTable) + "~~"
        case .highlight(let k): return "==" + inline(k, inTable: inTable) + "=="
        case .inlineCode(let v):
            let value = inTable ? v.replacingOccurrences(of: "|", with: "\\|") : v
            let ticks = String(repeating: "`", count: SourcePreprocessor.longestRun(of: "`", in: value) + 1)
            // Pad with a space when the content starts or ends with a backtick or space, unless it
            // is all spaces, which CommonMark never strips.
            let allSpaces = !value.isEmpty && value.allSatisfy { $0 == " " }
            let pad = !allSpaces && (value.hasPrefix(" ") || value.hasPrefix("`") || value.hasSuffix(" ") || value.hasSuffix("`"))
            return ticks + (pad ? " " : "") + value + (pad ? " " : "") + ticks
        case .break:
            return "\\\n"
        case .link(let url, let title, let kids):
            if title == nil, kids.count == 1, case .text(let t) = kids[0], autolinks != .inline {
                let scheme = ["http://", "https://", "ftp://"].contains(where: url.lowercased().hasPrefix)
                if autolinks == .bare, t == url, scheme { afterBareLink = true; return t }
                if t == url, isAutolinkable(url) { return "<" + url + ">" }
                if "mailto:" + t == url, isAutolinkable(t) { return "<" + t + ">" }
                if "http://" + t == url, t.hasPrefix("www.") { afterBareLink = true; return t }
            }
            return "[" + inline(kids, inTable: inTable) + "](" + destination(url) + titlePart(title) + ")"
        case .image(let url, let title, let alt):
            return "![" + text(alt) + "](" + destination(url) + titlePart(title) + ")"
        case .footnoteReference(_, let label):
            return "[^" + (label ?? "") + "]"
        case .wikiLink(let r):
            return wiki(r, inTable: inTable)
        case .embed(let r):
            return "!" + wiki(r, inTable: inTable)
        case .tag(let name):
            return "#" + name
        case .inlineMath(let v):
            // `$x$`, or `$$x$$`, whichever the parser's own scan reads back as exactly `x`
            // given the character that follows (a digit after `$` stops it closing).
            var after: Character? = nil
            if case .text(let t)? = next { after = t.first }
            for form in ["$" + v + "$", "$$" + v + "$$"] {
                let chars = Array(form) + (after.map { [$0] } ?? [])
                if let (end, token) = SourcePreprocessor.inlineMath(chars, at: 0), end == form.count,
                   case .inlineMath(let value, _) = token, value == v { return form }
            }
            return "$" + v + "$"
        case .html(let v):
            return v
        default:
            return inline(node.children, inTable: inTable)
        }
    }

    /// Text, with escape candidates (ASCII punctuation) numbered and escaped as decided.
    private mutating func text(_ value: String) -> String {
        var out = ""
        for c in value {
            if afterBareLink {
                // Up to and including the next whitespace, written as is: in raw source neither a
                // backslash nor `&#32;` ends the link.
                out.append(c)
                if c.isWhitespace { afterBareLink = false }
                continue
            }
            if c.isASCII, c.isPunctuation || c.isSymbol {
                if escape(candidateCount) { out.append("\\") }
                candidateCount += 1
                out.append(c)
            } else if c == " " || c == "\t" || c == "\n" || (!c.isASCII && (c.isPunctuation || c.isSymbol) && c.unicodeScalars.count == 1) {
                // Whitespace, and non-ASCII punctuation or symbols (whose neighbours' flanking can
                // differ from the entity they were written as): escaped as a character reference.
                let escaped = escape(candidateCount)
                whitespaceCandidates.insert(candidateCount)
                candidateCount += 1
                out += escaped ? "&#\(c.unicodeScalars.first!.value);" : String(c)
            } else {
                out.append(c)
            }
        }
        return out
    }



    private func wiki(_ r: WikiLinkReference, inTable: Bool) -> String {
        var s = "[[" + r.target
        if let h = r.heading { s += "#" + h }
        if let b = r.blockId { s += "#^" + b }
        if let a = r.alias { s += (inTable ? "\\|" : "|") + a }
        return s + "]]"
    }

    private func isAutolinkable(_ s: String) -> Bool {
        !s.isEmpty && !s.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "&" || $0 == "\\" })
    }

    /// A link destination. Backslashes, and `&` where it would start an entity, are escaped
    /// because destinations process both. Spaces, parentheses and angle brackets need `<…>`.
    private func destination(_ url: String) -> String {
        let escaped = Self.escapeEntitiesAndBackslashes(url)
        if url.isEmpty || url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) {
            return "<" + escaped.replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>") + ">"
        }
        return escaped
    }

    private func titlePart(_ title: String?) -> String {
        guard let title else { return "" }
        return " \"" + Self.escapeEntitiesAndBackslashes(title).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// For strings CommonMark processes for entities and backslash escapes (link destinations
    /// and titles, code info strings): backslashes doubled, `&` escaped where it would start an
    /// entity, and line endings as character references.
    static func escapeEntitiesAndBackslashes(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        if let regex = try? NSRegularExpression(pattern: "&(?=#?[A-Za-z0-9]+;)") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\\\\&")
        }
        // After the entity escape, so these references aren't escaped themselves.
        return out.replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
    }
}

/// How a link whose text is its own url is written (SPEC §8.3, "Autolinks").
enum AutolinkForm: CaseIterable {
    /// `<url>` and `<email>`, with `www.` links bare. Canonical.
    case angle
    /// URL links bare too, for urls only cmark-gfm's bare autolinker reads back (it sees raw
    /// source, so `http://a&amp;b` keeps its `&amp;`).
    case bare
    /// `[text](url)` for all of them.
    case inline
}

extension Character {
    fileprivate var isAlphanumeric: Bool { isLetter || isNumber }
}

extension MarkdownNode {
    var isParagraph: Bool { if case .paragraph = self { return true } else { return false } }
}

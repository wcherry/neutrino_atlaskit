import Foundation

/// Prepares Atlas Markdown source for cmark-gfm. Everything that depends on the *raw* source
/// text is decided here, before cmark processes escapes and inline syntax:
///
/// - **Frontmatter** (§4.1) is lifted out. Its lines are blanked, which keeps every line
///   number the same.
/// - **Math blocks** (§4.8) are rewritten as tilde-fenced code blocks with a sentinel info
///   string, so cmark keeps their content verbatim. Again, the line count doesn't change.
/// - **Escaped trigger characters** (`\#`, `\=`, `\^`, `\[`, `\$`) become private-use marker
///   characters. Later passes therefore see they were escaped, and cmark still treats them
///   as literal text.
/// - **Wiki links, embeds and inline math** (§4.2, §4.3, §4.8) are replaced by opaque
///   placeholder tokens. Their content is raw by spec, and cmark must not read emphasis,
///   escapes or links inside them.
///
/// The parser turns tokens back into nodes, or back into their raw text where the syntax is
/// not recognised (code, link text, URLs). Escape markers are restored the same way.
struct SourcePreprocessor {
    /// The text handed to cmark.
    var cmarkSource: String
    /// The frontmatter value (§4.1), if the page has frontmatter.
    var frontmatter: String?
    /// How many lines the frontmatter takes, both `---` lines included.
    var frontmatterLineCount = 0
    /// Placeholder tokens, indexed by the number encoded in the placeholder.
    var tokens: [Token]
    /// Where each wiki link, embed and inline math token came from: character offsets into the
    /// text inline protection ran on (the source without its BOM or frontmatter). In-place
    /// link rewrites (SPEC §8.2) use these.
    var tokenSourceRanges: [Int: Range<Int>] = [:]
    /// The code spans inline protection skipped, as character offsets like `tokenSourceRanges`.
    var codeSpanRanges: [Range<Int>] = []

    enum Token: Equatable {
        case wikiLink(WikiLinkReference, raw: String)
        case embed(WikiLinkReference, raw: String)
        case inlineMath(String, raw: String)
        /// A character from the private-use range the parser reserves, which the source already
        /// contained. It is protected so it can't be mistaken for a marker.
        case literal(String)

        var raw: String {
            switch self {
            case .wikiLink(_, let raw), .embed(_, let raw), .inlineMath(_, let raw): return raw
            case .literal(let s): return s
            }
        }
    }

    // MARK: Marker characters
    //
    // Escape markers and the two ends of every placeholder are Unicode *punctuation* that
    // cmark's own table also counts as punctuation (U+2E3C–U+2E42). The characters they stand
    // for (`\#`, `[[`, `$`, …) are punctuation, and emphasis flanking (`*x*`, `_x_`) depends on
    // whether a neighbour is punctuation. With letter-like markers, `*]*\^` would stop being
    // emphasis. The digits inside a placeholder are private-use characters, which never touch
    // a delimiter.

    static let tokenStart: Unicode.Scalar = "\u{2E3C}"
    static let tokenEnd: Unicode.Scalar = "\u{2E3D}"
    static let digitBase: UInt32 = 0xE020          // U+E020…U+E029 encode the token's index
    static let mathInfo = "\u{E0FF}atlas-math"     // info string of a rewritten math block

    /// Escaped characters the Atlas extensions care about, and the marker each becomes.
    static let escapeMarkers: [Character: Unicode.Scalar] = [
        "#": "\u{2E3E}", "=": "\u{2E3F}", "^": "\u{2E40}", "[": "\u{2E41}", "$": "\u{2E42}",
    ]
    static let escapedCharacter: [Unicode.Scalar: Character] =
        Dictionary(uniqueKeysWithValues: escapeMarkers.map { ($0.value, $0.key) })

    /// Characters the parser uses for its own bookkeeping. The user's own occurrences are
    /// protected as literal tokens.
    static func isReserved(_ s: Unicode.Scalar) -> Bool {
        (0xE000...0xE0FF).contains(s.value) || (0x2E3C...0x2E42).contains(s.value)
    }

    /// Reads the rest of a placeholder after its `tokenStart`: digits, then `tokenEnd`. Returns
    /// the token index, or nil (with the scalars it read) if the sequence is malformed, which
    /// callers then treat as plain text. It never traps, whatever the input.
    static func readToken(_ scalars: inout String.UnicodeScalarView.Iterator, count: Int) -> (index: Int?, read: [Unicode.Scalar]) {
        var index = 0, read: [Unicode.Scalar] = [], digits = 0
        while let d = scalars.next() {
            read.append(d)
            if d == tokenEnd { return (digits > 0 && index < count ? index : nil, read) }
            guard d.value >= digitBase, d.value <= digitBase + 9, digits < 9 else { return (nil, read) }
            index = index * 10 + Int(d.value - digitBase)
            digits += 1
        }
        return (nil, read)
    }

    static func placeholder(_ index: Int) -> String {
        var s = String(Character(tokenStart))
        for d in String(index) { s.unicodeScalars.append(Unicode.Scalar(digitBase + UInt32(d.wholeNumberValue!))!) }
        s.unicodeScalars.append(tokenEnd)
        return s
    }

    // MARK: -

    init(_ source: String) {
        var text = source
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        tokens = []

        var lines = Self.splitLines(text)
        frontmatter = Self.liftFrontmatter(&lines, lineCount: &frontmatterLineCount)
        cmarkSource = ""
        // Inline protection runs before math fencing so the fence's sentinel info string,
        // which is in the reserved range, isn't itself protected as a literal.
        var protected = Self.splitLines(protectInlines(lines.map { $0.content + $0.ending }.joined()))
        Self.fenceMathBlocks(&protected)
        cmarkSource = protected.map { $0.content + $0.ending }.joined()
    }

    struct Line { var content: String; var ending: String }

    static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var current = ""
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let s = pending ?? scalars.next() {
            pending = nil
            if s == "\n" {
                lines.append(Line(content: current, ending: "\n")); current = ""
            } else if s == "\r" {
                let next = scalars.next()
                if next == "\n" { lines.append(Line(content: current, ending: "\r\n")) }
                else { lines.append(Line(content: current, ending: "\r")); pending = next }
                current = ""
            } else {
                current.unicodeScalars.append(s)
            }
        }
        if !current.isEmpty { lines.append(Line(content: current, ending: "")) }
        return lines
    }

    /// §4.1: `---` as the very first line, closed by `---` or `...`. Without a closing line
    /// there is no frontmatter.
    static func liftFrontmatter(_ lines: inout [Line], lineCount: inout Int) -> String? {
        func isLine(_ l: Line, _ marks: Set<String>) -> Bool {
            marks.contains(String(l.content.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()))
        }
        guard let first = lines.first, isLine(first, ["---"]) else { return nil }
        guard let close = lines.indices.dropFirst().first(where: { isLine(lines[$0], ["---", "..."]) }) else { return nil }
        let value = lines[1..<close].map(\.content).joined(separator: "\n")
        for i in 0...close { lines[i].content = "" }
        lineCount = close + 1
        return value
    }

    /// §4.8: a line that is exactly `$$` (up to 3 spaces of indentation) opens a math block,
    /// closed by the next such line. Only at the top level of the document, and not inside a
    /// fenced code block. Without a closing line, the `$$` is ordinary text.
    static func fenceMathBlocks(_ lines: inout [Line]) {
        func isMathFence(_ s: String) -> Bool {
            s.range(of: #"^ {0,3}\$\$[ \t]*$"#, options: .regularExpression) != nil
        }
        var i = 0
        var openFence: (char: Character, count: Int)? = nil
        while i < lines.count {
            let content = lines[i].content
            if let fence = openFence {
                if let close = codeFence(content), close.char == fence.char, close.count >= fence.count, close.info.trimmingCharacters(in: .whitespaces).isEmpty {
                    openFence = nil
                }
            } else if let open = codeFence(content) {
                openFence = (open.char, open.count)
            } else if isMathFence(content), let close = lines.indices.dropFirst(i + 1).first(where: { isMathFence(lines[$0].content) }) {
                // A tilde fence longer than any tilde run in the content, so nothing closes it early.
                let longest = lines[(i + 1)..<close].map { longestRun(of: "~", in: $0.content) }.max() ?? 0
                let fence = String(repeating: "~", count: max(3, longest + 1))
                lines[i].content = fence + mathInfo
                lines[close].content = fence
                i = close
            }
            i += 1
        }
    }

    static func codeFence(_ line: String) -> (char: Character, count: Int, info: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let c = trimmed.first, c == "`" || c == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == c }).count
        guard count >= 3 else { return nil }
        let info = String(trimmed.dropFirst(count))
        if c == "`" && info.contains("`") { return nil }
        return (c, count, info)
    }

    static func longestRun(of c: Character, in s: String) -> Int {
        var best = 0, run = 0
        for ch in s { run = ch == c ? run + 1 : 0; best = max(best, run) }
        return best
    }

    // MARK: Inline protection

    /// One left-to-right pass over the source. Code spans and HTML/autolink tags are copied
    /// untouched, escapes become markers, and wiki links, embeds and inline math become tokens.
    mutating func protectInlines(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.unicodeScalars.contains(where: Self.isReserved) || Self.isHiddenCaret(chars, at: i) {
                out += protectReserved(c, chars, at: i); i += 1; continue
            }
            // Code spans and tags are copied as they are, except that reserved characters are
            // still protected, so that none of the user's text can pass for a marker.
            if c == "`" {
                // A backtick run is one unit (CommonMark): either it opens a code span, or the
                // whole run is literal text.
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                let end = Self.codeSpanEnd(chars, at: i) ?? i + run
                if end > i + run { codeSpanRanges.append(i..<end) }
                for k in i..<end { out += protectReserved(chars[k], chars, at: k) }
                i = end; continue
            }
            if c == "<", let end = Self.tagEnd(chars, at: i) {
                for k in i..<end { out += protectReserved(chars[k], chars, at: k) }
                i = end; continue
            }
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if let marker = Self.escapeMarkers[next] {
                    out.unicodeScalars.append(marker); i += 2; continue
                }
                if next.isASCII && next.isPunctuation || next.isASCII && next.isSymbol {
                    out.append(c); out.append(next); i += 2; continue
                }
            }
            if c == "$", let (end, token) = Self.inlineMath(chars, at: i) {
                tokenSourceRanges[tokens.count] = i..<end
                out += Self.placeholder(tokens.count); tokens.append(token); i = end; continue
            }
            if c == "!" || c == "[", let (end, token) = Self.wikiLink(chars, at: i) {
                tokenSourceRanges[tokens.count] = i..<end
                out += Self.placeholder(tokens.count); tokens.append(token); i = end; continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Whether the text from `start` is a footnote label and its closing `]`. SPEC §3.2: one or
    /// more letters, digits, `-` or `_`.
    static func isFootnoteLabel(_ chars: [Character], from start: Int) -> Bool {
        var j = start
        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" { j += 1 }
        return j > start && j < chars.count && chars[j] == "]"
    }

    /// The character itself, or a literal token for it: for characters in the reserved range,
    /// and for a `^` that cmark-gfm must not see (`isHiddenCaret`). Applied everywhere,
    /// including code spans and tags, because a literal token restores to the same character in
    /// every context.
    private mutating func protectReserved(_ c: Character, _ chars: [Character], at i: Int) -> String {
        guard c.unicodeScalars.contains(where: Self.isReserved) || Self.isHiddenCaret(chars, at: i) else { return String(c) }
        return literal(String(c))
    }

    /// The placeholder for a literal token. The same text always gets the same placeholder, so
    /// that, for example, a reference label and its definition still match (`[^a.b]` and
    /// `[^a.b]: url`, where both `^` are hidden).
    private mutating func literal(_ text: String) -> String {
        if let index = literalIndex[text] { return Self.placeholder(index) }
        tokens.append(.literal(text))
        literalIndex[text] = tokens.count - 1
        return Self.placeholder(tokens.count - 1)
    }
    private var literalIndex: [String: Int] = [:]

    /// A `^` that is hidden from cmark-gfm as a literal token. This works around three cmark
    /// behaviours that lose or misread text, none of which are GFM:
    /// - With footnotes on, a `[^` that can't be a footnote loses text. In `[^[x]]y` everything
    ///   after `[^[` is dropped; in `[^a\nb]` the label is.
    /// - swift-cmark (Apple's fork) parses `^[text](attributes)` as an inline attribute span.
    /// - `^[][x]` loses text.
    ///
    /// A `^` is hidden when `[` follows it, or when `[` precedes it and no footnote label
    /// follows. Neither is meaningful GFM or Atlas syntax, so hiding the `^` changes nothing else.
    static func isHiddenCaret(_ chars: [Character], at i: Int) -> Bool {
        guard chars[i] == "^" else { return false }
        if i + 1 < chars.count, chars[i + 1] == "[" { return true }
        return i > 0 && chars[i - 1] == "[" && !isFootnoteLabel(chars, from: i + 1)
    }

    /// The end of a code span starting at `i`: a matching run of exactly as many backticks, on
    /// the same line. Nil when there is none, and the run is literal.
    ///
    /// Only same-line spans are skipped. A code span can't cross a block boundary, and the
    /// preprocessor can't see blocks: following a span onto the next line could swallow a list
    /// item or quote that cmark starts there, leaving its wiki links unprotected. A multi-line
    /// span is still parsed as code, because placeholders contain no backticks, and any token
    /// inside it is restored as raw text.
    static func codeSpanEnd(_ chars: [Character], at i: Int) -> Int? {
        var n = 0
        while i + n < chars.count, chars[i + n] == "`" { n += 1 }
        var j = i + n
        while j < chars.count {
            let c = chars[j]
            if c.isNewline { return nil }
            if c == "`" {
                var m = 0
                while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                if m == n { return j + m }
                j += m; continue
            }
            j += 1
        }
        return nil
    }

    /// The end of an autolink or HTML tag starting at `i`, on the same line.
    static func tagEnd(_ chars: [Character], at i: Int) -> Int? {
        guard i + 1 < chars.count else { return nil }
        let next = chars[i + 1]
        guard next.isLetter || next == "/" || next == "!" || next == "?" else { return nil }
        var j = i + 1
        while j < chars.count {
            let c = chars[j]
            if c == ">" { return j + 1 }
            if c == "<" || c.isNewline { return nil }
            j += 1
        }
        return nil
    }

    /// §4.8 inline math, pandoc's rule, on one line. `$$x$$` is inline math too.
    static func inlineMath(_ chars: [Character], at i: Int) -> (Int, Token)? {
        let double = i + 1 < chars.count && chars[i + 1] == "$"
        let delim = double ? 2 : 1
        let start = i + delim
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }

        var j = start + 1
        while j < chars.count, !chars[j].isNewline {
            if chars[j] == "$" {
                if double {
                    if j + 1 < chars.count, chars[j + 1] == "$" {
                        let value = String(chars[start..<j])
                        return (j + 2, .inlineMath(value, raw: String(chars[i..<(j + 2)])))
                    }
                } else if !chars[j - 1].isWhitespace, chars[j - 1] != "\\",
                          !(j + 1 < chars.count && chars[j + 1].isASCII && chars[j + 1].isNumber) {
                    let value = String(chars[start..<j])
                    return (j + 1, .inlineMath(value, raw: String(chars[i..<(j + 1)])))
                }
            }
            j += 1
        }
        return nil
    }

    /// §4.2 / §4.3: `[[…]]` or `![[…]]` on one line, with raw content.
    static func wikiLink(_ chars: [Character], at i: Int) -> (Int, Token)? {
        let isEmbed = chars[i] == "!"
        let open = isEmbed ? i + 1 : i
        guard open + 1 < chars.count, chars[open] == "[", chars[open + 1] == "[" else { return nil }

        var j = open + 2
        while j + 1 < chars.count {
            let c = chars[j]
            if c.isNewline || c == "[" { return nil }
            if c == "]" {
                guard chars[j + 1] == "]" else { return nil }
                let inner = String(chars[(open + 2)..<j])
                guard let ref = parseWikiLink(inner) else { return nil }
                let raw = String(chars[i..<(j + 2)])
                return (j + 2, isEmbed ? .embed(ref, raw: raw) : .wikiLink(ref, raw: raw))
            }
            j += 1
        }
        return nil
    }

    /// Splits wiki-link content into target, heading or block reference, and alias.
    static func parseWikiLink(_ inner: String) -> WikiLinkReference? {
        func trim(_ s: Substring) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }

        // `\|` is the alias separator exactly like `|`.
        var left = Substring(inner), alias: String? = nil
        if let bar = inner.firstIndex(of: "|") {
            var end = bar
            if end > inner.startIndex, inner[inner.index(before: end)] == "\\" { end = inner.index(before: end) }
            left = inner[..<end]
            let a = trim(inner[inner.index(after: bar)...])
            alias = a.isEmpty ? nil : a
        }

        var ref = WikiLinkReference(target: "", alias: alias)
        if let hash = left.firstIndex(of: "#") {
            ref.target = trim(left[..<hash])
            let rest = left[left.index(after: hash)...]
            if rest.hasPrefix("^") {
                let id = trim(rest.dropFirst())
                guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                ref.blockId = id
            } else {
                let heading = trim(rest)
                guard !heading.isEmpty, !heading.contains("^") else { return nil }
                ref.heading = heading
            }
        } else {
            ref.target = trim(left)
        }
        if ref.target.contains("^") { return nil }
        if ref.target.isEmpty && ref.heading == nil && ref.blockId == nil { return nil }
        return ref
    }
}

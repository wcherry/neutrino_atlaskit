import AtlasCore
import Foundation

/// One change to a page's text, in UTF-16 offsets as TextKit counts them.
public struct TextEdit: Equatable, Sendable {
    /// The range replaced, in the text before the edit.
    public var range: Range<Int>
    public var replacement: String
    /// The selection after the edit.
    public var selection: Range<Int>

    public init(range: Range<Int>, replacement: String, selection: Range<Int>) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: replacement)
    }
}

/// The editor's Markdown commands. Each returns the edit to make, or nil when the key should
/// do what it normally does. They work on the text and the syntax map only, so both views
/// share them and they're tested without a UI.
public enum MarkdownEditing {
    /// Return: continues a list item, task or quote on the next line. On an item or quote line
    /// with nothing after its marker, removes the marker instead, which ends the list.
    public static func newline(in text: String, selection: Range<Int>, syntax: PageSyntax) -> TextEdit? {
        guard selection.isEmpty, !isInVerbatimBlock(selection.lowerBound, syntax) else { return nil }
        let ns = text as NSString
        let cursor = selection.lowerBound
        let line = lineContent(ns, at: cursor)
        let content = ns.substring(with: line)
        guard let prefix = LinePrefix(content), cursor >= line.location + prefix.length else { return nil }

        if prefix.length == content.utf16.count || content.dropFirst(prefix.text.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
            // An empty item or quote line: drop its marker (and one level of quote).
            let kept = prefix.withoutLastLevel
            let r = line.location..<(line.location + line.length)
            return TextEdit(range: r, replacement: kept, selection: (r.lowerBound + kept.utf16.count)..<(r.lowerBound + kept.utf16.count))
        }
        let insert = "\n" + prefix.continuation
        let at = cursor + insert.utf16.count
        // Trailing spaces before the cursor go: they'd become a hard break or stray whitespace.
        var start = cursor
        while start > line.location + prefix.length, ns.character(at: start - 1) == 0x20 { start -= 1 }
        return TextEdit(range: start..<cursor, replacement: insert, selection: (at - (cursor - start))..<(at - (cursor - start)))
    }

    /// Tab: indents the selected list items one level, under the item before them. Nil when
    /// any selected line isn't a list item, so Tab types a tab there.
    public static func indent(in text: String, selection: Range<Int>, syntax: PageSyntax) -> TextEdit? {
        guard !isInVerbatimBlock(selection.lowerBound, syntax) else { return nil }
        let ns = text as NSString
        let lines = selectedLines(ns, selection)
        guard let first = lines.first, lines.allSatisfy({ ListLine(ns.substring(with: $0)) != nil }) else { return nil }
        let item = ListLine(ns.substring(with: first))!
        // One level is the content offset of the sibling above (2 for `- `, 3 for `1. `).
        var unit = item.markerWidth
        if let sibling = previousListLine(ns, before: first.location, where: { $0.indent == item.indent }) {
            unit = sibling.markerWidth
        }
        return reindent(ns, lines, selection) { _ in unit }
    }

    /// Shift-Tab: outdents the selected list items to their parent's level.
    public static func outdent(in text: String, selection: Range<Int>, syntax: PageSyntax) -> TextEdit? {
        guard !isInVerbatimBlock(selection.lowerBound, syntax) else { return nil }
        let ns = text as NSString
        let lines = selectedLines(ns, selection)
        guard lines.allSatisfy({ ListLine(ns.substring(with: $0)) != nil }) else { return nil }
        guard lines.contains(where: { ListLine(ns.substring(with: $0))!.indent > 0 }) else { return nil }
        return reindent(ns, lines, selection) { line in
            let item = ListLine(ns.substring(with: line))!
            guard item.indent > 0 else { return 0 }
            let parent = previousListLine(ns, before: line.location, where: { $0.indent < item.indent })
            return -(item.indent - (parent?.indent ?? 0))
        }
    }

    /// Ticks or unticks the task whose checkbox is at `offset`, or, with `onLine`, the task on
    /// the line containing `offset`. It changes the one character between the brackets (SPEC §8.2).
    public static func toggleTask(at offset: Int, onLine: Bool = false, in text: String, syntax: PageSyntax) -> TextEdit? {
        let ns = text as NSString
        let range: Range<Int>
        if onLine {
            let line = lineContent(ns, at: min(offset, ns.length))
            range = line.location..<(line.location + line.length)
        } else {
            range = offset..<offset
        }
        for block in syntax.blocks where block.range.lowerBound <= range.upperBound && range.lowerBound <= block.range.upperBound {
            for span in block.spans {
                guard case .syntax(.taskMarker(let checked)) = span.kind else { continue }
                let hit = onLine ? range.contains(span.range.lowerBound) : span.range.contains(offset)
                guard hit, span.range.count == 3 else { continue }
                let box = (span.range.lowerBound + 1)..<(span.range.lowerBound + 2)
                return TextEdit(range: box, replacement: checked ? " " : "x", selection: box.upperBound..<box.upperBound)
            }
        }
        return nil
    }

    /// Bold, italic, code and the like: wraps the selection in `marker`, or unwraps it when it
    /// already is. With nothing selected, inserts the pair with the cursor between.
    public static func toggleWrap(_ marker: String, in text: String, selection: Range<Int>) -> TextEdit {
        let ns = text as NSString
        let m = marker.utf16.count
        let s = selection.lowerBound, e = selection.upperBound
        func has(_ at: Int) -> Bool { at >= 0 && at + m <= ns.length && ns.substring(with: NSRange(location: at, length: m)) == marker }

        if has(s - m), has(e) {
            // Markers just outside the selection.
            let inner = ns.substring(with: NSRange(location: s, length: e - s))
            return TextEdit(range: (s - m)..<(e + m), replacement: inner, selection: (s - m)..<(e - m))
        }
        if e - s >= 2 * m, has(s), has(e - m) {
            // Markers at the ends of the selection.
            let inner = ns.substring(with: NSRange(location: s + m, length: e - s - 2 * m))
            return TextEdit(range: s..<e, replacement: inner, selection: s..<(s + inner.utf16.count))
        }
        let inner = ns.substring(with: NSRange(location: s, length: e - s))
        return TextEdit(range: s..<e, replacement: marker + inner + marker, selection: (s + m)..<(e + m))
    }

    // MARK: Lines

    /// In code, math and frontmatter, Return and Tab are just characters.
    static func isInVerbatimBlock(_ offset: Int, _ syntax: PageSyntax) -> Bool {
        for block in syntax.blocks where block.range.lowerBound <= offset && offset <= block.range.upperBound {
            for span in block.spans where span.range.lowerBound < offset && offset <= span.range.upperBound {
                switch span.kind {
                case .codeBlock, .mathBlock, .frontmatter: return true
                default: continue
                }
            }
        }
        return false
    }

    /// The line around `offset`, without its line ending.
    static func lineContent(_ ns: NSString, at offset: Int) -> NSRange {
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func selectedLines(_ ns: NSString, _ selection: Range<Int>) -> [NSRange] {
        var lines: [NSRange] = []
        var at = selection.lowerBound
        repeat {
            let line = lineContent(ns, at: at)
            lines.append(line)
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
            if end <= at || end >= ns.length { break }
            at = end
        } while at < selection.upperBound
        return lines
    }

    static func previousListLine(_ ns: NSString, before location: Int, where match: (ListLine) -> Bool) -> ListLine? {
        var at = location
        while at > 0 {
            let line = lineContent(ns, at: at - 1)
            let content = ns.substring(with: line)
            if content.allSatisfy({ $0 == " " || $0 == "\t" }) { return nil }
            if let item = ListLine(content), match(item) { return item }
            at = line.location
        }
        return nil
    }

    /// Changes each line's indentation by `delta(line)` spaces, keeping the selection on the same text.
    static func reindent(_ ns: NSString, _ lines: [NSRange], _ selection: Range<Int>, _ delta: (NSRange) -> Int) -> TextEdit? {
        let start = lines.first!.location, end = lines.last!.location + lines.last!.length
        var out = "", shiftStart = 0, shiftEnd = 0, changed = false
        for (k, line) in lines.enumerated() {
            if k > 0 {
                let gap = NSRange(location: lines[k - 1].location + lines[k - 1].length, length: line.location - lines[k - 1].location - lines[k - 1].length)
                out += ns.substring(with: gap)
            }
            let content = ns.substring(with: line)
            let d = delta(line)
            var text = content
            if d > 0 {
                text = String(repeating: " ", count: d) + content
            } else if d < 0 {
                text = String(content.dropFirst(min(-d, content.prefix(while: { $0 == " " }).count)))
            }
            let change = text.utf16.count - content.utf16.count
            if change != 0 { changed = true }
            if line.location <= selection.lowerBound { shiftStart += change }
            shiftEnd += change
            out += text
        }
        guard changed else { return nil }
        let newStart = max(start, selection.lowerBound + shiftStart)
        return TextEdit(range: start..<end, replacement: out, selection: newStart..<max(newStart, selection.upperBound + shiftEnd))
    }
}

/// A list item line: indentation, marker, spaces, an optional checkbox.
struct ListLine {
    var indent: Int
    /// Marker plus the spaces after it: the content offset relative to the indentation.
    var markerWidth: Int

    init?(_ line: String) {
        let chars = Array(line)
        var k = 0
        while k < chars.count, chars[k] == " " { k += 1 }
        indent = k
        let m = k
        if k < chars.count, "-*+".contains(chars[k]) {
            k += 1
        } else {
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
            guard k > m, k - m <= 9, k < chars.count, chars[k] == "." || chars[k] == ")" else { return nil }
            k += 1
        }
        guard k == chars.count || chars[k] == " " || chars[k] == "\t" else { return nil }
        var spaces = 0
        while k + spaces < chars.count, chars[k + spaces] == " " { spaces += 1 }
        markerWidth = (k - m) + max(1, min(spaces, 4))
    }
}

/// The container markers that start a line: quotes, then at most one list item and its checkbox.
struct LinePrefix {
    /// The prefix as written.
    var text: String
    var length: Int { text.utf16.count }
    /// What the next line should start with.
    var continuation: String
    /// The prefix without its innermost level: the list marker, or else the last `>`.
    var withoutLastLevel: String

    init?(_ line: String) {
        let pattern = #"^([ \t]*(?:>[ \t]?)*)([ \t]*)(?:([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let ns = line as NSString
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let quotes = group(1) ?? "", indent = group(2) ?? ""
        let hasQuote = quotes.contains(">")
        text = ns.substring(with: m.range)

        if let marker = group(3) {
            var next = marker
            if let number = group(4).flatMap({ Int($0) }), let delimiter = group(5) { next = "\(number + 1)\(delimiter)" }
            let spaces = group(6) ?? " "
            continuation = quotes + indent + next + spaces + (group(7) != nil ? "[ ] " : "")
            withoutLastLevel = quotes + (indent.isEmpty ? "" : indent)
        } else if hasQuote {
            continuation = quotes.hasSuffix(" ") || quotes.hasSuffix("\t") ? quotes : quotes + " "
            var q = quotes
            while let last = q.last, last == " " || last == "\t" { q.removeLast() }
            if q.last == ">" { q.removeLast() }
            while let last = q.last, last == " " || last == "\t" { q.removeLast() }
            withoutLastLevel = q.isEmpty ? "" : q + " "
            text = quotes
        } else {
            return nil
        }
    }
}

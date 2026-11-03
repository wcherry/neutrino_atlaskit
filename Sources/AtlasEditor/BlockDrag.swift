import AtlasCore
import Foundation

extension MarkdownEditing {
    /// The blocks a drag handle moves (roadmap Phase 1, "move blocks with a drag handle"), in
    /// order, as UTF-16 ranges from the start of a block's first line to the end of its last:
    /// each top-level block (a paragraph, heading, quote, callout, table, code or math block), and
    /// each top-level item of a list, with its nested items. Not the frontmatter, which stays first.
    public static func dragBlocks(in text: String, syntax: PageSyntax) -> [Range<Int>] {
        let page = PageLines(text)
        var out: [Range<Int>] = []
        for block in syntax.blocks {
            if case .yaml = block.node { continue }
            if case .footnoteDefinition = block.node { continue }
            let first = page.index(at: block.range.lowerBound), last = page.index(at: max(block.range.lowerBound, block.range.upperBound - 1))
            guard case .list = block.node else {
                out.append(page.start(of: first)..<page.end(of: last))
                continue
            }
            // A list: each item at the list's own indent starts a block.
            let indent = PageLines.indent(page[first])
            var start = first
            for line in (first + 1)...max(first + 1, last + 1) where line <= last {
                let text = page[line]
                if ListLine(text) != nil, PageLines.indent(text) <= indent {
                    out.append(page.start(of: start)..<page.end(of: trimmed(start..<line, page)))
                    start = line
                }
            }
            out.append(page.start(of: start)..<page.end(of: last))
        }
        return out
    }

    /// The lines from `range`'s start up to its end, without trailing blank lines.
    private static func trimmed(_ range: Range<Int>, _ page: PageLines) -> Int {
        var end = range.upperBound - 1
        while end > range.lowerBound, PageLines.isBlank(page[end]) { end -= 1 }
        return end
    }

    /// Moves the drag block `block` (from `dragBlocks`) to just before the block starting at
    /// `target`, or to the end of the page when `target` is nil. Blank lines follow it so that
    /// nothing runs together: a paragraph keeps a blank line on each side, list items moved among
    /// list items keep none. The cursor goes to the start of the block where it lands.
    public static func moveBlock(_ block: Range<Int>, before target: Int?, in text: String) -> TextEdit? {
        var lines = text.components(separatedBy: "\n")
        let page = PageLines(text)
        let a = page.index(at: block.lowerBound), b = page.index(at: max(block.lowerBound, block.upperBound - 1))
        let t = target.map { page.index(at: $0) } ?? lines.count
        guard t < a || t > b + 1 else { return nil }  // onto itself, or where it already is
        if let target, target != page.start(of: t) { return nil }

        let moving = Array(lines[a...b])
        let isItem = ListLine(moving[0]) != nil
        func blank(_ i: Int) -> Bool { i < 0 || i >= lines.count || PageLines.isBlank(lines[i]) }
        func item(_ i: Int) -> Bool { i >= 0 && i < lines.count && ListLine(lines[i]) != nil }

        // Take it out, with one blank line that separated it, so none doubles up.
        var removeFrom = a, removeTo = b
        // When it stood apart, blank lines on both sides: the one after it (or, last on the page,
        // the one before). Never one that would join the lines on either side, such as the list
        // item before it and a paragraph after.
        if blank(a - 1), b + 1 < lines.count, blank(b + 1) {
            removeTo = b + 1
        } else if a > 0, blank(a - 1), b + 1 >= lines.count {
            removeFrom = a - 1
        }
        lines.removeSubrange(removeFrom...removeTo)
        var at = t > removeTo ? t - (removeTo - removeFrom + 1) : t
        // To the end: before the blank lines the page ends with (its final newline).
        var trailing: [String] = []
        if target == nil {
            while let last = lines.last, PageLines.isBlank(last), lines.count > 1 { trailing.insert(lines.removeLast(), at: 0) }
            at = lines.count
        }

        // Put it in, with the blank lines it needs on each side.
        let before = at > 0 && !blank(at - 1) && !(isItem && item(at - 1))
        let after = at < lines.count && !blank(at) && !(isItem && item(at))
        var inserted = moving
        if after { inserted.append("") }
        if before { inserted.insert("", at: 0) }
        lines.insert(contentsOf: inserted, at: at)
        lines += trailing

        let result = lines.joined(separator: "\n")
        let landed = at + (before ? 1 : 0)
        let cursor = lines[..<landed].reduce(0) { $0 + $1.utf16.count + 1 }
        return TextEdit.between(text, result, selection: cursor..<cursor)
    }
}

extension TextEdit {
    /// The edit that turns `old` into `new`, covering only what differs between them, so the view
    /// keeps its place.
    static func between(_ old: String, _ new: String, selection: Range<Int>) -> TextEdit? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Not inside a surrogate pair.
        func splits(_ u: [UInt16], _ i: Int) -> Bool { i > 0 && i < u.count && UTF16.isTrailSurrogate(u[i]) }
        while splits(a, prefix) || splits(b, prefix) { prefix -= 1 }
        while suffix > 0, splits(a, a.count - suffix) || splits(b, b.count - suffix) { suffix -= 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return TextEdit(range: prefix..<(a.count - suffix), replacement: replacement, selection: selection)
    }
}

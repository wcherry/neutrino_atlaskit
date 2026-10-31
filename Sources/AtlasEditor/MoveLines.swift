import AtlasCore
import Foundation

public enum MoveDirection: Sendable {
    case up, down
}

extension MarkdownEditing {
    /// ⌥⌘↑ and ⌥⌘↓ (roadmap Phase 1, "move blocks with … keyboard"): swaps the selected lines with
    /// the block above or below them. The lines moved, and the lines they move past, grow to whole
    /// blocks so nothing is split: a list item takes its nested items with it and passes a sibling
    /// with all of its own, and code and math blocks move and are passed whole. Indentation is
    /// kept; Tab and Shift-Tab change it. Nil at the top or bottom of the page, and next to the
    /// frontmatter, which stays first.
    public static func moveLines(_ direction: MoveDirection, in text: String, selection: Range<Int>, syntax: PageSyntax) -> TextEdit? {
        let page = Lines(text)
        let last = selection.isEmpty ? selection.lowerBound : max(selection.lowerBound, selection.upperBound - 1)
        var verbatim: [ClosedRange<Int>] = []
        var frontmatter: ClosedRange<Int>?
        for block in syntax.blocks {
            for span in block.spans {
                let lines = page.index(at: span.range.lowerBound)...page.index(at: max(span.range.lowerBound, span.range.upperBound - 1))
                switch span.kind {
                case .codeBlock, .mathBlock: verbatim.append(lines)
                case .frontmatter: frontmatter = lines; verbatim.append(lines)
                default: continue
                }
            }
        }
        /// `lines` grown to cover every code, math or frontmatter block it touches.
        func whole(_ lines: ClosedRange<Int>) -> ClosedRange<Int> {
            var r = lines
            while let b = verbatim.first(where: { $0.overlaps(r) && ($0.lowerBound < r.lowerBound || $0.upperBound > r.upperBound) }) {
                r = min(r.lowerBound, b.lowerBound)...max(r.upperBound, b.upperBound)
            }
            return r
        }
        func intersectsFrontmatter(_ r: ClosedRange<Int>) -> Bool { frontmatter.map { $0.overlaps(r) } ?? false }
        /// `lines` with the nested lines after them, when they start with a list item: the
        /// non-blank lines indented further than the least-indented line moved.
        func withChildren(_ lines: ClosedRange<Int>) -> ClosedRange<Int> {
            guard ListLine(page[lines.lowerBound]) != nil else { return lines }
            let indent = lines.map { page[$0] }.filter { !Lines.isBlank($0) }.map(Lines.indent).min() ?? 0
            var end = lines.upperBound
            while end + 1 < page.count, !Lines.isBlank(page[end + 1]), Lines.indent(page[end + 1]) > indent { end += 1 }
            return whole(lines.lowerBound...end)
        }

        let moved = withChildren(whole(page.index(at: selection.lowerBound)...page.index(at: last)))
        guard !intersectsFrontmatter(moved) else { return nil }

        let passed: ClosedRange<Int>
        switch direction {
        case .up:
            guard moved.lowerBound > 0 else { return nil }
            var start = moved.lowerBound - 1
            // Moving a list item past the nested lines of the sibling above passes the sibling too.
            if ListLine(page[moved.lowerBound]) != nil {
                let indent = Lines.indent(page[moved.lowerBound])
                while start > 0, !Lines.isBlank(page[start]), Lines.indent(page[start]) > indent,
                      !Lines.isBlank(page[start - 1]) { start -= 1 }
            }
            passed = whole(start...(moved.lowerBound - 1))
        case .down:
            guard moved.upperBound + 1 < page.count else { return nil }
            passed = withChildren(whole((moved.upperBound + 1)...(moved.upperBound + 1)))
        }
        guard !intersectsFrontmatter(passed) else { return nil }

        let movedText = page.text(of: moved), passedText = page.text(of: passed)
        let top = min(moved.lowerBound, passed.lowerBound), bottom = max(moved.upperBound, passed.upperBound)
        let range = page.start(of: top)..<page.end(of: bottom)
        let shift = (passedText.utf16.count + 1) * (direction == .up ? -1 : 1)
        let replacement = direction == .up ? movedText + "\n" + passedText : passedText + "\n" + movedText
        return TextEdit(range: range, replacement: replacement, selection: (selection.lowerBound + shift)..<(selection.upperBound + shift))
    }
}

/// A page's lines, split at `\n`, with their UTF-16 offsets.
private struct Lines {
    private let ns: NSString
    /// Where each line starts.
    private var starts: [Int] = [0]

    init(_ text: String) {
        ns = text as NSString
        for k in 0..<ns.length where ns.character(at: k) == 0x0A { starts.append(k + 1) }
    }

    var count: Int { starts.count }

    subscript(_ line: Int) -> String { ns.substring(with: NSRange(location: start(of: line), length: end(of: line) - start(of: line))) }

    func start(of line: Int) -> Int { starts[line] }
    /// The end of the line, before its `\n`.
    func end(of line: Int) -> Int { line + 1 < starts.count ? starts[line + 1] - 1 : ns.length }

    /// The line holding `offset`; a `\n` belongs to the line it ends.
    func index(at offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func text(of lines: ClosedRange<Int>) -> String {
        ns.substring(with: NSRange(location: start(of: lines.lowerBound), length: end(of: lines.upperBound) - start(of: lines.lowerBound)))
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    static func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }
}

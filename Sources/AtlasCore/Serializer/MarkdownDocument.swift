import Foundation

/// A page as an editor holds it: its tree, plus the exact bytes it was parsed from, split into
/// top-level blocks and the gaps between them (SPEC §8.1).
///
/// Saving writes every unchanged block and every gap back byte for byte, so a page saved
/// without edits is identical to the file it came from. A replaced or inserted block is
/// written in canonical form (§8.3) using the file's own line endings. Everything else,
/// including Obsidian-style tab indentation, reference definitions and unused footnotes in the
/// gaps, stays exactly as it was.
public struct MarkdownDocument: Equatable, Sendable {
    /// The top-level blocks, frontmatter first when present.
    public internal(set) var blocks: [MarkdownNode]
    /// `gaps[i]` comes before `blocks[i]`; the last gap follows the last block. A page with no
    /// blocks is all one gap.
    var gaps: [String]
    var blockText: [String]
    /// The line ending new text uses: the file's first one, or `\n`.
    public let lineEnding: String

    public var tree: MarkdownNode { .root(children: blocks) }

    public init(source: String) {
        let layout = AtlasMarkdown.parseLayout(source)
        let lines = SourcePreprocessor.splitLines(source)
        lineEnding = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"

        var gaps: [String] = [], texts: [String] = []
        var line = 1, gap = ""
        func take(_ i: Int) -> SourcePreprocessor.Line { lines[i - 1] }
        // Ranges in order, never overlapping, and inside the file, whatever the parser reported,
        // so every line is written exactly once.
        var floor = 1
        let ranges = layout.map { block -> ClosedRange<Int> in
            let lower = min(max(block.lines.lowerBound, floor), max(lines.count, 1))
            let upper = min(max(block.lines.upperBound, lower), max(lines.count, 1))
            floor = upper + 1
            return lower...upper
        }
        for range in ranges {
            // Lines already used (the file has fewer lines than the parser claimed): an empty block.
            if range.lowerBound < line || range.lowerBound > lines.count {
                gaps.append(gap); gap = ""; texts.append(""); continue
            }
            while line < range.lowerBound { gap += take(line).content + take(line).ending; line += 1 }
            gaps.append(gap)
            var text = ""
            for l in range {
                text += take(l).content
                if l < range.upperBound { text += take(l).ending } else { gap = take(l).ending }
            }
            texts.append(text)
            line = range.upperBound + 1
        }
        if layout.isEmpty { gap = "" }
        while line <= lines.count { gap += take(line).content + take(line).ending; line += 1 }
        gaps.append(gap)

        // A BOM belongs to the gap before the first block, so replacing that block keeps it.
        if let first = texts.first, first.unicodeScalars.first == "\u{FEFF}", gaps[0].isEmpty {
            texts[0] = String(first.unicodeScalars.dropFirst())
            gaps[0] = "\u{FEFF}"
        }

        self.blocks = layout.map(\.node)
        self.gaps = gaps
        self.blockText = texts
    }

    /// The page's bytes: unchanged blocks and gaps as they were, edits in canonical form.
    public func serialized() -> String {
        var out = gaps[0]
        for i in blocks.indices { out += blockText[i] + gaps[i + 1] }
        return out
    }

    /// Replaces a top-level block. Only that block's bytes change, plus a blank line on either
    /// side if there wasn't one.
    ///
    /// Returns whether the whole page now parses back to `tree`, so the result is never
    /// wrong about the page. It is false for trees no canonical text can express (SPEC §8.4),
    /// and when the change alters how a neighbour reads (cmark-gfm leaves `[r]: x` as text
    /// right before a table, and a new blank line makes it a definition). The editor should tell
    /// the user rather than save silently.
    @discardableResult
    public mutating func replaceBlock(at index: Int, with node: MarkdownNode) -> Bool {
        blocks[index] = node
        blockText[index] = canonicalText(at: index).0
        ensureBlankLines(around: index)
        return isExact
    }

    /// Whether the page's bytes parse to its tree.
    public var isExact: Bool { AtlasMarkdown.parse(serialized()) == tree }

    /// Inserts a top-level block, separated from its neighbours by one blank line. Returns
    /// whether the page parses back to `tree` (see `replaceBlock`).
    @discardableResult
    public mutating func insertBlock(_ node: MarkdownNode, at index: Int) -> Bool {
        let blank = lineEnding + lineEnding
        blocks.insert(node, at: index)
        blockText.insert("", at: index)
        if blocks.count == 1 {
            // An empty page: the block, then one line ending.
            gaps = [gaps[0], lineEnding]
        } else if index == blocks.count - 1 {
            // After the last block: it takes over the old trailing gap, and gets a blank line before it.
            gaps.insert(blank, at: index)
        } else {
            gaps.insert(blank, at: index + 1)
        }
        blockText[index] = canonicalText(at: index).0
        if !isExact, index + 1 < blocks.count {
            // The new block can change how the next one reads (a list after a list merges with
            // it): rewrite that one canonically too, which alternates the marker.
            blockText[index + 1] = canonicalText(at: index + 1).0
        }
        return isExact
    }

    /// Removes a top-level block, with the gap that followed it (or preceded it, at the end).
    /// Returns whether the page parses back to `tree` (see `replaceBlock`).
    @discardableResult
    public mutating func removeBlock(at index: Int) -> Bool {
        blocks.remove(at: index)
        blockText.remove(at: index)
        if index < blocks.count || index == 0 { gaps.remove(at: index + 1) } else { gaps.remove(at: index) }
        if !isExact, index < blocks.count, index > 0 {
            // Its neighbours now meet, and can read as one (two `-` lists merge): rewrite the
            // one after canonically, which alternates the marker.
            blockText[index] = canonicalText(at: index).0
            ensureBlankLines(around: index)
        }
        return isExact
    }

    private func canonicalText(at index: Int) -> (String, Bool) {
        let previous = index > 0 ? blocks[index - 1] : nil
        let previousText = index > 0 ? blockText[index - 1].replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : nil
        // At the file's start when nothing but a BOM comes before it.
        let atFileStart = index == 0 && gaps[0].unicodeScalars.allSatisfy { $0 == "\u{FEFF}" }
        let (text, exact) = AtlasMarkdown.serializeBlock(blocks[index], after: previous, previousText: previousText, atFileStart: atFileStart)
        return (lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding), exact)
    }

    /// A changed block needs a blank line on each side; a gap without one gets one.
    private mutating func ensureBlankLines(around index: Int) {
        let blank = lineEnding + lineEnding
        if index > 0, !containsBlankLine(gaps[index]) { gaps[index] = blank }
        if index < blocks.count - 1, !containsBlankLine(gaps[index + 1]) { gaps[index + 1] = blank }
    }

    private func containsBlankLine(_ gap: String) -> Bool {
        SourcePreprocessor.splitLines(gap).count >= 2
    }
}

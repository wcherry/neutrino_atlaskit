import Foundation

extension AtlasMarkdown {
    /// A heading as it's written after `#` in a wiki link: its plain text without the
    /// characters a link can't hold there (`[`, `]`, `|`, `^`; SPEC §4.2), runs of whitespace
    /// as one space. Obsidian writes heading links the same way.
    public static func headingLinkText(_ heading: String) -> String {
        heading.filter { !"[]|^".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The key a heading link is matched by: `headingLinkText`, then `matchKey`.
    static func headingKey(_ s: String) -> String { matchKey(headingLinkText(s)) }
}

extension PageSyntax {
    /// Where a heading link or block reference (`[[Page#Heading]]`, `[[Page#^id]]`) points in
    /// `source`, the text this map was made from: the first heading whose text matches, by
    /// `headingLinkText` and case-insensitively, or the list item or line that carries `^id`.
    /// Nil when there's no such heading or block.
    public func anchor(heading: String?, blockId: String?, in source: String) -> Range<Int>? {
        if let blockId, !blockId.isEmpty { return blockAnchor(blockId, in: source as NSString) }
        guard let heading, !heading.isEmpty else { return nil }
        let key = AtlasMarkdown.headingKey(heading)
        for block in blocks {
            if block.isComplete {
                // The block's headings, in order, are its heading spans in order.
                var nodes: [MarkdownNode] = []
                func collect(_ node: MarkdownNode) {
                    if case .heading = node { nodes.append(node) }
                    node.children.forEach(collect)
                }
                collect(block.node)
                let spans = block.spans.filter { if case .heading = $0.kind { return true } else { return false } }
                guard nodes.count == spans.count else { continue }
                if let i = nodes.firstIndex(where: { AtlasMarkdown.headingKey($0.plainText) == key }) { return spans[i].range }
            } else if case .heading = block.node, AtlasMarkdown.headingKey(block.node.plainText) == key {
                return block.range
            }
        }
        return nil
    }

    private func blockAnchor(_ id: String, in ns: NSString) -> Range<Int>? {
        let marker = "^" + id
        for block in blocks {
            for span in block.spans {
                guard case .syntax(.blockId) = span.kind, span.range.upperBound <= ns.length,
                      ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count)) == marker else { continue }
                // An id on a list item names the item (SPEC §4.6); otherwise show its line.
                let item = block.spans.last { s in
                    if case .listItem = s.kind { return s.range.lowerBound <= span.range.lowerBound && span.range.upperBound <= s.range.upperBound }
                    return false
                }
                if let item { return item.range }
                let line = ns.lineRange(for: NSRange(location: span.range.lowerBound, length: 0))
                return max(line.location, block.range.lowerBound)..<span.range.upperBound
            }
        }
        return nil
    }
}

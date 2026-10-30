import Foundation

extension AtlasMarkdown {
    /// Turns unlinked mentions of a page into wiki links ("link it", roadmap Phase 1): every
    /// place `name` appears as a phrase in `source`'s plain text becomes `[[target]]`, keeping
    /// the words as written. Returns the new text and how many mentions were linked, or nil when
    /// there was nothing to link or the result wouldn't read back as exactly those new links.
    ///
    /// Plain text only, found through the syntax map: not code, math, frontmatter or HTML, not
    /// inside a link, wiki link, image, tag or footnote reference, and never across syntax
    /// characters (`Pro**ject**`). Matching ignores case and diacritics, as search does, at word
    /// boundaries. Blocks the syntax map couldn't align completely are left alone.
    ///
    /// A mention written exactly as the target (up to case) becomes `[[Mention]]`. Otherwise it
    /// keeps its words as the alias: `[[Projects/Plan|plan]]`.
    public static func linkingMentions(of name: String, as target: String, in source: String) -> (text: String, linked: Int)? {
        let ns = source as NSString
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !target.isEmpty else { return nil }
        let syntax = syntax(of: source)

        var found: [NSRange] = []
        for block in syntax.blocks where block.isComplete && block.isProse {
            let forbidden = block.spans.filter(\.excludesMentions).map(\.range)
            var searchFrom = block.range.lowerBound
            while searchFrom < block.range.upperBound {
                let window = NSRange(location: searchFrom, length: block.range.upperBound - searchFrom)
                let r = ns.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: window)
                guard r.location != NSNotFound else { break }
                searchFrom = r.location + max(r.length, 1)
                let range = r.location..<(r.location + r.length)
                guard isWordBoundary(ns, before: r.location), isWordBoundary(ns, after: NSMaxRange(r)),
                      !forbidden.contains(where: { $0.overlaps(range) }) else { continue }
                found.append(r)
            }
        }
        guard !found.isEmpty else { return nil }

        let out = NSMutableString(string: source)
        for r in found.reversed() {
            let written = ns.substring(with: r)
            let link = matchKey(written) == matchKey(target) ? "[[\(written)]]" : "[[\(target)|\(written)]]"
            out.replaceCharacters(in: r, with: link)
        }
        let text = out as String

        // Exactly `found.count` more wiki links to the target, and the rest of the page unchanged.
        func links(_ node: MarkdownNode) -> Int {
            if case .wikiLink(let ref) = node, matchKey(ref.target) == matchKey(target) { return 1 }
            return node.children.reduce(0) { $0 + links($1) }
        }
        let before = parse(source), after = parse(text)
        guard links(after) == links(before) + found.count,
              unlinking(after, target) == unlinking(before, target) else { return nil }
        return (text, found.count)
    }

    private static func isWordBoundary(_ ns: NSString, before i: Int) -> Bool {
        guard i > 0 else { return true }
        return !isWordCharacter(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i - 1)))
    }

    private static func isWordBoundary(_ ns: NSString, after i: Int) -> Bool {
        guard i < ns.length else { return true }
        return !isWordCharacter(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i)))
    }

    private static func isWordCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }
}

private extension PageSyntax.Block {
    /// Blocks whose text can hold a mention: not code, math, frontmatter or HTML.
    var isProse: Bool {
        switch node {
        case .code, .math, .yaml, .html, .thematicBreak: return false
        default: return true
        }
    }
}

private extension SyntaxSpan {
    /// Text a mention must not touch.
    var excludesMentions: Bool {
        switch kind {
        case .inlineCode, .inlineMath, .inlineHTML, .codeBlock, .mathBlock, .frontmatter, .htmlBlock,
             .link, .image, .wikiLink, .embed, .tag, .footnoteReference, .syntax:
            return true
        default:
            return false
        }
    }
}

extension AtlasMarkdown {
    /// The tree with every wiki link to `target` turned back into the words it shows, and
    /// adjacent text merged: a change that only linked words compares equal.
    fileprivate static func unlinking(_ node: MarkdownNode, _ target: String) -> MarkdownNode {
        var kids: [MarkdownNode] = []
        for kid in node.children {
            var k = kid
            if case .wikiLink(let ref) = kid, matchKey(ref.target) == matchKey(target) {
                k = .text(value: ref.alias ?? ref.target)
            } else {
                k = unlinking(kid, target)
            }
            if case .text(let v) = k, case .text(let previous)? = kids.last {
                kids[kids.count - 1] = .text(value: previous + v)
            } else {
                kids.append(k)
            }
        }
        if case .callout(let type, let fold, let title, let id, _) = node {
            return .callout(calloutType: type, fold: fold, title: title.map { unlinking(.paragraph(blockId: nil, children: $0), target).children }, blockId: id, children: kids)
        }
        return node.children.isEmpty ? node : node.replacingChildren(kids)
    }
}

import Foundation

/// A link found in a page, as handed to `MarkdownDocument.rewriteLinks`.
public struct LinkOccurrence: Equatable, Sendable {
    public enum Kind: Sendable { case wiki, embed, markdown }
    public let kind: Kind
    /// For a markdown link: the decoded path without `.md`, with the fragment as heading or
    /// block id, as in `PageExtract` (SPEC §6).
    public let reference: WikiLinkReference
}

/// What an in-place edit did (SPEC §8.2).
public struct EditResult: Equatable, Sendable {
    /// Only the bytes of the edited construct changed. When false, the affected blocks were
    /// written canonically instead, which happens only for source no in-place edit reads back
    /// from.
    public var inPlace: Bool
    /// The page's bytes parse to its tree. Always true when `inPlace` is. When false, the
    /// canonical text couldn't express the tree either (§8.4): tell the user rather than save
    /// silently.
    public var exact: Bool

    public static let inPlaceExact = EditResult(inPlace: true, exact: true)
}

/// What `rewriteLinks` did.
public struct LinkRewriteResult: Equatable, Sendable {
    /// How many links got a new target.
    public var rewritten: Int
    /// See `EditResult.inPlace`.
    public var inPlace: Bool
    /// See `EditResult.exact`.
    public var exact: Bool = true
}

/// The two edits Atlas makes on the user's behalf, which must change only the bytes of the
/// construct they touch (SPEC §8.2): ticking a task, and rewriting links after a rename (§7).
///
/// Each edit is made on the bytes, then verified by parsing the whole page: everything must
/// read back as before, apart from the intended change. If that fails, which only odd source
/// should cause, the edit is undone and the affected block is written canonically instead,
/// and the result says so.
extension MarkdownDocument {
    // MARK: Tasks

    /// The number of task items (`- [ ]`, `- [x]`) in the page, in tree order.
    public var taskCount: Int { blocks.map { Self.taskCount(in: $0) }.reduce(0, +) }

    /// Ticks or unticks the task at `index` (tree order). Only the character between the
    /// brackets changes, unless the block has to be rewritten canonically instead.
    @discardableResult
    public mutating func setTask(at index: Int, checked: Bool) -> EditResult {
        var local = index
        for k in blocks.indices {
            let count = Self.taskCount(in: blocks[k])
            guard local < count else { local -= count; continue }
            var counter = 0
            let expected = Self.settingTask(local, checked: checked, in: blocks[k], counter: &counter)
            let anatomy = AtlasMarkdown.anatomy(of: blockText[k])
            if anatomy.tasks.count == count,
               let text = Self.togglingCheckbox(in: blockText[k], at: anatomy.tasks[local], checked: checked),
               commitIfOnlyChanged(block: k, to: expected, text: text) {
                return .inPlaceExact
            }
            return EditResult(inPlace: false, exact: replaceBlock(at: k, with: expected))
        }
        preconditionFailure("task index \(index) out of range (\(taskCount) tasks)")
    }

    // MARK: Links

    /// Rewrites link targets. `newTarget` is called for every wiki link, embed and internal
    /// markdown link (a relative `.md` path, SPEC §6), and returns the new target or nil to
    /// leave it. It must give the same answer each time it is asked about the same link.
    ///
    /// Only the target's bytes change: whitespace inside the brackets, the heading, block
    /// reference and alias, a markdown link's fragment and text, and everything else stay as
    /// they were. Reference definitions in the gaps between blocks are rewritten too.
    @discardableResult
    public mutating func rewriteLinks(_ newTarget: (LinkOccurrence) -> String?) -> LinkRewriteResult {
        var rewritten = 0
        let expected = blocks.map { Self.rewritingLinks(in: $0, newTarget) }
        for block in blocks { _ = Self.rewritingLinks(in: block) { occurrence in
            let target = newTarget(occurrence)
            if target != nil { rewritten += 1 }
            return target
        } }
        guard expected != blocks else { return LinkRewriteResult(rewritten: 0, inPlace: true, exact: true) }

        let before = AtlasMarkdown.parse(serialized()).children
        let saved = (blocks, blockText, gaps)
        var inPlace = true
        for k in blocks.indices where expected[k] != blocks[k] {
            guard let text = Self.rewritingLinkBytes(in: blockText[k], node: blocks[k], newTarget) else { inPlace = false; break }
            blockText[k] = text
            blocks[k] = expected[k]
        }
        if inPlace {
            gaps = gaps.map { Self.rewritingDefinitions(in: $0, newTarget) }
            let wanted = before.map { Self.rewritingLinks(in: $0, newTarget) }
            inPlace = AtlasMarkdown.parse(serialized()).children == wanted
        }
        if !inPlace {
            (blocks, blockText, gaps) = saved
            for k in blocks.indices where expected[k] != blocks[k] { replaceBlock(at: k, with: expected[k]) }
        }
        return LinkRewriteResult(rewritten: rewritten, inPlace: inPlace, exact: inPlace || isExact)
    }

    /// Rewrites the links in this page (`linkingPage`) that resolved to `oldPath` before a
    /// rename or move, so they point at `newPath` (SPEC §7). Each gets the shortest target that
    /// resolves to `newPath` in the vault after the change. Same-page links (`[[#Heading]]`)
    /// are never touched.
    @discardableResult
    public mutating func rewriteLinks(toRenamed oldPath: String, as newPath: String, linkingPage: String,
                                      before: LinkResolver, after: LinkResolver) -> LinkRewriteResult {
        let target = after.linkTarget(for: newPath)
        return rewriteLinks { occurrence in
            guard !occurrence.reference.target.isEmpty else { return nil }
            return before.resolve(occurrence.reference.target, from: linkingPage) == oldPath ? target : nil
        }
    }

    // MARK: - Verification

    /// Applies `text` to block `k` if the page then parses exactly as before, except that
    /// block `k` is now `expected`.
    private mutating func commitIfOnlyChanged(block k: Int, to expected: MarkdownNode, text: String) -> Bool {
        var wanted = AtlasMarkdown.parse(serialized()).children
        guard k < wanted.count else { return false }
        wanted[k] = expected
        let saved = (blocks[k], blockText[k])
        blocks[k] = expected
        blockText[k] = text
        if AtlasMarkdown.parse(serialized()).children == wanted { return true }
        (blocks[k], blockText[k]) = saved
        return false
    }

    // MARK: - Tasks: tree and bytes

    private static func taskCount(in node: MarkdownNode) -> Int {
        var n = 0
        if case .listItem(let checked, _, _) = node, checked != nil { n += 1 }
        return n + node.children.map(taskCount).reduce(0, +)
    }

    /// The node with its `index`-th task (tree order, counted by `counter`) set to `checked`.
    private static func settingTask(_ index: Int, checked: Bool, in node: MarkdownNode, counter: inout Int) -> MarkdownNode {
        var node = node
        if case .listItem(let c, let spread, let kids) = node, c != nil {
            if counter == index { node = .listItem(checked: checked, spread: spread, children: kids) }
            counter += 1
        }
        guard !node.children.isEmpty else { return node }
        var kids: [MarkdownNode] = []
        for kid in node.children { kids.append(settingTask(index, checked: checked, in: kid, counter: &counter)) }
        return node.replacingChildren(kids)
    }

    /// The text with one checkbox's character set: the item's list marker starts at `position`
    /// (1-based line and byte column); after the marker and its spaces comes `[ ]` or `[x]`.
    static func togglingCheckbox(in text: String, at position: (line: Int, column: Int), checked: Bool) -> String? {
        var lines = SourcePreprocessor.splitLines(text)
        guard position.line >= 1, position.line <= lines.count else { return nil }
        var bytes = Array(lines[position.line - 1].content.utf8)
        guard let at = CMarkConverter.checkboxOffset(in: bytes, markerColumn: position.column) else { return nil }
        guard (bytes[at] != UInt8(ascii: " ")) != checked else { return text }
        bytes[at] = checked ? UInt8(ascii: "x") : UInt8(ascii: " ")
        lines[position.line - 1].content = String(decoding: bytes, as: UTF8.self)
        return lines.map { $0.content + $0.ending }.joined()
    }

    // MARK: - Links: tree

    static func rewritingLinks(in node: MarkdownNode, _ newTarget: (LinkOccurrence) -> String?) -> MarkdownNode {
        switch node {
        case .wikiLink(var ref):
            if let t = newTarget(LinkOccurrence(kind: .wiki, reference: ref)) { ref.target = t }
            return .wikiLink(ref)
        case .embed(var ref):
            if let t = newTarget(LinkOccurrence(kind: .embed, reference: ref)) { ref.target = t }
            return .embed(ref)
        case .link(let url, let title, let kids):
            var url = url
            if let ref = PageExtract.internalPageReference(url), let t = newTarget(LinkOccurrence(kind: .markdown, reference: ref)) {
                url = rewrittenURL(url, target: t)
            }
            return .link(url: url, title: title, children: kids.map { rewritingLinks(in: $0, newTarget) })
        case .callout(let type, let fold, let title, let id, let kids):
            return .callout(calloutType: type, fold: fold, title: title.map { $0.map { rewritingLinks(in: $0, newTarget) } },
                            blockId: id, children: kids.map { rewritingLinks(in: $0, newTarget) })
        default:
            return node.children.isEmpty ? node : node.replacingChildren(node.children.map { rewritingLinks(in: $0, newTarget) })
        }
    }

    /// A markdown link url pointing at `target` instead, keeping its fragment, and percent
    /// encoding if the old path used it.
    static func rewrittenURL(_ url: String, target: String) -> String {
        let hash = url.firstIndex(of: "#")
        let path = hash.map { String(url[..<$0]) } ?? url
        let fragment = hash.map { String(url[$0...]) } ?? ""
        var newPath = target + ".md"
        if path.contains("%") { newPath = newPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newPath }
        return newPath + fragment
    }

    // MARK: - Links: bytes

    /// The block's text with only the targets of rewritten links changed, or nil if the links in
    /// the text can't be matched to the tree.
    static func rewritingLinkBytes(in text: String, node: MarkdownNode, _ newTarget: (LinkOccurrence) -> String?) -> String? {
        var edits: [(range: Range<String.Index>, replacement: String)] = []

        // Wiki links and embeds: the token ranges the parser recorded, in tree order.
        let anatomy = AtlasMarkdown.anatomy(of: text)
        var wiki: [(LinkOccurrence.Kind, WikiLinkReference)] = []
        collectWiki(node, into: &wiki)
        guard wiki.count == anatomy.links.count else { return nil }
        for ((kind, ref), offsets) in zip(wiki, anatomy.links) {
            guard let t = newTarget(LinkOccurrence(kind: kind, reference: ref)) else { continue }
            let range = text.index(text.startIndex, offsetBy: offsets.lowerBound)..<text.index(text.startIndex, offsetBy: offsets.upperBound)
            guard let raw = rewritingWikiTarget(String(text[range]), to: t) else { return nil }
            edits.append((range, raw))
        }

        // Inline markdown links: destinations found in the text, matched to the tree's links in
        // order by url. Reference-style links have no destination here; their definitions are
        // rewritten in the gaps.
        let destinations = inlineDestinations(in: text, excluding: anatomy.opaque)
        var cursor = 0
        var targets: [(url: String, isImage: Bool)] = []
        collectLinkURLs(node, into: &targets)
        for (url, isImage) in targets {
            guard let found = destinations[cursor...].firstIndex(where: { $0.url == url && $0.isImage == isImage }) else { continue }
            cursor = found + 1
            guard !isImage, let ref = PageExtract.internalPageReference(url), let t = newTarget(LinkOccurrence(kind: .markdown, reference: ref)) else { continue }
            edits.append((destinations[found].range, writtenDestination(rewrittenURL(url, target: t), angle: destinations[found].angle)))
        }

        var out = text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { out.replaceSubrange(edit.range, with: edit.replacement) }
        // cmark lifts reference definitions off the start of a paragraph but dates the paragraph
        // from the definition's line, so a definition can sit inside a block's text as well as
        // in a gap.
        return rewritingDefinitions(in: out, newTarget, leadingOnly: true)
    }

    private static func collectWiki(_ node: MarkdownNode, into out: inout [(LinkOccurrence.Kind, WikiLinkReference)]) {
        switch node {
        case .wikiLink(let r): out.append((.wiki, r))
        case .embed(let r): out.append((.embed, r))
        case .callout(_, _, let title, _, let kids): (title ?? []).forEach { collectWiki($0, into: &out) }; kids.forEach { collectWiki($0, into: &out) }
        default: node.children.forEach { collectWiki($0, into: &out) }
        }
    }

    /// Every link and image url, in tree order. Images are matched too, so that an image with
    /// the same url can't be mistaken for a link, but they are never rewritten.
    private static func collectLinkURLs(_ node: MarkdownNode, into out: inout [(url: String, isImage: Bool)]) {
        if case .link(let url, _, _) = node { out.append((url, false)) }
        if case .image(let url, _, _) = node { out.append((url, true)) }
        if case .callout(_, _, let title, _, _) = node { (title ?? []).forEach { collectLinkURLs($0, into: &out) } }
        node.children.forEach { collectLinkURLs($0, into: &out) }
    }

    /// `[[target#…|…]]` with only the target replaced: the whitespace around it, and
    /// everything after it, stay byte for byte.
    static func rewritingWikiTarget(_ raw: String, to target: String) -> String? {
        let prefix = raw.hasPrefix("![[") ? "![[" : "[["
        guard raw.hasPrefix(prefix), raw.hasSuffix("]]") else { return nil }
        let inner = raw.dropFirst(prefix.count).dropLast(2)
        var end = inner.endIndex
        if let stop = inner.firstIndex(where: { $0 == "#" || $0 == "|" }) {
            end = stop
            if inner[stop] == "|", stop > inner.startIndex, inner[inner.index(before: stop)] == "\\" { end = inner.index(before: stop) }
        }
        let segment = inner[..<end]
        let leading = segment.prefix(while: { $0 == " " || $0 == "\t" })
        let trailing = String(segment.reversed().prefix(while: { $0 == " " || $0 == "\t" }))
        return prefix + leading + target + trailing + inner[end...] + "]]"
    }

    /// Inline link destinations in `text`, in order: the range of the destination (with its
    /// angle brackets, if any), and its url as the parser reads it.
    static func inlineDestinations(in text: String, excluding opaque: [Range<Int>] = []) -> [(range: Range<String.Index>, url: String, angle: Bool, isImage: Bool)] {
        // Anchored at every `](`, so a stray `](` can't swallow the real link after it. The
        // destination must be followed by an optional title and the closing `)`.
        let pattern = #"\]\([ \t]*(<(?:[^<>\n\\]|\\.)*>|(?:[^\s()\\]|\\.|\((?:[^\s()\\]|\\.)*\))+)(?=[ \t]*\n?[ \t]*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\))?[ \t]*\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        var starts: [Int] = []
        var search = ns
        while let found = Optional((text as NSString).range(of: "](", options: [], range: search)), found.location != NSNotFound {
            starts.append(found.location)
            search = NSRange(location: found.location + 1, length: ns.length - found.location - 1)
        }
        let insideOpaque = { (start: Int) -> Bool in
            guard let index = Range(NSRange(location: start, length: 0), in: text)?.lowerBound else { return true }
            let offset = text.distance(from: text.startIndex, to: index)
            return opaque.contains { $0.contains(offset) }
        }
        return starts.compactMap { start -> (range: Range<String.Index>, url: String, angle: Bool, isImage: Bool)? in
            guard !insideOpaque(start), let opener = openingBracket(text as NSString, before: start),
                  let match = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: start, length: ns.length - start)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let isImage = opener > 0 && (text as NSString).character(at: opener - 1) == 0x21
            var raw = String(text[range])
            let angle = raw.hasPrefix("<")
            if angle { raw = String(raw.dropFirst().dropLast()) }
            return (range, unescapingBackslashes(raw), angle, isImage)
        }
    }

    /// The unescaped `[` that the `]` at `close` balances, as link text must, or nil. A `](`
    /// with nothing to close is just text.
    private static func openingBracket(_ text: NSString, before close: Int) -> Int? {
        var depth = 1
        var i = close - 1
        while i >= 0 {
            let c = text.character(at: i)
            var backslashes = 0
            while i - backslashes - 1 >= 0, text.character(at: i - backslashes - 1) == 0x5C { backslashes += 1 }
            if backslashes % 2 == 0 {
                if c == 0x5D { depth += 1 } else if c == 0x5B { depth -= 1; if depth == 0 { return i } }
            }
            i -= 1
        }
        return nil
    }

    /// A destination as written: in `<…>` if it was before, or if it now needs them.
    private static func writtenDestination(_ url: String, angle: Bool) -> String {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
        if angle || url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) {
            return "<" + escaped.replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>") + ">"
        }
        return escaped
    }

    private static func unescapingBackslashes(_ s: String) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped { if !(c.isASCII && (c.isPunctuation || c.isSymbol)) { out.append("\\") }; out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// Text with the destinations of internal reference definitions (`[label]: Page.md`)
    /// rewritten. Everything else stays as it was. A line counts only if the whole line is a
    /// definition: a label without brackets, a destination, an optional title. Inside a block
    /// (`leadingOnly`), only the lines at its start can be definitions.
    static func rewritingDefinitions(in gap: String, _ newTarget: (LinkOccurrence) -> String?, leadingOnly: Bool = false) -> String {
        let pattern = #"(?m)^((?: {0,3}>[ ]?)*[ ]{0,3})\[((?:[^\[\]\\\n]|\\.)+)\]:[ \t]*(<[^<>\n]*>|(?:[^\s()\\]|\\.|\((?:[^\s()\\]|\\.)*\))+)[ \t]*(?:(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|\((?:[^()\\\n]|\\.)*\))[ \t]*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return gap }
        var out = gap
        var matches = regex.matches(in: gap, range: NSRange(gap.startIndex..., in: gap))
        if leadingOnly {
            // Keep only an unbroken run of definition lines from the very start.
            var kept: [NSTextCheckingResult] = []
            var expected = 0
            for m in matches where m.range.location == expected {
                kept.append(m)
                expected = m.range.location + m.range.length
                let ns = gap as NSString
                while expected < ns.length, ns.character(at: expected) == 0x0D || ns.character(at: expected) == 0x0A { expected += 1 }
            }
            matches = kept
        }
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 3), in: out) else { continue }
            var raw = String(out[range])
            let angle = raw.hasPrefix("<")
            if angle { raw = String(raw.dropFirst().dropLast()) }
            let url = unescapingBackslashes(raw)
            guard let ref = PageExtract.internalPageReference(url), let t = newTarget(LinkOccurrence(kind: .markdown, reference: ref)) else { continue }
            out.replaceSubrange(range, with: writtenDestination(rewrittenURL(url, target: t), angle: angle))
        }
        return out
    }
}

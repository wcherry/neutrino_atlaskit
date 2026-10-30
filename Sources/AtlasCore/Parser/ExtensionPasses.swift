import Foundation

/// Applies the Atlas extensions (SPEC §4) to the tree cmark-gfm produced.
///
/// 1. **Inline pass**, per paragraph, heading and table cell:
///    - placeholder tokens become wiki links, embeds and inline math;
///    - `==highlights==` are paired;
///    - `#tags` are recognised;
///    - a trailing `^block-id` is lifted off each paragraph.
/// 2. **Block pass**: blockquotes that start with `[!type]` become callouts, and standalone
///    `^block-id` paragraphs attach to the block before them.
/// 3. **Restore pass**: escape markers and any tokens left in places where the syntax isn't
///    recognised (code, link text, URLs) turn back into their text, and adjacent text nodes
///    are merged.
struct ExtensionPasses {
    let tokens: [SourcePreprocessor.Token]
    /// The wiki link and embed tokens that became nodes, in tree order. Those left in code or
    /// link text don't.
    let materialized = TokenLog()

    final class TokenLog { var indices: [Int] = [] }

    func apply(_ root: MarkdownNode) -> MarkdownNode {
        restore(block(root))
    }

    /// The same passes over the top-level blocks, keeping each block's source lines. A
    /// standalone `^id` paragraph that attaches to the block before it gives that block its lines.
    func applyTopLevel(_ blocks: [(node: MarkdownNode, lines: ClosedRange<Int>)]) -> [(node: MarkdownNode, lines: ClosedRange<Int>)] {
        var out: [(node: MarkdownNode, lines: ClosedRange<Int>)] = []
        for (node, lines) in blocks {
            let converted = block(node)
            if let previous = out.last, attachStandaloneIds([previous.node, converted]).count == 1 {
                out[out.count - 1] = (attachStandaloneIds([previous.node, converted])[0], previous.lines.lowerBound...lines.upperBound)
            } else {
                out.append((converted, lines))
            }
        }
        return out.map { (restore($0.node), $0.lines) }
    }

    // MARK: - Blocks

    private func block(_ node: MarkdownNode) -> MarkdownNode {
        switch node {
        case .paragraph(_, let kids):
            return trailingBlockId(.paragraph(blockId: nil, children: inline(kids)))
        case .heading(let depth, let kids):
            return .heading(depth: depth, children: inline(kids))
        case .tableCell(let kids):
            return .tableCell(children: inline(kids))
        case .blockquote:
            return callout(node.replacingChildren(attachStandaloneIds(node.children.map(block))))
        case .root, .listItem, .footnoteDefinition, .table, .tableRow:
            let kids = node.children.map(block)
            return node.replacingChildren(node.isBlockContainer ? attachStandaloneIds(kids) : kids)
        case .list:
            return node.replacingChildren(node.children.map(block))
        default:
            return node
        }
    }

    /// §4.6, trailing form: whitespace, `^`, then an id at the very end of a paragraph.
    private func trailingBlockId(_ p: MarkdownNode) -> MarkdownNode {
        guard case .paragraph(_, var kids) = p, case .text(let value)? = kids.last, value.hasByte(UInt8(ascii: "^")),
              let match = value.range(of: #"[ \t]+\^[A-Za-z0-9-]+$"#, options: .regularExpression) else { return p }
        let id = String(value[match].drop(while: { $0 != "^" }).dropFirst())
        let rest = String(value[..<match.lowerBound]).trimmingTrailing(" \t")
        kids.removeLast()
        if !rest.isEmpty { kids.append(.text(value: rest)) }
        return .paragraph(blockId: id, children: kids)
    }

    /// §4.6, standalone form: a paragraph that is only `^id`, after a table, code, quote,
    /// callout, list or math block, names that block and leaves the tree.
    private func attachStandaloneIds(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        var out: [MarkdownNode] = []
        for kid in kids {
            if case .paragraph(nil, let inner) = kid, inner.count == 1, case .text(let v) = inner[0], v.hasPrefix("^"),
               v.range(of: #"^\^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
               let previous = out.last, previous.acceptsStandaloneBlockId {
                out[out.count - 1] = previous.settingBlockId(String(v.dropFirst()))
                continue
            }
            out.append(kid)
        }
        return out
    }

    /// §4.7: a blockquote whose first paragraph starts with `[!type]`, an optional fold, then
    /// whitespace, a line ending or nothing.
    private func callout(_ quote: MarkdownNode) -> MarkdownNode {
        guard case .blockquote(_, let kids) = quote, case .paragraph(let pid, let inline)? = kids.first,
              case .text(let first)? = inline.first, first.hasPrefix("[!"),
              let marker = first.range(of: #"^\[![A-Za-z0-9_-]+\][+-]?"#, options: .regularExpression) else { return quote }

        let markerText = first[marker]
        let type = String(markerText.dropFirst(2).prefix(while: { $0 != "]" }))
        let foldChar = markerText.last == "+" || markerText.last == "-" ? String(markerText.last!) : nil
        let rest = String(first[marker.upperBound...])
        if let c = rest.first, !c.isWhitespace { return quote }
        if rest.isEmpty && inline.count > 1 { return quote }

        // Split the paragraph at its first line ending: before it is the title, after it the body.
        var line: [MarkdownNode] = rest.isEmpty ? [] : [.text(value: rest)]
        line += inline.dropFirst()
        var title: [MarkdownNode] = [], body: [MarkdownNode] = []
        var inBody = false
        for n in line {
            if !inBody, case .text(let v) = n, let nl = v.firstIndex(of: "\n") {
                if nl > v.startIndex { title.append(.text(value: String(v[..<nl]))) }
                let after = String(v[v.index(after: nl)...])
                if !after.isEmpty { body.append(.text(value: after)) }
                inBody = true
            } else if inBody {
                body.append(n)
            } else {
                title.append(n)
            }
        }
        if case .text(let v)? = title.first {
            let trimmed = String(v.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmed.isEmpty { title.removeFirst() } else { title[0] = .text(value: trimmed) }
        }

        var children = Array(kids.dropFirst())
        var calloutId: String? = nil
        if !body.isEmpty { children.insert(.paragraph(blockId: pid, children: body), at: 0) } else { calloutId = pid }
        return .callout(calloutType: type, fold: foldChar.flatMap(CalloutFold.init(rawValue:)),
                        title: title.isEmpty ? nil : title, blockId: calloutId, children: children)
    }

    // MARK: - Inlines

    private func inline(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        var previous: Character? = nil
        return tags(highlights(mergeAllText(expandTokens(mergeAllText(kids)))), previous: &previous)
    }

    /// cmark can leave one run of text as several text nodes (it splits at `[`, `]` and `!`).
    /// Every extension below matches across those boundaries, so merge them first.
    private func mergeAllText(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        mergeText(kids.map { $0.children.isEmpty ? $0 : $0.replacingChildren(mergeAllText($0.children)) })
    }

    /// Placeholder tokens in text become wiki links, embeds and inline math. Not inside link
    /// or image text, where §4.2 says wiki links aren't recognised; those are restored as text.
    private func expandTokens(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        kids.flatMap { kid -> [MarkdownNode] in
            switch kid {
            case .text(let v): return split(v)
            case .emphasis, .strong, .delete, .highlight: return [kid.replacingChildren(expandTokens(kid.children))]
            default: return [kid]
            }
        }
    }

    private func split(_ text: String) -> [MarkdownNode] {
        guard text.unicodeScalars.contains(SourcePreprocessor.tokenStart) else { return [.text(value: text)] }
        var out: [MarkdownNode] = []
        var run = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let s = scalars.next() {
            guard s == SourcePreprocessor.tokenStart else { run.unicodeScalars.append(s); continue }
            let (index, read) = SourcePreprocessor.readToken(&scalars, count: tokens.count)
            guard let index else {
                run.unicodeScalars.append(s); run.unicodeScalars.append(contentsOf: read); continue
            }
            let node: MarkdownNode
            switch tokens[index] {
            case .wikiLink(let ref, _): node = .wikiLink(ref); materialized.indices.append(index)
            case .embed(let ref, _): node = .embed(ref); materialized.indices.append(index)
            case .inlineMath(let value, _): node = .inlineMath(value: value)
            case .literal, .reference:
                // Left as a placeholder: the restore pass turns it back into the character, once.
                run += SourcePreprocessor.placeholder(index); continue
            }
            if !run.isEmpty { out.append(.text(value: run)); run = "" }
            out.append(node)
        }
        if !run.isEmpty { out.append(.text(value: run)) }
        return out
    }

    /// §4.5: `==` pairs with the left/right-flanking rules GFM uses for `~~`.
    private func highlights(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        enum Item { case node(MarkdownNode), delim(canOpen: Bool, canClose: Bool) }

        // Recurse first, then split this level's text around `==` runs.
        let nested = kids.map { kid -> MarkdownNode in
            switch kid {
            case .emphasis, .strong, .delete: return kid.replacingChildren(highlights(kid.children))
            default: return kid
            }
        }
        var pieces: [Item] = []
        for kid in nested {
            guard case .text(let v) = kid, v.hasBytePair(UInt8(ascii: "=")) else { pieces.append(.node(kid)); continue }
            var run = ""
            var chars = Array(v)[...]
            while let c = chars.first {
                if c == "=" {
                    let n = chars.prefix(while: { $0 == "=" }).count
                    if n == 2 {
                        if !run.isEmpty { pieces.append(.node(.text(value: run))); run = "" }
                        pieces.append(.delim(canOpen: false, canClose: false))
                    } else {
                        run += String(repeating: "=", count: n)
                    }
                    chars = chars.dropFirst(n)
                } else {
                    run.append(c); chars = chars.dropFirst()
                }
            }
            if !run.isEmpty { pieces.append(.node(.text(value: run))) }
        }

        // Flanking, from the characters either side of each delimiter.
        func lastChar(_ i: Int) -> Character? {
            guard i >= 0 else { return nil }
            if case .node(let n) = pieces[i] { return n.plainTextForFlanking.last }
            return "="
        }
        func firstChar(_ i: Int) -> Character? {
            guard i < pieces.count else { return nil }
            if case .node(let n) = pieces[i] { return n.plainTextForFlanking.first }
            return "="
        }
        for i in pieces.indices {
            guard case .delim = pieces[i] else { continue }
            let before = lastChar(i - 1), after = firstChar(i + 1)
            let beforeSpace = before?.isWhitespace ?? true, afterSpace = after?.isWhitespace ?? true
            let beforePunct = before.map(\.isMarkdownPunctuation) ?? false, afterPunct = after.map(\.isMarkdownPunctuation) ?? false
            let left = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
            let right = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
            pieces[i] = .delim(canOpen: left, canClose: right)
        }

        // Pair each closer with the nearest open opener; highlights don't nest.
        var out: [MarkdownNode] = []
        var openAt: Int? = nil
        for piece in pieces {
            switch piece {
            case .node(let n):
                out.append(n)
            case .delim(let canOpen, let canClose):
                if canClose, let start = openAt, start < out.count {
                    let inner = Array(out[start...])
                    out.removeSubrange(start...)
                    out.removeLast()  // the opener's placeholder text
                    out.append(.highlight(children: inner))
                    openAt = nil
                } else {
                    out.append(.text(value: "=="))
                    if canOpen { openAt = out.count }
                }
            }
        }
        return out
    }

    /// §4.4: `#tag` where the `#` starts the block's plain text or follows whitespace.
    private func tags(_ kids: [MarkdownNode], previous: inout Character?) -> [MarkdownNode] {
        var out: [MarkdownNode] = []
        for kid in kids {
            switch kid {
            case .text(let v):
                out += tags(in: v, previous: &previous)
            case .emphasis, .strong, .delete, .highlight:
                out.append(kid.replacingChildren(tags(kid.children, previous: &previous)))
            default:
                if let last = kid.plainTextForFlanking.last { previous = last }
                out.append(kid)
            }
        }
        return out
    }

    private func tags(in text: String, previous: inout Character?) -> [MarkdownNode] {
        guard text.hasByte(UInt8(ascii: "#")) else {
            if let last = text.last { previous = last }
            return [.text(value: text)]
        }
        let chars = Array(text)
        var out: [MarkdownNode] = []
        var run = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "#", previous?.isWhitespace ?? true {
                var j = i + 1
                while j < chars.count {
                    if chars[j].isTagCharacter { j += 1 }
                    else if chars[j] == "/", j + 1 < chars.count, chars[j + 1].isTagCharacter { j += 1 }
                    else { break }
                }
                let name = String(chars[(i + 1)..<j])
                if !name.isEmpty, AtlasMarkdown.isValidTag(name) {
                    if !run.isEmpty { out.append(.text(value: run)); run = "" }
                    out.append(.tag(name: name))
                    previous = chars[j - 1]
                    i = j
                    continue
                }
            }
            run.append(c)
            previous = c
            i += 1
        }
        if !run.isEmpty { out.append(.text(value: run)) }
        return out
    }

    // MARK: - Restore

    private enum Context { case text, url, raw }

    /// Turns escape markers and leftover tokens back into text, and merges adjacent text.
    private func restore(_ node: MarkdownNode) -> MarkdownNode {
        func r(_ s: String, _ c: Context) -> String { restoreString(s, c) }
        func kids(_ k: [MarkdownNode]) -> [MarkdownNode] { mergeText(k.map(restore)) }
        switch node {
        case .text(let v): return .text(value: r(v, .text))
        case .code(let l, let m, let v, let id): return .code(lang: l.map { r($0, .url) }, meta: m.map { r($0, .url) }, value: r(v, .raw), blockId: id)
        case .math(let m, let v, let id): return .math(meta: m, value: r(v, .raw), blockId: id)
        case .inlineCode(let v): return .inlineCode(value: r(v, .raw))
        case .html(let v): return .html(value: r(v, .raw))
        case .link(let u, let t, let k): return .link(url: r(u, .url), title: t.map { r($0, .url) }, children: kids(k))
        case .image(let u, let t, let a): return .image(url: r(u, .url), title: t.map { r($0, .url) }, alt: r(a, .text))
        case .footnoteDefinition(let i, let l, let k): return .footnoteDefinition(identifier: r(i, .url), label: l.map { r($0, .url) }, children: kids(k))
        case .footnoteReference(let i, let l): return .footnoteReference(identifier: r(i, .url), label: l.map { r($0, .url) })
        case .callout(let t, let f, let title, let id, let k):
            return .callout(calloutType: t, fold: f, title: title.map(kids), blockId: id, children: kids(k))
        default:
            return node.children.isEmpty ? node : node.replacingChildren(kids(node.children))
        }
    }

    private func restoreString(_ s: String, _ context: Context) -> String {
        guard s.unicodeScalars.contains(where: SourcePreprocessor.isReserved) else { return s }
        var out = ""
        var scalars = s.unicodeScalars.makeIterator()
        while let c = scalars.next() {
            if c == SourcePreprocessor.tokenStart {
                let (index, read) = SourcePreprocessor.readToken(&scalars, count: tokens.count)
                if let index {
                    if case .reference(let decoded, let raw) = tokens[index] { out += context == .raw ? raw : decoded }
                    else { out += tokens[index].raw }
                } else {
                    out.unicodeScalars.append(c); out.unicodeScalars.append(contentsOf: read)
                }
            } else if let escaped = SourcePreprocessor.escapedCharacter[c] {
                // In text and URLs cmark would have processed the escape; in code it stays.
                if context == .raw { out += "\\" }
                out.append(escaped)
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private func mergeText(_ kids: [MarkdownNode]) -> [MarkdownNode] {
        var out: [MarkdownNode] = []
        for kid in kids {
            if case .text(let v) = kid {
                if v.isEmpty { continue }
                if case .text(let prev)? = out.last { out[out.count - 1] = .text(value: prev + v); continue }
            }
            out.append(kid)
        }
        return out
    }
}

// MARK: - Helpers

extension MarkdownNode {
    /// The same node with different children. Leaves are returned unchanged.
    func replacingChildren(_ kids: [MarkdownNode]) -> MarkdownNode {
        switch self {
        case .root: return .root(children: kids)
        case .paragraph(let id, _): return .paragraph(blockId: id, children: kids)
        case .heading(let d, _): return .heading(depth: d, children: kids)
        case .blockquote(let id, _): return .blockquote(blockId: id, children: kids)
        case .list(let o, let s, let sp, let id, _): return .list(ordered: o, start: s, spread: sp, blockId: id, children: kids)
        case .listItem(let c, let sp, _): return .listItem(checked: c, spread: sp, children: kids)
        case .table(let a, let id, _): return .table(align: a, blockId: id, children: kids)
        case .tableRow: return .tableRow(children: kids)
        case .tableCell: return .tableCell(children: kids)
        case .footnoteDefinition(let i, let l, _): return .footnoteDefinition(identifier: i, label: l, children: kids)
        case .callout(let t, let f, let ti, let id, _): return .callout(calloutType: t, fold: f, title: ti, blockId: id, children: kids)
        case .emphasis: return .emphasis(children: kids)
        case .strong: return .strong(children: kids)
        case .delete: return .delete(children: kids)
        case .link(let u, let t, _): return .link(url: u, title: t, children: kids)
        case .highlight: return .highlight(children: kids)
        default: return self
        }
    }

    /// Containers whose children are blocks, where a standalone block id may appear.
    var isBlockContainer: Bool {
        switch self {
        case .root, .blockquote, .listItem, .footnoteDefinition, .callout: return true
        default: return false
        }
    }

    /// The block types a standalone `^id` can name (§4.6).
    var acceptsStandaloneBlockId: Bool {
        switch self {
        case .table, .code, .blockquote, .callout, .list, .math: return true
        default: return false
        }
    }

    func settingBlockId(_ id: String) -> MarkdownNode {
        switch self {
        case .table(let a, _, let k): return .table(align: a, blockId: id, children: k)
        case .code(let l, let m, let v, _): return .code(lang: l, meta: m, value: v, blockId: id)
        case .blockquote(_, let k): return .blockquote(blockId: id, children: k)
        case .callout(let t, let f, let ti, _, let k): return .callout(calloutType: t, fold: f, title: ti, blockId: id, children: k)
        case .list(let o, let s, let sp, _, let k): return .list(ordered: o, start: s, spread: sp, blockId: id, children: k)
        case .math(let m, let v, _): return .math(meta: m, value: v, blockId: id)
        case .paragraph(_, let k): return .paragraph(blockId: id, children: k)
        default: return self
        }
    }

    /// Plain text used to decide flanking and tag boundaries. Unlike `plainText` it is not
    /// trimmed, because the whitespace at the edges is exactly what matters.
    var plainTextForFlanking: String {
        switch self {
        case .text(let v), .inlineCode(let v), .inlineMath(let v): return v
        case .wikiLink(let r), .embed(let r): return r.alias ?? r.target
        case .tag(let name): return "#" + name
        case .image(_, _, let alt): return alt
        case .break: return " "
        default: return children.map(\.plainTextForFlanking).joined()
        }
    }
}

extension Character {
    /// A character a tag may contain (§4.4): letters, marks, decimal digits, `_` and `-`.
    var isTagCharacter: Bool { unicodeScalars.allSatisfy(AtlasMarkdown.isTagScalar) }

    /// CommonMark's "Unicode punctuation character", used by the flanking rules.
    var isMarkdownPunctuation: Bool { isPunctuation || isSymbol }
}

extension String {
    func trimmingTrailing(_ chars: String) -> String {
        var s = self
        while let last = s.last, chars.contains(last) { s.removeLast() }
        return s
    }
}

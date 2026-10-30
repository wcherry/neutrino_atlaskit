import AtlasCore
import Foundation

/// What a link in the page points at, for the app to open.
public enum LinkTarget: Equatable, Sendable {
    /// A wiki link or embed (SPEC §4.2, §4.3). The app resolves it with `LinkResolver`.
    case wiki(WikiLinkReference)
    /// A Markdown link or autolink.
    case url(String)
}

/// One suggestion while a wiki link is being typed.
public struct LinkCompletion: Equatable, Sendable {
    /// What the list shows: the page's title.
    public var title: String
    /// What goes between `[[` and `]]`: the shortest target that resolves to the page
    /// (`LinkResolver.linkTarget(for:)`).
    public var target: String
    /// A second line, such as the page's folder.
    public var detail: String?

    public init(title: String, target: String, detail: String? = nil) {
        self.title = title
        self.target = target
        self.detail = detail
    }
}

/// A wiki link being typed: the text after `[[`, up to the cursor.
public struct LinkCompletionContext: Equatable, Sendable {
    /// UTF-16 offsets of the typed text (empty right after `[[`).
    public var range: Range<Int>
    public var query: String
}

extension MarkdownEditing {
    /// The link or wiki link at `offset`, and its range. The innermost one, so a link inside a
    /// link's text is the one clicked.
    public static func link(at offset: Int, in syntax: PageSyntax) -> (target: LinkTarget, range: Range<Int>)? {
        var best: (LinkTarget, Range<Int>)?
        for block in syntax.blocks where block.range.lowerBound <= offset && offset < block.range.upperBound {
            for span in block.spans where span.range.lowerBound <= offset && offset < span.range.upperBound {
                let target: LinkTarget
                switch span.kind {
                case .wikiLink(let ref), .embed(let ref): target = .wiki(ref)
                case .link(let url): target = .url(url)
                default: continue
                }
                if best == nil || span.range.count <= best!.1.count { best = (target, span.range) }
            }
        }
        return best
    }

    /// Whether a click at `offset` opens the link there: always with ⌘, and in Live Preview
    /// when the link shows as a link, because the selection isn't in it (then a click is the
    /// only way to follow it, and editing it starts with the arrow keys or ⌘-less selection).
    public static func shouldOpenLink(at offset: Int, in syntax: PageSyntax, selection: Range<Int>,
                                      mode: EditorMode, commandKey: Bool) -> LinkTarget? {
        guard let (target, range) = link(at: offset, in: syntax) else { return nil }
        if commandKey { return target }
        let touched = selection.lowerBound <= range.upperBound && selection.upperBound >= range.lowerBound
        return mode == .livePreview && !touched ? target : nil
    }

    /// The wiki link being typed at `cursor`, if any: an unclosed `[[` earlier on the line, with
    /// no `]`, `[`, `|` or `#` between it and the cursor. Not inside code.
    public static func linkCompletionContext(in text: String, cursor: Int, syntax: PageSyntax) -> LinkCompletionContext? {
        let ns = text as NSString
        guard cursor <= ns.length, !isInCode(cursor, syntax) else { return nil }
        let line = lineContent(ns, at: cursor)
        let before = ns.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let query = String(before[open.upperBound...])
        guard !query.contains(where: { "[]|#\n".contains($0) }) else { return nil }
        let start = cursor - query.utf16.count
        return LinkCompletionContext(range: start..<cursor, query: query)
    }

    /// Accepting a suggestion: the typed text becomes the target, and the link is closed with
    /// `]]` unless it already was. The cursor goes after the link.
    public static func accept(_ completion: LinkCompletion, in context: LinkCompletionContext, text: String) -> TextEdit {
        let ns = text as NSString
        let after = context.range.upperBound
        let closed = after + 2 <= ns.length && ns.substring(with: NSRange(location: after, length: 2)) == "]]"
        let replacement = completion.target + (closed ? "" : "]]")
        let end = context.range.lowerBound + replacement.utf16.count + (closed ? 2 : 0)
        return TextEdit(range: context.range, replacement: replacement, selection: end..<end)
    }

    static func isInCode(_ offset: Int, _ syntax: PageSyntax) -> Bool {
        for block in syntax.blocks where block.range.lowerBound <= offset && offset <= block.range.upperBound {
            for span in block.spans where span.range.lowerBound < offset && offset < span.range.upperBound {
                switch span.kind {
                case .inlineCode, .codeBlock, .mathBlock, .inlineMath, .frontmatter: return true
                default: continue
                }
            }
        }
        return false
    }
}

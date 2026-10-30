import AtlasCore
import Foundation

/// What a link in the page points at, for the app to open.
public enum LinkTarget: Equatable, Sendable {
    /// A wiki link or embed (SPEC §4.2, §4.3). The app resolves it with `LinkResolver`.
    case wiki(WikiLinkReference)
    /// A Markdown link or autolink.
    case url(String)
}

/// A place on a page to show: the heading or block a link points at (`[[Page#Heading]]`,
/// `[[Page#^id]]`). `AtlasTextView.reveal` finds it with `PageSyntax.anchor`.
public struct EditorAnchor: Equatable, Sendable {
    public var heading: String?
    public var blockId: String?
    /// Tells two requests apart, so following the same link again shows the place again.
    public var id = UUID()

    public init(heading: String? = nil, blockId: String? = nil) {
        self.heading = heading
        self.blockId = blockId
    }

    /// The place a link points at on its page, or nil for a link to the whole page.
    public init?(_ ref: WikiLinkReference) {
        guard ref.heading != nil || ref.blockId != nil else { return nil }
        self.init(heading: ref.heading, blockId: ref.blockId)
    }
}

/// One suggestion while a wiki link is being typed.
public struct LinkCompletion: Equatable, Sendable {
    /// What the list shows: the page's title.
    public var title: String
    /// What replaces the typed text: the shortest target that resolves to the page
    /// (`LinkResolver.linkTarget(for:)`), or after `#` the heading as a link writes it
    /// (`AtlasMarkdown.headingLinkText`).
    public var target: String
    /// A second line, such as the page's folder.
    public var detail: String?

    public init(title: String, target: String, detail: String? = nil) {
        self.title = title
        self.target = target
        self.detail = detail
    }
}

/// A wiki link being typed: the text after `[[`, up to the cursor, or after its `#` once the
/// page is named.
public struct LinkCompletionContext: Equatable, Sendable {
    /// UTF-16 offsets of the typed text (empty right after `[[` or `#`).
    public var range: Range<Int>
    public var query: String
    /// Nil while the page is typed. Once a `#` follows it, the page's target as written
    /// (empty for `[[#`, this page), and `query` is the heading typed so far.
    public var page: String?

    public init(range: Range<Int>, query: String, page: String? = nil) {
        self.range = range
        self.query = query
        self.page = page
    }
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
    /// no `]`, `[` or `|` between it and the cursor. After a `#` it's the heading being typed
    /// (`page` is set); after `#^`, a block reference, there's nothing to complete. Not inside code.
    public static func linkCompletionContext(in text: String, cursor: Int, syntax: PageSyntax) -> LinkCompletionContext? {
        let ns = text as NSString
        guard cursor <= ns.length, !isInCode(cursor, syntax) else { return nil }
        let line = lineContent(ns, at: cursor)
        let before = ns.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let typed = String(before[open.upperBound...])
        guard !typed.contains(where: { "[]|\n".contains($0) }) else { return nil }
        guard let hash = typed.firstIndex(of: "#") else {
            return LinkCompletionContext(range: (cursor - typed.utf16.count)..<cursor, query: typed)
        }
        let heading = String(typed[typed.index(after: hash)...])
        guard !heading.hasPrefix("^") else { return nil }
        let page = typed[..<hash].trimmingCharacters(in: .whitespaces)
        return LinkCompletionContext(range: (cursor - heading.utf16.count)..<cursor, query: heading, page: page)
    }

    /// Accepting a suggestion: the typed page or heading becomes its target, and the link is closed with
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

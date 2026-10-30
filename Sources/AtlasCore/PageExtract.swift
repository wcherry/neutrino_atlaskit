import Foundation
import Yams

/// What one page contributes to the index: the link graph, backlinks, tag browser, quick
/// switcher and search all build on it (SPEC §6).
public struct PageExtract: Equatable, Sendable, Codable {
    public struct Link: Equatable, Hashable, Sendable, Codable {
        public enum Kind: String, Sendable, Codable { case wiki, markdown }
        public var kind: Kind
        public var reference: WikiLinkReference

        public init(kind: Kind, reference: WikiLinkReference) {
            self.kind = kind
            self.reference = reference
        }

        // Flattened to {kind, target, heading, blockId, alias}, as in extract.json.
        public init(from decoder: Decoder) throws {
            kind = try decoder.container(keyedBy: KindKey.self).decode(Kind.self, forKey: .kind)
            reference = try WikiLinkReference(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: KindKey.self)
            try c.encode(kind, forKey: .kind)
            try reference.encode(to: encoder)
        }

        private enum KindKey: String, CodingKey { case kind }
    }

    public struct Heading: Equatable, Sendable, Codable {
        public var depth: Int
        public var text: String
    }

    /// Wiki links and internal markdown links, in document order, duplicates included.
    public var links: [Link] = []
    /// Embeds, in document order, duplicates included.
    public var embeds: [WikiLinkReference] = []
    /// Frontmatter tags then inline tags, de-duplicated case-insensitively, first spelling kept.
    public var tags: [String] = []
    public var aliases: [String] = []
    public var headings: [Heading] = []
    /// Block ids in document order, duplicates included.
    public var blockIds: [String] = []

    public init() {}

    /// Extracts a page from its parsed tree.
    public init(page root: MarkdownNode) {
        var seenTags = Set<String>()
        func addTag(_ name: String) {
            if seenTags.insert(AtlasMarkdown.matchKey(name)).inserted { tags.append(name) }
        }

        // Frontmatter comes first in `tags`, so read it before walking the body.
        if case .yaml(let value) = root.children.first {
            let frontmatter = Frontmatter(yaml: value)
            frontmatter.tags.forEach(addTag)
            aliases = frontmatter.aliases
        }

        func walk(_ node: MarkdownNode) {
            switch node {
            case .wikiLink(let ref): links.append(Link(kind: .wiki, reference: ref))
            case .link(let url, _, _):
                if let ref = Self.internalPageReference(url) { links.append(Link(kind: .markdown, reference: ref)) }
            case .embed(let ref): embeds.append(ref)
            case .tag(let name): addTag(name)
            case .heading(let depth, _): headings.append(Heading(depth: depth, text: node.plainText))
            case .callout(_, _, let title, _, _): title?.forEach(walk)
            default: break
            }
            if let id = node.blockId { blockIds.append(id) }
            node.children.forEach(walk)
        }
        walk(root)
    }

    /// The page a standard link points at, if its url is an internal page reference (SPEC §6):
    /// no scheme, not absolute or a bare fragment, and a path ending in `.md`.
    static func internalPageReference(_ url: String) -> WikiLinkReference? {
        if url.hasPrefix("/") || url.hasPrefix("#") { return nil }
        if url.hasByte(UInt8(ascii: ":")), url.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }

        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(parts[0]).removingPercentEncoding, path.lowercased().hasSuffix(".md") else { return nil }
        let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil

        var ref = WikiLinkReference(target: String(path.dropLast(3)))
        if let fragment, fragment.hasPrefix("^") {
            ref.blockId = String(fragment.dropFirst())
        } else {
            ref.heading = fragment
        }
        return ref
    }
}

/// The two frontmatter keys v1 interprets (SPEC §6). Anything unreadable contributes nothing:
/// a page must never fail to open because of its frontmatter.
struct Frontmatter {
    var tags: [String] = []
    var aliases: [String] = []

    init(yaml: String) {
        guard let map = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return }

        switch map["tags"] {
        case let list as [Any]:
            tags = list.compactMap { $0 as? String }.compactMap(Self.tag)
        case let string as String:
            tags = string.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).compactMap(Self.tag)
        default:
            break
        }

        var seen = Set<String>()
        switch map["aliases"] {
        case let list as [Any]:
            aliases = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
        case let string as String:
            aliases = [string.trimmingCharacters(in: .whitespaces)]
        default:
            break
        }
        aliases = aliases.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One leading `#` is stripped, then the value must be a valid tag.
    private static func tag(_ raw: String) -> String? {
        let name = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        return AtlasMarkdown.isValidTag(name) ? name : nil
    }
}

extension MarkdownNode {
    /// The node's plain text (SPEC §6), trimmed. Tag recognition and heading text use it.
    public var plainText: String {
        rawPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rawPlainText: String {
        switch self {
        case .text(let v), .inlineCode(let v), .inlineMath(let v): return v
        case .wikiLink(let r), .embed(let r): return r.alias ?? r.target
        case .tag(let name): return "#" + name
        case .image(_, _, let alt): return alt
        case .break: return " "
        default: return children.map(\.rawPlainText).joined()
        }
    }
}

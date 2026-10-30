import Foundation

/// A node of the Atlas Markdown tree (SPEC §3, §4): mdast plus the Atlas extensions.
///
/// The JSON form is the one the conformance corpus uses: `type` names the node, optional mdast
/// fields are always present (as `null` when unset), and source positions are not part of the
/// tree. Encoding and decoding are written out by hand to keep that shape exact. A synthesized
/// `Codable` would drop the nulls and invent its own enum layout.
public indirect enum MarkdownNode: Equatable, Sendable {
    // Blocks
    case root(children: [MarkdownNode])
    case paragraph(blockId: String?, children: [MarkdownNode])
    case heading(depth: Int, children: [MarkdownNode])
    case thematicBreak
    case blockquote(blockId: String?, children: [MarkdownNode])
    case list(ordered: Bool, start: Int?, spread: Bool, blockId: String?, children: [MarkdownNode])
    case listItem(checked: Bool?, spread: Bool, children: [MarkdownNode])
    case code(lang: String?, meta: String?, value: String, blockId: String?)
    case html(value: String)
    case table(align: [TableAlignment?], blockId: String?, children: [MarkdownNode])
    case tableRow(children: [MarkdownNode])
    case tableCell(children: [MarkdownNode])
    case definition(identifier: String, label: String?, url: String, title: String?)
    case footnoteDefinition(identifier: String, label: String?, children: [MarkdownNode])
    case yaml(value: String)
    case callout(calloutType: String, fold: CalloutFold?, title: [MarkdownNode]?, blockId: String?, children: [MarkdownNode])
    case math(meta: String?, value: String, blockId: String?)

    // Inlines
    case text(value: String)
    case emphasis(children: [MarkdownNode])
    case strong(children: [MarkdownNode])
    case delete(children: [MarkdownNode])
    case inlineCode(value: String)
    case `break`
    case link(url: String, title: String?, children: [MarkdownNode])
    case image(url: String, title: String?, alt: String)
    case linkReference(identifier: String, label: String?, referenceType: String, children: [MarkdownNode])
    case imageReference(identifier: String, label: String?, referenceType: String, alt: String)
    case footnoteReference(identifier: String, label: String?)
    case wikiLink(WikiLinkReference)
    case embed(WikiLinkReference)
    case tag(name: String)
    case highlight(children: [MarkdownNode])
    case inlineMath(value: String)

    /// The child nodes, in order. A callout's title is not included; see `callout`.
    public var children: [MarkdownNode] {
        switch self {
        case .root(let c), .paragraph(_, let c), .heading(_, let c), .blockquote(_, let c),
             .list(_, _, _, _, let c), .listItem(_, _, let c), .table(_, _, let c), .tableRow(let c),
             .tableCell(let c), .footnoteDefinition(_, _, let c), .callout(_, _, _, _, let c),
             .emphasis(let c), .strong(let c), .delete(let c), .link(_, _, let c),
             .linkReference(_, _, _, let c), .highlight(let c):
            return c
        default:
            return []
        }
    }

    /// The block id (SPEC §4.6), for the node types that can carry one.
    public var blockId: String? {
        switch self {
        case .paragraph(let id, _), .blockquote(let id, _), .list(_, _, _, let id, _), .code(_, _, _, let id),
             .table(_, let id, _), .callout(_, _, _, let id, _), .math(_, _, let id):
            return id
        default:
            return nil
        }
    }
}

/// The target and qualifiers of a wiki link or embed (SPEC §4.2, §4.3).
public struct WikiLinkReference: Equatable, Hashable, Sendable, Codable {
    /// The page or file named; empty means the linking page itself.
    public var target: String
    public var heading: String?
    public var blockId: String?
    public var alias: String?

    public init(target: String, heading: String? = nil, blockId: String? = nil, alias: String? = nil) {
        self.target = target
        self.heading = heading
        self.blockId = blockId
        self.alias = alias
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(heading, forKey: .heading)
        try c.encode(blockId, forKey: .blockId)
        try c.encode(alias, forKey: .alias)
    }
}

public enum TableAlignment: String, Equatable, Sendable, Codable {
    case left, right, center
}

/// `+` is collapsible and open, `-` collapsible and closed (SPEC §4.7).
public enum CalloutFold: String, Equatable, Sendable, Codable {
    case open = "+"
    case closed = "-"
}

// MARK: - JSON

extension MarkdownNode: Codable {
    private enum Key: String, CodingKey {
        case type, children, value, blockId, depth, ordered, start, spread, checked, lang, meta
        case align, identifier, label, url, title, alt, referenceType, name, calloutType, fold
        case target, heading, alias
    }

    public struct UnknownNodeType: Error, CustomStringConvertible {
        public let type: String
        public var description: String { "unknown Atlas Markdown node type \"\(type)\"" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        func kids() throws -> [MarkdownNode] { try c.decode([MarkdownNode].self, forKey: .children) }
        func str(_ k: Key) throws -> String { try c.decode(String.self, forKey: k) }
        // Optional fields are required keys that may be null (SPEC §3.1), so decode them with
        // `decode(Optional<T>)`: a missing key throws instead of passing as nil.
        func opt<T: Decodable>(_ k: Key, _ t: T.Type = T.self) throws -> T? { try c.decode(T?.self, forKey: k) }
        func ref() throws -> WikiLinkReference {
            WikiLinkReference(target: try str(.target), heading: try opt(.heading), blockId: try opt(.blockId), alias: try opt(.alias))
        }

        switch type {
        case "root": self = .root(children: try kids())
        case "paragraph": self = .paragraph(blockId: try opt(.blockId), children: try kids())
        case "heading": self = .heading(depth: try c.decode(Int.self, forKey: .depth), children: try kids())
        case "thematicBreak": self = .thematicBreak
        case "blockquote": self = .blockquote(blockId: try opt(.blockId), children: try kids())
        case "list":
            self = .list(ordered: try c.decode(Bool.self, forKey: .ordered), start: try opt(.start),
                         spread: try c.decode(Bool.self, forKey: .spread), blockId: try opt(.blockId), children: try kids())
        case "listItem":
            self = .listItem(checked: try opt(.checked), spread: try c.decode(Bool.self, forKey: .spread), children: try kids())
        case "code": self = .code(lang: try opt(.lang), meta: try opt(.meta), value: try str(.value), blockId: try opt(.blockId))
        case "html": self = .html(value: try str(.value))
        case "table":
            self = .table(align: try c.decode([TableAlignment?].self, forKey: .align), blockId: try opt(.blockId), children: try kids())
        case "tableRow": self = .tableRow(children: try kids())
        case "tableCell": self = .tableCell(children: try kids())
        case "definition":
            self = .definition(identifier: try str(.identifier), label: try opt(.label), url: try str(.url), title: try opt(.title))
        case "footnoteDefinition":
            self = .footnoteDefinition(identifier: try str(.identifier), label: try opt(.label), children: try kids())
        case "yaml": self = .yaml(value: try str(.value))
        case "callout":
            self = .callout(calloutType: try str(.calloutType), fold: try opt(.fold), title: try opt(.title),
                            blockId: try opt(.blockId), children: try kids())
        case "math": self = .math(meta: try opt(.meta), value: try str(.value), blockId: try opt(.blockId))
        case "text": self = .text(value: try str(.value))
        case "emphasis": self = .emphasis(children: try kids())
        case "strong": self = .strong(children: try kids())
        case "delete": self = .delete(children: try kids())
        case "inlineCode": self = .inlineCode(value: try str(.value))
        case "break": self = .break
        case "link": self = .link(url: try str(.url), title: try opt(.title), children: try kids())
        case "image": self = .image(url: try str(.url), title: try opt(.title), alt: try str(.alt))
        case "linkReference":
            self = .linkReference(identifier: try str(.identifier), label: try opt(.label),
                                  referenceType: try str(.referenceType), children: try kids())
        case "imageReference":
            self = .imageReference(identifier: try str(.identifier), label: try opt(.label),
                                   referenceType: try str(.referenceType), alt: try str(.alt))
        case "footnoteReference": self = .footnoteReference(identifier: try str(.identifier), label: try opt(.label))
        case "wikiLink": self = .wikiLink(try ref())
        case "embed": self = .embed(try ref())
        case "tag": self = .tag(name: try str(.name))
        case "highlight": self = .highlight(children: try kids())
        case "inlineMath": self = .inlineMath(value: try str(.value))
        default: throw UnknownNodeType(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        // `encode(Optional)` writes an explicit null, which the corpus requires.
        func put<T: Encodable>(_ k: Key, _ v: T) throws { try c.encode(v, forKey: k) }
        func type(_ t: String) throws { try put(.type, t) }
        func ref(_ r: WikiLinkReference) throws {
            try put(.target, r.target); try put(.heading, r.heading); try put(.blockId, r.blockId); try put(.alias, r.alias)
        }

        switch self {
        case .root(let k): try type("root"); try put(.children, k)
        case .paragraph(let id, let k): try type("paragraph"); try put(.blockId, id); try put(.children, k)
        case .heading(let d, let k): try type("heading"); try put(.depth, d); try put(.children, k)
        case .thematicBreak: try type("thematicBreak")
        case .blockquote(let id, let k): try type("blockquote"); try put(.blockId, id); try put(.children, k)
        case .list(let o, let s, let sp, let id, let k):
            try type("list"); try put(.ordered, o); try put(.start, s); try put(.spread, sp); try put(.blockId, id); try put(.children, k)
        case .listItem(let ch, let sp, let k): try type("listItem"); try put(.checked, ch); try put(.spread, sp); try put(.children, k)
        case .code(let l, let m, let v, let id): try type("code"); try put(.lang, l); try put(.meta, m); try put(.value, v); try put(.blockId, id)
        case .html(let v): try type("html"); try put(.value, v)
        case .table(let a, let id, let k): try type("table"); try put(.align, a); try put(.blockId, id); try put(.children, k)
        case .tableRow(let k): try type("tableRow"); try put(.children, k)
        case .tableCell(let k): try type("tableCell"); try put(.children, k)
        case .definition(let i, let l, let u, let t):
            try type("definition"); try put(.identifier, i); try put(.label, l); try put(.url, u); try put(.title, t)
        case .footnoteDefinition(let i, let l, let k):
            try type("footnoteDefinition"); try put(.identifier, i); try put(.label, l); try put(.children, k)
        case .yaml(let v): try type("yaml"); try put(.value, v)
        case .callout(let t, let f, let ti, let id, let k):
            try type("callout"); try put(.calloutType, t); try put(.fold, f); try put(.title, ti); try put(.blockId, id); try put(.children, k)
        case .math(let m, let v, let id): try type("math"); try put(.meta, m); try put(.value, v); try put(.blockId, id)
        case .text(let v): try type("text"); try put(.value, v)
        case .emphasis(let k): try type("emphasis"); try put(.children, k)
        case .strong(let k): try type("strong"); try put(.children, k)
        case .delete(let k): try type("delete"); try put(.children, k)
        case .inlineCode(let v): try type("inlineCode"); try put(.value, v)
        case .break: try type("break")
        case .link(let u, let t, let k): try type("link"); try put(.url, u); try put(.title, t); try put(.children, k)
        case .image(let u, let t, let a): try type("image"); try put(.url, u); try put(.title, t); try put(.alt, a)
        case .linkReference(let i, let l, let r, let k):
            try type("linkReference"); try put(.identifier, i); try put(.label, l); try put(.referenceType, r); try put(.children, k)
        case .imageReference(let i, let l, let r, let a):
            try type("imageReference"); try put(.identifier, i); try put(.label, l); try put(.referenceType, r); try put(.alt, a)
        case .footnoteReference(let i, let l): try type("footnoteReference"); try put(.identifier, i); try put(.label, l)
        case .wikiLink(let r): try type("wikiLink"); try ref(r)
        case .embed(let r): try type("embed"); try ref(r)
        case .tag(let n): try type("tag"); try put(.name, n)
        case .highlight(let k): try type("highlight"); try put(.children, k)
        case .inlineMath(let v): try type("inlineMath"); try put(.value, v)
        }
    }
}

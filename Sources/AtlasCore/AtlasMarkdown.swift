import Foundation

extension String {
    /// Whether the string contains this ASCII byte. Far cheaper than Foundation's
    /// `contains(_: String)`, which the type checker picks for a string literal and which
    /// searches character by character.
    func hasByte(_ byte: UInt8) -> Bool { utf8.contains(byte) }

    /// Whether the string contains this ASCII byte twice in a row (`==`, `$$`).
    func hasBytePair(_ byte: UInt8) -> Bool {
        var previous: UInt8 = 0
        for b in utf8 {
            if b == byte && previous == byte { return true }
            previous = b
        }
        return false
    }
}

/// Rules of the Atlas Markdown dialect that more than one part of AtlasCore needs.
public enum AtlasMarkdown {
    /// The spec this package implements. It must match the vendored corpus's manifest.
    public static let specVersion = "1.0.0-draft.4"

    /// The key two strings are compared by, for tags and link resolution: NFC, then
    /// case-folded (SPEC §4.4, §7). Display always keeps the original spelling.
    public static func matchKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether `name` (without its `#`) is a tag under SPEC §4.4: `/`-separated segments of
    /// letters, marks, decimal digits, `_` and `-`, not made of digits alone.
    public static func isValidTag(_ name: String) -> Bool {
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(isTagScalar) }) else { return false }
        return name.unicodeScalars.contains { $0 != "/" && $0.properties.generalCategory != .decimalNumber }
    }

    static func isTagScalar(_ s: Unicode.Scalar) -> Bool {
        if s == "_" || s == "-" { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }
}

extension AtlasMarkdown {
    /// Parses a page into its Atlas Markdown tree (SPEC §3, §4).
    ///
    /// cmark-gfm handles the CommonMark + GFM base; the Atlas extensions are layered around
    /// it (see `SourcePreprocessor` and `ExtensionPasses`). Source positions are not part of
    /// the tree.
    public static func parse(_ source: String) -> MarkdownNode {
        .root(children: parseLayout(source).map(\.node))
    }

    /// The top-level blocks of a page, in order, each with the 1-based source lines it
    /// occupies. Frontmatter is the first block when present. Source preservation (§8.1)
    /// is built on this.
    /// What in-place edits need to know about one block's text (SPEC §8.2): its tree, where its
    /// wiki links and embeds are (character ranges, in tree order), and where its task items
    /// start (line and byte column of the list marker, in tree order). Never call it on
    /// frontmatter.
    struct Anatomy {
        var blocks: [MarkdownNode]
        var links: [Range<Int>]
        var tasks: [(line: Int, column: Int)]
        /// Text the parser treats as opaque: code spans, and every wiki link, embed and inline
        /// math token. Markdown link syntax inside these isn't a link.
        var opaque: [Range<Int>]
    }

    static func anatomy(of text: String) -> Anatomy {
        let prepared = SourcePreprocessor(text)
        let converted = CMarkConverter.convertTopLevelWithTasks(prepared.cmarkSource)
        let passes = ExtensionPasses(tokens: prepared.tokens)
        let blocks = passes.applyTopLevel(converted.blocks).map(\.node)
        let links = passes.materialized.indices.compactMap { prepared.tokenSourceRanges[$0] }
        return Anatomy(blocks: blocks, links: links, tasks: converted.tasks,
                       opaque: prepared.codeSpanRanges + Array(prepared.tokenSourceRanges.values))
    }

    static func parseLayout(_ source: String) -> [(node: MarkdownNode, lines: ClosedRange<Int>)] {
        let prepared = SourcePreprocessor(source)
        var blocks = ExtensionPasses(tokens: prepared.tokens).applyTopLevel(CMarkConverter.convertTopLevel(prepared.cmarkSource))
        if let frontmatter = prepared.frontmatter {
            blocks.insert((.yaml(value: frontmatter), 1...prepared.frontmatterLineCount), at: 0)
        }
        return blocks
    }
}

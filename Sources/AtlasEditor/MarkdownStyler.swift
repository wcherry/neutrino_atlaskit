import AtlasCore
import Foundation

/// How a run of text looks, independent of the platform. The views turn it into fonts and
/// colours through `EditorTheme`.
public struct TextStyle: Hashable, Sendable {
    public enum FontRole: Hashable, Sendable { case body, heading(Int), monospace }
    public enum ColorRole: Hashable, Sendable { case text, syntax, link, tag, quote, secondary }

    public var font: FontRole = .body
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var highlight = false
    public var codeBackground = false
    public var color: ColorRole = .text
    /// Live Preview hides this syntax: the cursor isn't in the construct it belongs to.
    public var hidden = false

    public init() {}
}

public struct StyleRun: Equatable, Sendable {
    /// UTF-16 offsets into the page.
    public var range: Range<Int>
    public var style: TextStyle
}

public enum EditorMode: Sendable {
    /// Markdown styled in place, with syntax hidden away from the cursor (Obsidian's Live Preview).
    case livePreview
    /// Every character shown, still styled.
    case source
}

/// Turns a page's syntax map into style runs.
public enum MarkdownStyler {
    /// The runs for one block, covering its whole range. `selection` is in UTF-16 offsets; a
    /// construct is revealed when the selection touches it, ends included, so the cursor never
    /// moves through hidden characters: they show as soon as it reaches them.
    public static func runs(for block: PageSyntax.Block, selection: Range<Int>, mode: EditorMode) -> [StyleRun] {
        let spans = block.spans
        guard !block.range.isEmpty else { return [] }

        // Each syntax span belongs to the innermost construct around it: `**` to its strong,
        // `## ` to its heading. With none, the block is its construct.
        let constructs = spans.filter { if case .syntax = $0.kind { return false }; return true }
        func owner(of s: SyntaxSpan) -> Range<Int> {
            var best = block.range
            for c in constructs where c.range.lowerBound <= s.range.lowerBound && s.range.upperBound <= c.range.upperBound {
                if c.range.count <= best.count { best = c.range }
            }
            return best
        }
        func revealed(_ r: Range<Int>) -> Bool {
            mode == .source || (selection.lowerBound <= r.upperBound && selection.upperBound >= r.lowerBound)
        }
        let hidden: [Bool] = spans.map { span in
            guard case .syntax(let role) = span.kind, role.isConcealable else { return false }
            return !revealed(owner(of: span))
        }

        var cuts = Set([block.range.lowerBound, block.range.upperBound])
        for s in spans {
            cuts.insert(max(s.range.lowerBound, block.range.lowerBound))
            cuts.insert(min(s.range.upperBound, block.range.upperBound))
        }
        let points = cuts.sorted()

        var runs: [StyleRun] = []
        for (a, b) in zip(points, points.dropFirst()) where a < b {
            var style = TextStyle()
            // Outer spans first, so inner ones refine them.
            for (k, s) in spans.enumerated() where s.range.lowerBound <= a && b <= s.range.upperBound {
                apply(s.kind, to: &style)
                if hidden[k] { style.hidden = true }
            }
            if let last = runs.last, last.style == style, last.range.upperBound == a {
                runs[runs.count - 1].range = last.range.lowerBound..<b
            } else {
                runs.append(StyleRun(range: a..<b, style: style))
            }
        }
        return runs
    }

    static func apply(_ kind: SyntaxSpan.Kind, to style: inout TextStyle) {
        switch kind {
        case .heading(let level): style.font = .heading(level); style.bold = true
        case .strong: style.bold = true
        case .emphasis: style.italic = true
        case .strikethrough: style.strikethrough = true
        case .highlight: style.highlight = true
        case .inlineCode, .codeBlock, .mathBlock: style.font = .monospace; style.codeBackground = true
        case .inlineMath, .table: style.font = .monospace
        case .frontmatter: style.font = .monospace; style.color = .secondary
        case .htmlBlock, .inlineHTML: style.color = .secondary
        case .link, .image, .wikiLink, .embed, .footnoteReference: style.color = .link
        case .tag: style.color = .tag
        case .blockquote, .callout: style.color = .quote
        case .thematicBreak: style.color = .syntax
        case .listItem, .footnoteDefinition: break
        case .syntax: style.color = .syntax
        }
    }
}

extension SyntaxRole {
    /// Syntax that Live Preview hides. List and task markers, quote bars, fences, pipes and
    /// callout markers stay: they are what the reader sees as the structure.
    public var isConcealable: Bool {
        switch self {
        case .headingMarker, .delimiter, .linkBracket, .linkDestination, .wikiBracket, .wikiTarget,
             .escape, .blockId, .hardBreak:
            return true
        default:
            return false
        }
    }
}

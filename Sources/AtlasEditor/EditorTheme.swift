#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

#if canImport(AppKit) || canImport(UIKit)
import AtlasCore

/// Fonts and colours for each `TextStyle`. Colours are the system's semantic ones, so light
/// and dark mode follow the system.
public struct EditorTheme {
    public var fontSize: CGFloat
    /// Heading sizes relative to `fontSize`, for levels 1 to 6.
    public var headingScale: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.0, 1.0]
    public var lineHeightMultiple: CGFloat = 1.2

    public init(fontSize: CGFloat = Self.defaultFontSize) {
        self.fontSize = fontSize
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public static let defaultFontSize: CGFloat = 15
    #else
    public static let defaultFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize
    #endif

    public func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        if style.hidden {
            // Hidden syntax keeps its characters (the text is the file) but takes no space.
            return [.font: PlatformFont.systemFont(ofSize: 0.01), .foregroundColor: PlatformColor.clear, .paragraphStyle: paragraph]
        }
        var size = fontSize
        if case .heading(let level) = style.font { size *= headingScale[max(0, min(level - 1, headingScale.count - 1))] }

        var font: PlatformFont
        switch style.font {
        case .monospace:
            font = .monospacedSystemFont(ofSize: size * 0.92, weight: style.bold ? .bold : .regular)
        case .body, .heading:
            font = .systemFont(ofSize: size, weight: style.bold ? (style.font == .body ? .bold : .semibold) : .regular)
        }
        if style.italic { font = italic(font) }

        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(style.color), .paragraphStyle: paragraph]
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.highlight {
            attributes[.backgroundColor] = PlatformColor.systemYellow.withAlphaComponent(0.35)
        } else if style.codeBackground {
            attributes[.backgroundColor] = PlatformColor.systemGray.withAlphaComponent(0.15)
        }
        return attributes
    }

    func color(_ role: TextStyle.ColorRole) -> PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        switch role {
        case .text: return .labelColor
        case .syntax: return .tertiaryLabelColor
        case .link: return .linkColor
        case .tag: return .systemPurple
        case .quote, .secondary: return .secondaryLabelColor
        }
        #else
        switch role {
        case .text: return .label
        case .syntax: return .tertiaryLabel
        case .link: return .link
        case .tag: return .systemPurple
        case .quote, .secondary: return .secondaryLabel
        }
        #endif
    }

    private func italic(_ font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        #else
        guard let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: d, size: font.pointSize)
        #endif
    }
}

/// What both views share: the current syntax map, and applying style runs to their storage.
@MainActor
final class EditorStyling {
    var mode: EditorMode = .livePreview
    var theme = EditorTheme() { didSet { cache = [:] } }
    private(set) var syntax = AtlasMarkdown.syntax(of: "")
    private var cache: [TextStyle: [NSAttributedString.Key: Any]] = [:]
    private var styledSelection = 0..<0

    func attributes(_ style: TextStyle) -> [NSAttributedString.Key: Any] {
        if let a = cache[style] { return a }
        let a = theme.attributes(for: style)
        cache[style] = a
        return a
    }

    var baseAttributes: [NSAttributedString.Key: Any] { attributes(TextStyle()) }

    /// Re-maps the text and restyles all of it.
    func restyleAll(_ storage: NSTextStorage, selection: Range<Int>) {
        syntax = AtlasMarkdown.syntax(of: storage.string)
        styledSelection = selection
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        for block in syntax.blocks { apply(block, storage, selection) }
        storage.endEditing()
    }

    /// After the selection moved: restyles only the blocks it left or entered.
    func selectionChanged(_ storage: NSTextStorage, to selection: Range<Int>) {
        guard mode == .livePreview, selection != styledSelection else { styledSelection = selection; return }
        let old = styledSelection
        styledSelection = selection
        func touches(_ b: PageSyntax.Block, _ r: Range<Int>) -> Bool { r.lowerBound <= b.range.upperBound && r.upperBound >= b.range.lowerBound }
        let affected = syntax.blocks.filter { touches($0, old) || touches($0, selection) }
        guard !affected.isEmpty else { return }
        storage.beginEditing()
        for block in affected { apply(block, storage, selection) }
        storage.endEditing()
    }

    private func apply(_ block: PageSyntax.Block, _ storage: NSTextStorage, _ selection: Range<Int>) {
        guard block.range.upperBound <= storage.length else { return }
        storage.setAttributes(baseAttributes, range: NSRange(location: block.range.lowerBound, length: block.range.count))
        for run in MarkdownStyler.runs(for: block, selection: selection, mode: mode) {
            storage.setAttributes(attributes(run.style), range: NSRange(location: run.range.lowerBound, length: run.range.count))
        }
    }
}

#endif

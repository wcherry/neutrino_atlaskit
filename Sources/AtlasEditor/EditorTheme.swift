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
import ImageIO

/// Fonts and colours for each `TextStyle`. Colours are the system's semantic ones, so light
/// and dark mode follow the system.
public struct EditorTheme {
    public var fontSize: CGFloat
    /// Heading sizes relative to `fontSize`, for levels 1 to 6.
    public var headingScale: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.0, 1.0]
    public var lineHeightMultiple: CGFloat = 1.2
    /// Space above and below an image shown in Live Preview.
    public var imagePadding: CGFloat = 6

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

/// An image drawn in place of its block (`EditorStyling.image`), at `size` points.
final class ShownImage: NSObject {
    let image: CGImage
    let size: CGSize

    init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }

    /// Decodes PNG, JPEG, GIF, HEIC and the rest with ImageIO, which both platforms have.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `data` re-encoded as PNG: for TIFF, which the Mac's pasteboard uses for images and
    /// which isn't a format to keep in a vault.
    static func png(from data: Data) -> Data? {
        guard let image = decode(data) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The size to draw `image` at: its pixel size (or the width asked for), no wider than `available`.
    static func size(of image: CGImage, width asked: Int?, available: CGFloat) -> CGSize {
        let natural = CGSize(width: image.width, height: image.height)
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let width = max(1, min(asked.map(CGFloat.init) ?? natural.width, available))
        return CGSize(width: width, height: (natural.height * width / natural.width).rounded())
    }
}

extension NSAttributedString.Key {
    /// On the characters of a block shown as an image: its `ShownImage`.
    static let atlasImage = NSAttributedString.Key("AtlasImage")
}

/// What both views share: the current syntax map, and applying style runs to their storage.
@MainActor
final class EditorStyling {
    var mode: EditorMode = .livePreview
    var theme = EditorTheme() { didSet { cache = [:] } }
    /// The image to show for a block in Live Preview, and its size; nil shows its Markdown.
    var image: ((BlockImage) -> ShownImage?)?
    /// The blocks showing an image now.
    private(set) var imageBlocks: [Range<Int>] = []
    /// Which links show as chips (`LinkChip`); nil, or nil for a link, leaves them as links.
    var linkChip: ((String) -> LinkChip?)?
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
        imageBlocks = []
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
        imageBlocks.removeAll { $0 == block.range }
        if mode == .livePreview, !(selection.lowerBound <= block.range.upperBound && selection.upperBound >= block.range.lowerBound),
           let image, let found = MarkdownEditing.blockImage(block, in: storage.string, allowingURL: { self.linkChip?($0) != nil }),
           let shown = image(found) {
            // The Markdown stays, hidden; the line is as tall as the image, which the view's
            // layout fragment draws there.
            var attributes = attributes({ var s = TextStyle(); s.hidden = true; return s }())
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = shown.size.height + 2 * theme.imagePadding
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            attributes[.paragraphStyle] = paragraph
            attributes[.atlasImage] = shown
            storage.setAttributes(attributes, range: NSRange(location: block.range.lowerBound, length: block.range.count))
            imageBlocks.append(block.range)
            return
        }
        storage.setAttributes(baseAttributes, range: NSRange(location: block.range.lowerBound, length: block.range.count))
        for run in MarkdownStyler.runs(for: block, selection: selection, mode: mode) {
            storage.setAttributes(attributes(run.style), range: NSRange(location: run.range.lowerBound, length: run.range.count))
        }
        if mode == .livePreview, let linkChip { markChips(block, storage, selection, linkChip) }
    }

    /// Links the app shows as chips, away from the cursor: `[text](url)` only, whose `[` makes
    /// the symbol's slot.
    private func markChips(_ block: PageSyntax.Block, _ storage: NSTextStorage, _ selection: Range<Int>, _ linkChip: (String) -> LinkChip?) {
        let ns = storage.string as NSString
        for span in block.spans {
            // A link, or a preview with nothing to show (no thumbnail): its `!` stays hidden.
            let url: String, slot: Int
            switch span.kind {
            case .link(let u): url = u; slot = span.range.lowerBound
            case .image(let u): url = u; slot = span.range.lowerBound + 1
            default: continue
            }
            guard span.range.count > 2, slot < span.range.upperBound,
                  !(selection.lowerBound <= span.range.upperBound && selection.upperBound >= span.range.lowerBound),
                  ns.character(at: slot) == 0x5B /* [ */, let chip = linkChip(url) else { continue }
            storage.addAttribute(.atlasChip, value: ChipMark(symbol: chip.symbol), range: NSRange(location: slot, length: span.range.upperBound - slot))
            // The `[` takes the symbol's width, unseen.
            let font = PlatformFont.systemFont(ofSize: theme.fontSize)
            let bracket = ("[" as NSString).size(withAttributes: [.font: font]).width
            storage.addAttributes([.font: font, .foregroundColor: PlatformColor.clear, .kern: max(0, min(theme.fontSize, 14) + 5 - bracket)],
                                  range: NSRange(location: slot, length: 1))
        }
    }
}

extension AtlasTextView {
    /// An image's bytes from the app, decoded, logging why when there's nothing to show.
    static func decode(_ source: ImageSource, _ imageData: (ImageSource) -> Data?) -> CGImage? {
        let name: String
        switch source {
        case .embed(let ref): name = "![[\(ref.target)]]"
        case .path(let path): name = "![](\(path))"
        case .url(let url): name = "![](\(url))"
        }
        guard let data = imageData(source) else {
            if case .url = source {
                AtlasLog.images.info("\(name): no preview (yet); shown as a chip")
            } else {
                AtlasLog.images.notice("\(name): no such image in the vault")
            }
            return nil
        }
        guard let image = ShownImage.decode(data) else {
            AtlasLog.images.error("\(name): \(data.count) bytes that aren't an image this device can decode (\(ImageImport.fileExtension(of: data) ?? "unknown type"))")
            return nil
        }
        AtlasLog.images.info("\(name): \(image.width)×\(image.height) px")
        return image
    }
}

/// Gives a paragraph shown as an image (`.atlasImage`) a layout fragment that draws it, and one
/// with link chips (`.atlasChip`) one that draws them.
final class ImageFragments: NSObject, NSTextLayoutManagerDelegate {
    var padding: CGFloat = 6

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let text = paragraph.attributedString
            if let shown = text.attribute(.atlasImage, at: 0, effectiveRange: nil) as? ShownImage {
                return ImageLayoutFragment(textElement: textElement, range: textElement.elementRange, image: shown, padding: padding)
            }
            var chips = false
            text.enumerateAttribute(.atlasChip, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if value != nil { chips = true; stop.pointee = true }
            }
            if chips { return ChipLayoutFragment(textElement: textElement, range: textElement.elementRange) }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

final class ImageLayoutFragment: NSTextLayoutFragment {
    let shown: ShownImage
    let padding: CGFloat

    init(textElement: NSTextElement, range: NSTextRange?, image: ShownImage, padding: CGFloat) {
        shown = image
        self.padding = padding
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var imageRect: CGRect {
        let inset = textLineFragments.first?.typographicBounds.minX ?? 0
        return CGRect(x: inset, y: padding, width: shown.size.width, height: shown.size.height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(imageRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        // The hidden Markdown draws nothing; the image goes in the line made for it. Both
        // platforms' text views draw top-down, so flip for Core Graphics' bottom-up image.
        let r = imageRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        context.translateBy(x: r.minX, y: r.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(shown.image, in: CGRect(origin: .zero, size: r.size))
        context.restoreGState()
    }
}

#endif

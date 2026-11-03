import Foundation

/// How a link shows as a chip in Live Preview (roadmap Phase 1, "links to other Neutrino files
/// as rich chips"): its text on a tinted background, after an SF Symbol. The app decides which
/// links are chips; for Atlas, links to Neutrino Docs, Sheets, Slides, Notes and Drive files.
public struct LinkChip: Hashable, Sendable {
    /// An SF Symbol name, such as `doc.text`.
    public var symbol: String

    public init(symbol: String) {
        self.symbol = symbol
    }
}

#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif
import CoreGraphics

/// On a link shown as a chip: its symbol. Its `[`, kept but made clear and widened, is the
/// slot the symbol is drawn in.
final class ChipMark: NSObject {
    let symbol: String
    init(symbol: String) { self.symbol = symbol }
}

extension NSAttributedString.Key {
    static let atlasChip = NSAttributedString.Key("AtlasChip")
}

/// Draws the chips in a paragraph behind its text: a rounded tint over each, and its symbol in
/// the slot its `[` leaves.
final class ChipLayoutFragment: NSTextLayoutFragment {
    var tint: CGColor = PlatformColor.linkColorForChips.cgColor

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph else { return super.draw(at: point, in: context) }
        let text = paragraph.attributedString
        for line in textLineFragments {
            let lineRange = line.characterRange
            text.enumerateAttribute(.atlasChip, in: lineRange) { value, range, _ in
                guard let mark = value as? ChipMark else { return }
                let end = min(range.location + range.length, lineRange.location + lineRange.length)
                let x0 = line.locationForCharacter(at: range.location).x
                let x1 = line.locationForCharacter(at: end).x
                let bounds = line.typographicBounds
                let chip = CGRect(x: point.x + bounds.minX + x0 - 2, y: point.y + bounds.minY + 1,
                                  width: x1 - x0 + 4, height: max(0, bounds.height - 2))
                context.saveGState()
                context.setFillColor(tint.copy(alpha: 0.14) ?? tint)
                context.addPath(CGPath(roundedRect: chip, cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.fillPath()
                let side = min(chip.height - 4, 14)
                if let symbol = Self.symbol(mark.symbol, size: side) {
                    let icon = CGRect(x: chip.minX + 3, y: chip.midY - side / 2, width: side, height: side)
                    // Top-down views; Core Graphics masks bottom-up.
                    context.translateBy(x: icon.minX, y: icon.maxY)
                    context.scaleBy(x: 1, y: -1)
                    let fitted = CGRect(origin: .zero, size: icon.size)
                    context.clip(to: fitted, mask: symbol)
                    context.setFillColor(tint)
                    context.fill(fitted)
                }
                context.restoreGState()
            }
        }
        super.draw(at: point, in: context)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.insetBy(dx: -4, dy: -2) }

    private static var symbols: [String: CGImage] = [:]

    /// An SF Symbol as a mask, `size` points square.
    static func symbol(_ name: String, size: CGFloat) -> CGImage? {
        let key = "\(name)@\(size)"
        if let cached = symbols[key] { return cached }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        let cg = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 2, weight: .medium))?.cgImage
        #endif
        symbols[key] = cg
        return cg
    }
}

extension PlatformColor {
    static var linkColorForChips: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .linkColor
        #else
        .link
        #endif
    }
}
#endif

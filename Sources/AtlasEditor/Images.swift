import AtlasCore
import Foundation

/// Where an image in a page comes from. The app turns it into bytes: it resolves the file in
/// the vault and reads it from the encrypted copy, so nothing is written out to show it.
public enum ImageSource: Hashable, Sendable {
    /// `![[photo.png]]`, resolved like a wiki link (SPEC §4.3).
    case embed(WikiLinkReference)
    /// `![alt](photo.png)`: a path in the vault, as written, percent-decoded.
    case path(String)
}

/// An image that a block of its own shows in Live Preview (roadmap Phase 1, "images" in the
/// editor), in place of its Markdown while the cursor is elsewhere.
public struct BlockImage: Equatable, Sendable {
    public var source: ImageSource
    /// The width asked for with an embed's display hint, `![[photo.png|300]]` or `|300x200`
    /// (SPEC §4.3 keeps the hint verbatim; Obsidian reads it this way).
    public var width: Int?
}

extension MarkdownEditing {
    /// File types shown as images. Others (`.pdf`, `.mp3`) stay links.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    /// The image `block` shows: a paragraph holding one image or image embed and nothing else
    /// but spaces. An image inside a sentence stays a link. Web images aren't shown: fetching one
    /// would tell its server which page is being read, so they stay links too.
    public static func blockImage(_ block: PageSyntax.Block, in text: String) -> BlockImage? {
        guard case .paragraph = block.node else { return nil }
        let constructs = block.spans.filter { if case .syntax = $0.kind { return false }; return true }
        guard constructs.count == 1, let span = constructs.first else { return nil }
        let ns = text as NSString
        guard block.range.upperBound <= ns.length else { return nil }
        let before = ns.substring(with: NSRange(location: block.range.lowerBound, length: span.range.lowerBound - block.range.lowerBound))
        let after = ns.substring(with: NSRange(location: span.range.upperBound, length: block.range.upperBound - span.range.upperBound))
        guard (before + after).allSatisfy(\.isWhitespace) else { return nil }

        switch span.kind {
        case .embed(let ref):
            guard imageExtensions.contains((ref.target as NSString).pathExtension.lowercased()) else { return nil }
            let width = ref.alias.flatMap { Int($0.split(separator: "x", maxSplits: 1).first ?? "") }.flatMap { $0 > 0 ? $0 : nil }
            return BlockImage(source: .embed(ref), width: width)
        case .image(let url):
            let path = url.removingPercentEncoding ?? url
            // A scheme (`https:`, `data:`) or a host (`//cdn…`) means it isn't in the vault.
            guard !path.hasPrefix("//"), URL(string: url)?.scheme == nil,
                  imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
            return BlockImage(source: .path(path), width: nil)
        default:
            return nil
        }
    }
}

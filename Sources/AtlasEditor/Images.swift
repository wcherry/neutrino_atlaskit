import AtlasCore
import Foundation

/// Where an image in a page comes from. The app turns it into bytes: it resolves the file in
/// the vault and reads it from the encrypted copy, so nothing is written out to show it.
public enum ImageSource: Hashable, Sendable {
    /// `![[photo.png]]`, resolved like a wiki link (SPEC §4.3).
    case embed(WikiLinkReference)
    /// `![alt](photo.png)`: a path in the vault, as written, percent-decoded.
    case path(String)
    /// `![Q4 plan](https://…/open/doc/<id>)`: a preview of a file the app links to (its Drive
    /// thumbnail), for a URL the app vouches for. Other web images are never fetched.
    case url(String)
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
    ///
    /// `allowingURL` names the web URLs that may show anyway: the app's own links to files on its
    /// server, fetched with the user's own session, which tells nobody else anything.
    public static func blockImage(_ block: PageSyntax.Block, in text: String, allowingURL: (String) -> Bool = { _ in false }) -> BlockImage? {
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
        case .image(let url) where allowingURL(url):
            return BlockImage(source: .url(url), width: nil)
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

/// An image to add to a page, from a paste, a drop or a picker: its bytes, and its file name
/// when it had one (a pasted screenshot doesn't).
public struct ImageImport: Equatable, Sendable {
    public var data: Data
    public var name: String?

    public init(data: Data, name: String? = nil) {
        self.data = data
        self.name = name
    }

    /// The file extension the bytes call for, from their signature: nil for anything that isn't
    /// an image Atlas shows.
    public static func fileExtension(of data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        func starts(_ p: [UInt8], at k: Int = 0) -> Bool { b.count >= k + p.count && Array(b[k..<(k + p.count)]) == p }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "webp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts(Array("BM".utf8)) { return "bmp" }
        if starts(Array("ftyp".utf8), at: 4), let brand = String(bytes: b.dropFirst(8).prefix(4), encoding: .ascii),
           ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(brand) { return "heic" }
        return nil
    }
}

extension MarkdownEditing {
    /// Embeds `targets` (`![[target]]`) in place of the selection, each a block of its own, with
    /// blank lines around, so that Live Preview shows them as images. The cursor goes after the last.
    public static func insertEmbeds(_ targets: [String], in text: String, selection: Range<Int>) -> TextEdit? {
        insertBlocks(targets.map { "![[\($0)]]" }, in: text, selection: selection)
    }

    /// `blocks` in place of the selection, each a paragraph of its own, with blank lines around.
    public static func insertBlocks(_ blocks: [String], in text: String, selection: Range<Int>) -> TextEdit? {
        guard !blocks.isEmpty else { return nil }
        let ns = text as NSString
        let first = lineContent(ns, at: selection.lowerBound), last = lineContent(ns, at: selection.upperBound)
        let head = ns.substring(with: NSRange(location: first.location, length: selection.lowerBound - first.location))
        let tail = ns.substring(with: NSRange(location: selection.upperBound, length: last.location + last.length - selection.upperBound))
        func blank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

        var before = "", after = ""
        if !blank(head) {
            before = "\n\n"
        } else if first.location > 0, !blank(ns.substring(with: lineContent(ns, at: first.location - 1))) {
            before = "\n"
        }
        let lineEnd = last.location + last.length
        if !blank(tail) {
            after = "\n\n"
        } else if lineEnd < ns.length, !blank(ns.substring(with: lineContent(ns, at: lineEnd + 1))) {
            after = "\n"
        }
        // On an otherwise empty line the embeds replace the line's spaces too.
        let range = blank(head) ? first.location..<(blank(tail) ? lineEnd : selection.upperBound) : selection
        let embeds = blocks.joined(separator: "\n\n")
        let cursor = range.lowerBound + (before + embeds).utf16.count
        return TextEdit(range: range, replacement: before + embeds + after, selection: cursor..<cursor)
    }
}

extension MarkdownEditing {
    /// The link or image at `offset` whose URL `isFileLink` accepts (a link to a Neutrino file),
    /// and whether it shows as a preview (`![…](…)`) rather than a chip (`[…](…)`).
    public static func fileLink(at offset: Int, in syntax: PageSyntax, isFileLink: (String) -> Bool) -> (range: Range<Int>, isPreview: Bool)? {
        for block in syntax.blocks where block.range.lowerBound <= offset && offset <= block.range.upperBound {
            for span in block.spans where span.range.lowerBound <= offset && offset < span.range.upperBound {
                switch span.kind {
                case .link(let url) where isFileLink(url): return (span.range, false)
                case .image(let url) where isFileLink(url): return (span.range, true)
                default: continue
                }
            }
        }
        return nil
    }

    /// Show as Preview / Show as Chip for the file link at `offset`. A preview is `![…](…)` on a
    /// line of its own, so a link inside a sentence moves to its own line below; a chip is the
    /// link with its `!` taken off, where it stands.
    public static func setPreview(_ preview: Bool, linkAt offset: Int, in text: String, syntax: PageSyntax,
                                  isFileLink: (String) -> Bool) -> TextEdit? {
        guard let found = fileLink(at: offset, in: syntax, isFileLink: isFileLink), found.isPreview != preview else { return nil }
        let ns = text as NSString
        let r = found.range
        if !preview {
            // Drop the `!`.
            return TextEdit(range: r.lowerBound..<(r.lowerBound + 1), replacement: "", selection: (r.upperBound - 1)..<(r.upperBound - 1))
        }
        let link = ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
        let line = lineContent(ns, at: r.lowerBound)
        let lineText = ns.substring(with: line)
        let rest = (lineText as NSString).replacingCharacters(in: NSRange(location: r.lowerBound - line.location, length: r.count), with: "")
        if rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
            return TextEdit(range: r.lowerBound..<r.lowerBound, replacement: "!", selection: (r.upperBound + 1)..<(r.upperBound + 1))
        }
        // In a sentence: the link leaves it (spaces closed up) and goes below as a block.
        var before = ns.substring(with: NSRange(location: line.location, length: r.lowerBound - line.location))
        var after = ns.substring(with: NSRange(location: r.upperBound, length: line.location + line.length - r.upperBound))
        if before.hasSuffix(" ") && (after.hasPrefix(" ") || after.isEmpty || after.first.map { ",.;:!?)".contains($0) } == true) { before.removeLast() }
        if before.isEmpty, after.hasPrefix(" ") { after.removeFirst() }
        let kept = before + after
        let lineEnd = line.location + line.length
        let replacement = kept + "\n\n!" + link + (lineEnd < ns.length && !(ns.substring(with: lineContent(ns, at: lineEnd + 1)).allSatisfy { $0 == " " || $0 == "\t" }) ? "\n" : "")
        let cursor = line.location + (kept + "\n\n!" + link).utf16.count
        return TextEdit(range: line.location..<lineEnd, replacement: replacement, selection: cursor..<cursor)
    }
}

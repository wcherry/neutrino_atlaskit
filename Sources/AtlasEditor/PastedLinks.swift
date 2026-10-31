import AtlasCore
import Foundation

extension MarkdownEditing {
    /// What pasting a copied link inserts: `[Title](url)` when the clipboard holds a single
    /// http(s) URL as text and, as HTML, nothing but one link to that URL with its title, the
    /// way a browser's or Neutrino Notes' "Copy link" puts it there. Nil otherwise, and the
    /// paste is plain text as usual.
    public static func pastedLink(plain: String, html: String?) -> String? {
        let url = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let html, !url.isEmpty, !url.contains(where: \.isWhitespace),
              let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let ns = html as NSString
        let anchors = anchorPattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard anchors.count == 1, let anchor = anchors.first,
              decodeEntities(ns.substring(with: anchor.range(at: 2))) == url else { return nil }
        // Nothing to show besides the link: a copied paragraph that merely contains it is text.
        let outside = ns.replacingCharacters(in: anchor.range, with: "")
        guard plainText(outside).isEmpty else { return nil }
        let title = plainText(ns.substring(with: anchor.range(at: 3)))
        guard !title.isEmpty, title != url else { return nil }
        // Escaped so the title shows as written: not a nested link, emphasis or code.
        let text = title.reduce(into: "") { out, ch in
            if "\\[]*`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        let destination = url.contains(where: { "()<>".contains($0) }) ? "<\(url.replacingOccurrences(of: ">", with: "%3E"))>" : url
        return "[\(text)](\(destination))"
    }

    /// Pasting a copied link at `selection`: the edit, or nil for an ordinary paste. Code, math
    /// and frontmatter take text as it is.
    public static func pasteLink(plain: String, html: String?, in text: String, selection: Range<Int>, syntax: PageSyntax) -> TextEdit? {
        guard !isInCode(selection.lowerBound, syntax), !isInVerbatimBlock(selection.lowerBound, syntax),
              let markdown = pastedLink(plain: plain, html: html) else { return nil }
        let end = selection.lowerBound + markdown.utf16.count
        return TextEdit(range: selection, replacement: markdown, selection: end..<end)
    }

    // `<a … href="url" …>text</a>`, with the href quoted either way.
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// HTML's visible text: tags, comments and `<meta>`/`<style>` dropped, entities decoded,
    /// whitespace collapsed.
    private static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<!--.*?-->|<style\b.*?</style\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return decodeEntities(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric references, then `&amp;` last so `&amp;lt;` stays `&lt;`.
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in (try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)).matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = ns.substring(with: m.range(at: 1))
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

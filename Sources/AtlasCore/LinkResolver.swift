import Foundation

/// Resolves link targets to vault files, and picks the target to write for a new link
/// (SPEC §7). It runs only on the client, against the decrypted vault paths. The server never
/// sees titles or the link graph (neutrino-atlas.md, constraint 2).
///
/// Paths are relative to the vault root, use `/`, and include the extension.
public struct LinkResolver: Sendable {
    private struct Entry: Sendable {
        let path: String
        let key: String        // match key of the path, `.md` stripped for pages
        let segments: Int
        let isPage: Bool
    }

    private let entries: [Entry]

    public init<Paths: Sequence>(files: Paths) where Paths.Element == String {
        entries = files.map { path in
            let isPage = Self.isPageName(path)
            let key = AtlasMarkdown.matchKey(isPage ? String(path.dropLast(3)) : path)
            return Entry(path: path, key: key, segments: path.split(separator: "/").count, isPage: isPage)
        }
    }

    /// The file `target` names, or nil when the link is unresolved. Where the link appears
    /// matters only for an empty target, which means the linking page itself.
    public func resolve(_ target: String, from linkingPage: String) -> String? {
        if target.isEmpty { return linkingPage }

        var t = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
        let lastSegment = t.split(separator: "/").last.map(String.init) ?? t
        let wantsPage = !Self.hasExtension(lastSegment) || Self.isPageName(lastSegment)
        if wantsPage && Self.isPageName(t) { t = String(t.dropLast(3)) }
        let key = AtlasMarkdown.matchKey(t)

        let hits = entries.filter { $0.isPage == wantsPage && ($0.key == key || $0.key.hasSuffix("/" + key)) }
        if let exact = hits.first(where: { $0.key == key }) { return exact.path }
        return hits.min { a, b in
            a.segments != b.segments ? a.segments < b.segments : a.key.unicodeScalars.lexicographicallyPrecedes(b.key.unicodeScalars)
        }?.path
    }

    /// The target to write when inserting a link to `file`: the first of the bare name, the
    /// last two segments, three, … that resolves back to it. A page's `.md` is never written.
    public func linkTarget(for file: String) -> String {
        let name = Self.isPageName(file) ? String(file.dropLast(3)) : file
        let parts = name.split(separator: "/").map(String.init)
        for n in 1...max(parts.count, 1) {
            let candidate = parts.suffix(n).joined(separator: "/")
            if resolve(candidate, from: "") == file { return candidate }
        }
        return name
    }

    private static func isPageName(_ s: String) -> Bool { s.lowercased().hasSuffix(".md") }

    private static func hasExtension(_ segment: String) -> Bool {
        guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else { return false }
        return segment.index(after: dot) != segment.endIndex
    }
}

import Foundation

extension VaultIndex {
    // MARK: - Links

    /// A link from one page to another, as indexed.
    public struct IndexedLink: Equatable, Sendable {
        /// The page the link is on.
        public var source: String
        public var kind: LinkOccurrence.Kind
        public var reference: WikiLinkReference
        /// The file it resolves to (SPEC §7), or nil if unresolved.
        public var resolved: String?
    }

    /// Links to `path` from other pages (and from itself, for heading links), grouped by page
    /// in title order, links in document order. The backlinks panel, and what a rename must
    /// rewrite.
    public func backlinks(to path: String) throws -> [IndexedLink] {
        try links(where: "links.resolved = ?", [.text(path)])
    }

    /// The pages with links to `path`: the pages to rewrite (`MarkdownDocument.rewriteLinks`)
    /// before `path` is renamed. Same-page links don't count.
    public func pagesLinking(to path: String) throws -> [String] {
        var pages: [String] = []
        try db.query("""
            SELECT DISTINCT pages.path FROM links JOIN pages ON pages.id = links.page
            WHERE links.resolved = ? AND links.target != '' ORDER BY pages.path
            """, [.text(path)]) { if let p = $0.text(0) { pages.append(p) } }
        return pages
    }

    /// The links on `path`, in document order.
    public func outgoingLinks(from path: String) throws -> [IndexedLink] {
        try links(where: "pages.path = ?", [.text(path)])
    }

    /// Link targets that don't resolve, with how many links use each: pages to create.
    public func unresolvedTargets() throws -> [(target: String, count: Int)] {
        var out: [(String, Int)] = []
        try db.query("""
            SELECT target, count(*) FROM links WHERE resolved IS NULL AND target != ''
            GROUP BY target_key ORDER BY count(*) DESC, target
            """) { out.append(($0.text(0) ?? "", Int($0.int(1)))) }
        return out
    }

    private func links(where condition: String, _ bindings: [SQLiteDatabase.Value]) throws -> [IndexedLink] {
        var out: [IndexedLink] = []
        try db.query("""
            SELECT pages.path, links.kind, links.target, links.heading, links.block, links.alias, links.resolved
            FROM links JOIN pages ON pages.id = links.page WHERE \(condition)
            ORDER BY pages.title_key, pages.path, links.ord
            """, bindings) { row in
            out.append(IndexedLink(source: row.text(0) ?? "", kind: Self.kind(row.int(1)),
                                   reference: WikiLinkReference(target: row.text(2) ?? "", heading: row.text(3), blockId: row.text(4), alias: row.text(5)),
                                   resolved: row.text(6)))
        }
        return out
    }

    // MARK: - Unlinked mentions

    /// A place where a page's title or alias appears in another page's text without a link.
    public struct Mention: Equatable, Sendable {
        public var source: String
        /// The title or alias that appears.
        public var name: String
        public var snippet: Snippet
    }

    /// Pages that mention `path`'s title or one of its aliases as a phrase, but don't link to
    /// it (§1 Phase 1, "unlinked mentions"). Ordered by relevance.
    public func unlinkedMentions(of path: String, limit: Int = 50) throws -> [Mention] {
        guard let id = try pageID(path) else { return [] }
        var names = [Self.title(of: path)]
        try db.query("SELECT alias FROM aliases WHERE page = ?", [.int(id)]) { if let a = $0.text(0) { names.append(a) } }
        var linking = Set<Int64>()
        try db.query("SELECT DISTINCT page FROM links WHERE resolved = ?", [.text(path)]) { linking.insert($0.int(0)) }

        var seen = Set<Int64>()
        var out: [Mention] = []
        for name in names where !name.isEmpty {
            try db.query("""
                SELECT fts.rowid, pages.path, snippet(fts, 2, char(1), char(2), '…', 12)
                FROM fts JOIN pages ON pages.id = fts.rowid
                WHERE fts MATCH ? ORDER BY rank LIMIT ?
                """, [.text("body : " + Self.phrase(name)), .int(Int64(limit))]) { row in
                let page = row.int(0)
                guard page != id, !linking.contains(page), seen.insert(page).inserted else { return }
                out.append(Mention(source: row.text(1) ?? "", name: name, snippet: Snippet(marked: row.text(2) ?? "")))
            }
        }
        return Array(out.prefix(limit))
    }

    // MARK: - Search

    /// Text around a search match. `matches` are the matched words' ranges in `text`.
    public struct Snippet: Equatable, Sendable {
        public var text: String
        public var matches: [Range<String.Index>]

        /// From FTS5's `snippet()` output, with matches marked by U+0001 … U+0002.
        init(marked: String) {
            var text = "", matches: [Range<String.Index>] = [], start: String.Index?
            for c in marked {
                if c == "\u{1}" { start = text.endIndex }
                else if c == "\u{2}", let s = start { matches.append(s..<text.endIndex); start = nil }
                else { text.append(c) }
            }
            // Indices taken while appending stay valid for the finished string.
            self.text = text
            self.matches = matches
        }
    }

    public struct SearchHit: Equatable, Sendable {
        public var path: String
        public var title: String
        public var snippet: Snippet
    }

    /// Full-text search. Words match as prefixes (`plan` finds "planning"), `"quoted phrases"`
    /// exactly, `-word` excludes. `#tag` or `tag:tag` keeps pages with that tag or a tag nested
    /// under it; `path:folder` keeps pages under that folder. Matching ignores case and
    /// diacritics. Titles weigh more than aliases, and aliases more than body text. With only
    /// filters, every matching page is returned in title order.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let parsed = SearchQuery(query)
        var conditions: [String] = [], bindings: [SQLiteDatabase.Value] = []
        for tag in parsed.tags {
            // Uncorrelated, so SQLite evaluates it once rather than once per candidate page.
            conditions.append("pages.id IN (SELECT page FROM tags WHERE tag_key = ? OR tag_key LIKE ? ESCAPE '\\')")
            let key = AtlasMarkdown.matchKey(tag)
            bindings += [.text(key), .text(Self.likeEscaped(key) + "/%")]
        }
        for folder in parsed.folders {
            conditions.append("(pages.path LIKE ? ESCAPE '\\')")
            bindings.append(.text(Self.likeEscaped(folder.hasSuffix("/") ? folder : folder + "/") + "%"))
        }
        let filter = conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")

        var hits: [SearchHit] = []
        if let match = parsed.ftsExpression {
            try db.query("""
                SELECT pages.path, pages.title, snippet(fts, 2, char(1), char(2), '…', 12)
                FROM fts JOIN pages ON pages.id = fts.rowid
                WHERE fts MATCH ?\(filter) ORDER BY rank LIMIT ?
                """, [.text(match)] + bindings + [.int(Int64(limit))]) { row in
                hits.append(SearchHit(path: row.text(0) ?? "", title: row.text(1) ?? "", snippet: Snippet(marked: row.text(2) ?? "")))
            }
        } else if !conditions.isEmpty {
            try db.query("SELECT pages.path, pages.title FROM pages WHERE 1\(filter) ORDER BY pages.title_key LIMIT ?",
                         bindings + [.int(Int64(limit))]) { row in
                hits.append(SearchHit(path: row.text(0) ?? "", title: row.text(1) ?? "", snippet: Snippet(marked: "")))
            }
        }
        return hits
    }

    /// A query string split into its parts. Words and phrases become an FTS5 expression in which
    /// every term is quoted, so nothing the user types is read as FTS5 syntax.
    struct SearchQuery {
        var terms: [(text: String, phrase: Bool, negated: Bool)] = []
        var tags: [String] = []
        var folders: [String] = []

        init(_ query: String) {
            var chars = Array(query)[...]
            while let c = chars.first {
                if c.isWhitespace { chars = chars.dropFirst(); continue }
                var negated = false
                if c == "-", chars.count > 1, !(chars.dropFirst().first!.isWhitespace) { negated = true; chars = chars.dropFirst() }
                if chars.first == "\"" {
                    chars = chars.dropFirst()
                    let phrase = String(chars.prefix(while: { $0 != "\"" }))
                    chars = chars.dropFirst(phrase.count).dropFirst()
                    if !phrase.trimmingCharacters(in: .whitespaces).isEmpty { terms.append((phrase, true, negated)) }
                    continue
                }
                let word = String(chars.prefix(while: { !$0.isWhitespace }))
                chars = chars.dropFirst(word.count)
                if word.hasPrefix("#"), word.count > 1, !negated { tags.append(String(word.dropFirst())) }
                else if word.lowercased().hasPrefix("tag:"), word.count > 4, !negated { tags.append(String(word.dropFirst(4)).trimmingPrefix("#")) }
                else if word.lowercased().hasPrefix("path:"), word.count > 5, !negated { folders.append(String(word.dropFirst(5))) }
                else { terms.append((word, false, negated)) }
            }
        }

        /// The FTS5 MATCH expression, or nil when there are no positive terms (FTS5 can't
        /// express a query that only excludes).
        var ftsExpression: String? {
            let positive = terms.filter { !$0.negated }
            guard !positive.isEmpty else { return nil }
            var expression = positive.map { $0.phrase ? VaultIndex.phrase($0.text) : VaultIndex.phrase($0.text) + "*" }.joined(separator: " AND ")
            for term in terms where term.negated { expression += " NOT " + VaultIndex.phrase(term.text) }
            return expression
        }
    }

    /// `text` as an FTS5 string literal: quoted, inner quotes doubled.
    static func phrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Quick switcher

    public struct SwitcherHit: Equatable, Sendable {
        public var path: String
        public var title: String
        /// The alias that matched, if it was an alias rather than the title.
        public var alias: String?
        public var score: Int
    }

    /// Pages whose title or alias fuzzily matches `query`, best first (the `⌘O` switcher).
    /// An exact title beats a prefix, and a prefix beats anything else. Otherwise matches are
    /// scored fzf-style: points per matched character, bonuses at word starts and for
    /// consecutive runs, penalties for gaps and for long titles. A query with `/` also matches
    /// against the folder path.
    public func quickSwitch(_ query: String, limit: Int = 20) throws -> [SwitcherHit] {
        let q = AtlasMarkdown.matchKey(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var best: [String: SwitcherHit] = [:]
        func consider(path: String, title: String, candidate: String, alias: String?) {
            guard let score = Self.fuzzyScore(q, AtlasMarkdown.matchKey(candidate)) else { return }
            if score > (best[path]?.score ?? Int.min) { best[path] = SwitcherHit(path: path, title: title, alias: alias, score: score) }
        }
        try db.query("SELECT path, title FROM pages") { row in
            let path = row.text(0) ?? "", title = row.text(1) ?? ""
            consider(path: path, title: title, candidate: title, alias: nil)
            if q.contains("/") { consider(path: path, title: title, candidate: String(path.dropLast(3)), alias: nil) }
        }
        try db.query("SELECT pages.path, pages.title, aliases.alias FROM aliases JOIN pages ON pages.id = aliases.page") { row in
            let alias = row.text(2) ?? ""
            consider(path: row.text(0) ?? "", title: row.text(1) ?? "", candidate: alias, alias: alias)
        }
        return Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }.prefix(limit))
    }

    // MARK: - Headings

    /// The headings on `path`, in document order.
    public func headings(of path: String) throws -> [PageExtract.Heading] {
        var out: [PageExtract.Heading] = []
        try db.query("""
            SELECT headings.depth, headings.text FROM headings JOIN pages ON pages.id = headings.page
            WHERE pages.path = ? ORDER BY headings.ord
            """, [.text(path)]) { row in out.append(PageExtract.Heading(depth: Int(row.int(0)), text: row.text(1) ?? "")) }
        return out
    }

    /// Headings to suggest after `[[Page#`: those `query` fuzzily matches, best first, or all
    /// of them in document order when it's empty. Headings that would be written the same in a
    /// link (`AtlasMarkdown.headingLinkText`) are suggested once, as the first resolves.
    public static func matchingHeadings(_ headings: [PageExtract.Heading], _ query: String, limit: Int = 20) -> [PageExtract.Heading] {
        var seen = Set<String>()
        let unique = headings.filter { h in
            let key = AtlasMarkdown.headingKey(h.text)
            return !key.isEmpty && seen.insert(key).inserted
        }
        let q = AtlasMarkdown.matchKey(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Array(unique.prefix(limit)) }
        let scored = unique.enumerated().compactMap { i, h in fuzzyScore(q, AtlasMarkdown.headingKey(h.text)).map { (i, h, $0) } }
        return Array(scored.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.map(\.1).prefix(limit))
    }

    /// A match score, or nil if `query` isn't a subsequence of `candidate`. Both already folded.
    static func fuzzyScore(_ query: String, _ candidate: String) -> Int? {
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 8_000 - candidate.count }
        // Leftmost subsequence match, scored like fzf.
        var score = 0, previous: Character? = nil, inRun = false, gap = 0
        var q = query.makeIterator(), want = q.next()
        for c in candidate {
            guard let w = want else { break }
            if c == w {
                score += 16
                if previous.map(isBoundary) ?? true { score += 8 }
                if inRun { score += 6 }
                if gap > 0 { score -= 3 + (gap - 1) }
                inRun = true
                gap = 0
                want = q.next()
            } else {
                if score > 0 || gap > 0 { gap += 1 }
                inRun = false
            }
            previous = c
        }
        guard want == nil else { return nil }
        return score - candidate.count / 4
    }

    private static func isBoundary(_ c: Character) -> Bool { c == " " || c == "/" || c == "-" || c == "_" || c == "." }

    // MARK: - Tags

    /// Every tag with the number of pages using it, nested tags as written (`project/atlas`),
    /// grouped case-insensitively under the alphabetically first spelling.
    public func tags() throws -> [(tag: String, count: Int)] {
        var out: [(String, Int)] = []
        try db.query("SELECT min(tag), count(DISTINCT page) FROM tags GROUP BY tag_key ORDER BY tag_key") {
            out.append(($0.text(0) ?? "", Int($0.int(1))))
        }
        return out
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}

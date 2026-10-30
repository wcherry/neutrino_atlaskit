import Foundation

/// The index of one vault: what every page contributes (SPEC §6), resolved links (§7), and
/// full-text search. It lives only on the device (neutrino-atlas.md, constraints 2 and 4):
/// the server never sees titles, links, tags or text.
///
/// The index is an in-memory SQLite database with FTS5. At rest it is one snapshot, sealed by
/// an `IndexSealer` (see `snapshot(sealedWith:)`), so no plaintext ever reaches the disk.
///
/// Not thread-safe: confine an instance to one actor or queue.
public final class VaultIndex {
    let db: SQLiteDatabase
    private var files: Set<String> = []
    private var resolverCache: LinkResolver?
    /// Inside `batch`: links are stored unresolved and resolved once at the end.
    private var deferringResolution = false

    /// The schema version. A snapshot written by another version is rejected, and the app
    /// rebuilds the index from the pages.
    public static let schemaVersion = 1

    /// An empty index.
    public init() throws {
        db = try SQLiteDatabase()
        try Self.createSchema(db)
    }

    static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE files(path TEXT PRIMARY KEY);
            CREATE TABLE pages(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                               title_key TEXT NOT NULL, modified REAL);
            CREATE TABLE links(page INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, ord INTEGER NOT NULL,
                               kind INTEGER NOT NULL, target TEXT NOT NULL, heading TEXT, block TEXT, alias TEXT,
                               target_key TEXT NOT NULL, resolved TEXT);
            CREATE INDEX links_resolved ON links(resolved);
            CREATE INDEX links_target_key ON links(target_key);
            CREATE INDEX links_page ON links(page);
            CREATE TABLE tags(page INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, tag TEXT NOT NULL, tag_key TEXT NOT NULL);
            CREATE INDEX tags_key ON tags(tag_key);
            CREATE TABLE aliases(page INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, alias TEXT NOT NULL);
            CREATE TABLE headings(page INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, ord INTEGER NOT NULL,
                                  depth INTEGER NOT NULL, text TEXT NOT NULL);
            CREATE TABLE block_ids(page INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, id TEXT NOT NULL);
            CREATE VIRTUAL TABLE fts USING fts5(title, aliases, body, tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO fts(fts, rank) VALUES ('rank', 'bm25(10.0, 5.0, 1.0)');
            """)
        try db.query("INSERT INTO meta(key, value) VALUES ('schema', ?)", [.text(String(schemaVersion))])
    }

    // MARK: - Files and pages

    /// Runs many updates as one: a first import, or a sync that brings in many pages. Link
    /// resolution waits until the end, so the batch costs one resolution pass rather than
    /// one per new file.
    public func batch(_ body: () throws -> Void) throws {
        let outer = !deferringResolution
        deferringResolution = true
        defer { if outer { deferringResolution = false } }
        try db.transaction {
            try body()
            if outer { try resolveAllLinks() }
        }
    }

    private func resolveAllLinks() throws {
        resolverCache = nil
        var updates: [(rowid: Int64, resolved: String?)] = []
        try db.query("SELECT links.rowid, links.target, pages.path FROM links JOIN pages ON pages.id = links.page") { row in
            updates.append((row.int(0), self.resolver.resolve(row.text(1) ?? "", from: row.text(2) ?? "")))
        }
        for update in updates {
            try db.query("UPDATE links SET resolved = ? WHERE rowid = ?", [Self.optional(update.resolved), .int(update.rowid)])
        }
    }

    /// The number of indexed pages.
    public var pageCount: Int {
        (try? scalarInt("SELECT count(*) FROM pages")) ?? 0
    }

    /// Records the vault's files that aren't pages (attachments), so links and embeds to them
    /// resolve. Pages are recorded by `upsertPage`.
    public func addFile(_ path: String) throws {
        guard !files.contains(path) else { return }
        try db.query("INSERT OR IGNORE INTO files(path) VALUES (?)", [.text(path)])
        files.insert(path)
        try fileSetChanged(keys: [Self.fileKey(path)])
    }

    public func removeFile(_ path: String) throws {
        if Self.isPage(path) { return try removePage(path) }
        guard files.contains(path) else { return }
        try db.query("DELETE FROM files WHERE path = ?", [.text(path)])
        files.remove(path)
        try fileSetChanged(keys: [Self.fileKey(path)])
    }

    /// Indexes a page from its Markdown source, replacing what was indexed for it before.
    public func upsertPage(_ path: String, source: String, modified: Date? = nil) throws {
        let tree = AtlasMarkdown.parse(source)
        try upsertPage(path, tree: tree, modified: modified)
    }

    /// Indexes a page from its already-parsed tree.
    public func upsertPage(_ path: String, tree: MarkdownNode, modified: Date? = nil) throws {
        let extract = PageExtract(page: tree)
        let title = Self.title(of: path)
        let isNewFile = !files.contains(path)
        try db.transaction {
            let id: Int64
            if let existing = try pageID(path) {
                id = existing
                try db.query("UPDATE pages SET title = ?, title_key = ?, modified = ? WHERE id = ?",
                             [.text(title), .text(AtlasMarkdown.matchKey(title)), modified.map { .double($0.timeIntervalSince1970) } ?? .null, .int(id)])
                for table in ["links", "tags", "aliases", "headings", "block_ids"] {
                    try db.query("DELETE FROM \(table) WHERE page = ?", [.int(id)])
                }
                try db.query("DELETE FROM fts WHERE rowid = ?", [.int(id)])
            } else {
                try db.query("INSERT INTO pages(path, title, title_key, modified) VALUES (?, ?, ?, ?)",
                             [.text(path), .text(title), .text(AtlasMarkdown.matchKey(title)), modified.map { .double($0.timeIntervalSince1970) } ?? .null])
                id = db.lastInsertedRow
                try db.query("INSERT OR IGNORE INTO files(path) VALUES (?)", [.text(path)])
            }
            files.insert(path)
            if isNewFile { resolverCache = nil }

            var ord = 0
            func addLink(_ kind: LinkOccurrence.Kind, _ ref: WikiLinkReference) throws {
                let resolved = deferringResolution ? nil : resolver.resolve(ref.target, from: path)
                try db.query("""
                    INSERT INTO links(page, ord, kind, target, heading, block, alias, target_key, resolved)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(id), .int(Int64(ord)), .int(Self.kindCode(kind)), .text(ref.target), Self.optional(ref.heading),
                          Self.optional(ref.blockId), Self.optional(ref.alias), .text(Self.targetKey(ref.target)), Self.optional(resolved)])
                ord += 1
            }
            for link in extract.links { try addLink(link.kind == .wiki ? .wiki : .markdown, link.reference) }
            for embed in extract.embeds { try addLink(.embed, embed) }
            for tag in extract.tags {
                try db.query("INSERT INTO tags(page, tag, tag_key) VALUES (?, ?, ?)", [.int(id), .text(tag), .text(AtlasMarkdown.matchKey(tag))])
            }
            for alias in extract.aliases { try db.query("INSERT INTO aliases(page, alias) VALUES (?, ?)", [.int(id), .text(alias)]) }
            for (i, heading) in extract.headings.enumerated() {
                try db.query("INSERT INTO headings(page, ord, depth, text) VALUES (?, ?, ?, ?)",
                             [.int(id), .int(Int64(i)), .int(Int64(heading.depth)), .text(heading.text)])
            }
            for blockId in extract.blockIds { try db.query("INSERT INTO block_ids(page, id) VALUES (?, ?)", [.int(id), .text(blockId)]) }
            try db.query("INSERT INTO fts(rowid, title, aliases, body) VALUES (?, ?, ?, ?)",
                         [.int(id), .text(title), .text(extract.aliases.joined(separator: "\n")), .text(Self.searchText(of: tree))])
        }
        // A new file can change what other pages' links resolve to.
        if isNewFile { try fileSetChanged(keys: [Self.fileKey(path)]) }
    }

    public func removePage(_ path: String) throws {
        guard let id = try pageID(path) else { return }
        try db.transaction {
            try db.query("DELETE FROM fts WHERE rowid = ?", [.int(id)])
            try db.query("DELETE FROM pages WHERE id = ?", [.int(id)])
            try db.query("DELETE FROM files WHERE path = ?", [.text(path)])
        }
        files.remove(path)
        try fileSetChanged(keys: [Self.fileKey(path)])
    }

    /// Renames or moves a page (or attachment) in the index. The pages that linked to it keep
    /// their old link text until they are rewritten (`MarkdownDocument.rewriteLinks`) and
    /// re-indexed: call `pagesLinking(to:)` before renaming to find them.
    public func renameFile(from old: String, to new: String) throws {
        guard old != new else { return }
        if let id = try pageID(old) {
            let title = Self.title(of: new)
            try db.transaction {
                try db.query("UPDATE pages SET path = ?, title = ?, title_key = ? WHERE id = ?",
                             [.text(new), .text(title), .text(AtlasMarkdown.matchKey(title)), .int(id)])
                try db.query("UPDATE fts SET title = ? WHERE rowid = ?", [.text(title), .int(id)])
                try db.query("DELETE FROM files WHERE path = ?", [.text(old)])
                try db.query("INSERT OR IGNORE INTO files(path) VALUES (?)", [.text(new)])
                // A same-page link (empty target) resolves to its own page, wherever it moved.
                try db.query("UPDATE links SET resolved = ? WHERE page = ? AND target = ''", [.text(new), .int(id)])
            }
        } else {
            try db.query("DELETE FROM files WHERE path = ?", [.text(old)])
            try db.query("INSERT OR IGNORE INTO files(path) VALUES (?)", [.text(new)])
        }
        files.remove(old)
        files.insert(new)
        try fileSetChanged(keys: [Self.fileKey(old), Self.fileKey(new)])
    }

    /// After loading a snapshot: the in-memory file set comes from the database.
    func restoreFileSet() throws {
        files = []
        try db.query("SELECT path FROM files") { if let p = $0.text(0) { self.files.insert(p) } }
        resolverCache = nil
    }

    // MARK: - Resolution

    private var resolver: LinkResolver {
        if let resolverCache { return resolverCache }
        let built = LinkResolver(files: files)
        resolverCache = built
        return built
    }

    /// The file set changed: re-resolve exactly the links whose target names one of these files.
    private func fileSetChanged(keys: Set<String>) throws {
        resolverCache = nil
        guard !deferringResolution else { return }
        var updates: [(rowid: Int64, resolved: String?)] = []
        for key in keys {
            try db.query("""
                SELECT links.rowid, links.target, pages.path FROM links JOIN pages ON pages.id = links.page
                WHERE links.target_key = ?
                """, [.text(key)]) { row in
                updates.append((row.int(0), self.resolver.resolve(row.text(1) ?? "", from: row.text(2) ?? "")))
            }
        }
        guard !updates.isEmpty else { return }
        try db.transaction {
            for update in updates {
                try db.query("UPDATE links SET resolved = ? WHERE rowid = ?", [Self.optional(update.resolved), .int(update.rowid)])
            }
        }
    }

    // MARK: - Helpers

    func pageID(_ path: String) throws -> Int64? {
        var id: Int64?
        try db.query("SELECT id FROM pages WHERE path = ?", [.text(path)]) { id = $0.int(0) }
        return id
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteDatabase.Value] = []) throws -> Int {
        var value = 0
        try db.query(sql, bindings) { value = Int($0.int(0)) }
        return value
    }

    static func optional(_ s: String?) -> SQLiteDatabase.Value { s.map { .text($0) } ?? .null }

    static func kindCode(_ kind: LinkOccurrence.Kind) -> Int64 {
        switch kind { case .wiki: 0; case .markdown: 1; case .embed: 2 }
    }

    static func kind(_ code: Int64) -> LinkOccurrence.Kind {
        switch code { case 1: .markdown; case 2: .embed; default: .wiki }
    }

    static func isPage(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// A page's title: its file name without `.md` (titles are file names, as in Obsidian).
    static func title(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return isPage(name) ? String(name.dropLast(3)) : name
    }

    /// The key a link target is filed under for re-resolution: its last segment, as matched.
    static func targetKey(_ target: String) -> String {
        var last = target.split(separator: "/").last.map(String.init) ?? target
        if isPage(last) { last = String(last.dropLast(3)) }
        return AtlasMarkdown.matchKey(last)
    }

    /// The same key for a file: its name, without `.md` for a page.
    static func fileKey(_ path: String) -> String { targetKey(path) }

    /// The text full-text search sees: every block's plain text, one block per line, code and
    /// math included, frontmatter left out (its tags and aliases are indexed on their own).
    static func searchText(of tree: MarkdownNode) -> String {
        var lines: [String] = []
        func walk(_ node: MarkdownNode) {
            switch node {
            case .yaml: return
            case .paragraph, .heading, .tableCell:
                lines.append(node.plainTextForFlanking)
            case .code(_, _, let value, _), .math(_, let value, _), .html(let value):
                lines.append(value)
            case .callout(_, _, let title, _, let kids):
                if let title { lines.append(title.map(\.plainTextForFlanking).joined()) }
                kids.forEach(walk)
            default:
                node.children.forEach(walk)
            }
        }
        walk(tree)
        return lines.joined(separator: "\n")
    }
}

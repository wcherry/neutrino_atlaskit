import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import AtlasCore

/// A test-only sealer. The app seals with NeutrinoCrypto (root CLAUDE.md, rule 5).
private struct TestSealer: IndexSealer {
    static let shared = TestSealer()
    let key = SymmetricKey(size: .bits256)
    func seal(_ plaintext: Data) throws -> Data { try ChaChaPoly.seal(plaintext, using: key).combined }
    func open(_ sealed: Data) throws -> Data { try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key) }
}

final class VaultIndexTests: XCTestCase {
    private func index(_ pages: [String: String], files: [String] = []) throws -> VaultIndex {
        let index = try VaultIndex()
        try index.batch {
            for file in files { try index.addFile(file) }
            for (path, source) in pages.sorted(by: { $0.key < $1.key }) { try index.upsertPage(path, source: source) }
        }
        return index
    }

    func testFTS5IsAvailableOnThisPlatform() {
        XCTAssertEqual(sqlite3_compileoption_used("ENABLE_FTS5"), 1)
    }

    // MARK: Links

    func testBacklinksAcrossLinkKinds() throws {
        let index = try self.index([
            "A.md": "See [[B]], [[Projects/C|the C]], [b](B.md#Intro) and ![[img.png]]. Also [[Missing]].\n",
            "B.md": "Back to [[A#Top]] and [[#Intro]].\n\n# Intro\n",
            "Projects/C.md": "Nothing.\n",
        ], files: ["img.png"])

        XCTAssertEqual(try index.backlinks(to: "B.md").map(\.source), ["A.md", "A.md", "B.md"])
        XCTAssertEqual(try index.backlinks(to: "B.md").map(\.kind), [.wiki, .markdown, .wiki])
        XCTAssertEqual(try index.backlinks(to: "img.png").first?.kind, .embed)
        XCTAssertEqual(try index.outgoingLinks(from: "A.md").map(\.resolved), ["B.md", "Projects/C.md", "B.md", nil, "img.png"])
        XCTAssertEqual(try index.unresolvedTargets().map(\.target), ["Missing"])
        // Same-page links don't make a page need rewriting when it's renamed.
        XCTAssertEqual(try index.pagesLinking(to: "B.md"), ["A.md"])
    }

    func testANewPageThatTakesOverANameReResolvesLinks() throws {
        let index = try self.index(["Inbox.md": "[[Spec]]\n", "Archive/Spec.md": "old\n"])
        XCTAssertEqual(try index.backlinks(to: "Archive/Spec.md").count, 1)
        // A root-level Spec.md has fewer segments, so `[[Spec]]` now means it (SPEC §7).
        try index.upsertPage("Spec.md", source: "new\n")
        XCTAssertEqual(try index.backlinks(to: "Archive/Spec.md").count, 0)
        XCTAssertEqual(try index.backlinks(to: "Spec.md").map(\.source), ["Inbox.md"])
        try index.removePage("Spec.md")
        XCTAssertEqual(try index.backlinks(to: "Archive/Spec.md").map(\.source), ["Inbox.md"])
        // Removing a page removes everything it contributed, including after a snapshot round trip
        // (the cascade depends on a per-connection setting).
        let loaded = try VaultIndex(snapshot: index.snapshot(sealedWith: TestSealer.shared), sealedWith: TestSealer.shared)
        try loaded.removePage("Inbox.md")
        XCTAssertEqual(try loaded.backlinks(to: "Archive/Spec.md"), [])
        XCTAssertEqual(try loaded.outgoingLinks(from: "Inbox.md"), [])
        XCTAssertEqual(try loaded.scalarInt("SELECT count(*) FROM links"), 0)
    }

    /// The whole rename flow: find the linking pages, rewrite them (SPEC §7, §8.2), re-index.
    func testRenamingAPageEndToEnd() throws {
        var sources = [
            "Roadmap.md": "# Roadmap\n\nSee [[#Roadmap]].\n",
            "Inbox.md": "Plan in [[Roadmap|the roadmap]] and [here](Roadmap.md).\n",
            "Other.md": "Nothing to do with it.\n",
        ]
        let index = try self.index(sources)
        let before = LinkResolver(files: sources.keys)
        let after = LinkResolver(files: sources.keys.map { $0 == "Roadmap.md" ? "Plans/Roadmap 2027.md" : $0 })

        let toRewrite = try index.pagesLinking(to: "Roadmap.md")
        XCTAssertEqual(toRewrite, ["Inbox.md"])
        try index.renameFile(from: "Roadmap.md", to: "Plans/Roadmap 2027.md")
        sources["Plans/Roadmap 2027.md"] = sources.removeValue(forKey: "Roadmap.md")
        for page in toRewrite {
            var doc = MarkdownDocument(source: sources[page]!)
            XCTAssertTrue(doc.rewriteLinks(toRenamed: "Roadmap.md", as: "Plans/Roadmap 2027.md", linkingPage: page, before: before, after: after).inPlace)
            sources[page] = doc.serialized()
            try index.upsertPage(page, source: doc.serialized())
        }
        XCTAssertEqual(sources["Inbox.md"], "Plan in [[Roadmap 2027|the roadmap]] and [here](<Roadmap 2027.md>).\n")
        XCTAssertEqual(try index.backlinks(to: "Plans/Roadmap 2027.md").map(\.source), ["Inbox.md", "Inbox.md", "Plans/Roadmap 2027.md"])
        XCTAssertEqual(try index.unresolvedTargets().count, 0)
        XCTAssertEqual(try index.quickSwitch("roadmap 2027").first?.path, "Plans/Roadmap 2027.md")
    }

    // MARK: Tags and search

    func testTagsAreNestedCaseInsensitiveAndIncludeFrontmatter() throws {
        let index = try self.index([
            "A.md": "---\ntags: [project/atlas]\n---\n\nText #idea\n",
            "B.md": "#Project/atlas and #project\n",
            "C.md": "#idea #idea\n",
        ])
        // B writes `#Project/atlas` and `#project`: each group shows its (first) spelling.
        XCTAssertEqual(try index.tags().map(\.tag), ["idea", "project", "Project/atlas"])
        XCTAssertEqual(try index.tags().map(\.count), [2, 1, 2])
        XCTAssertEqual(try index.search("#project").map(\.path).sorted(), ["A.md", "B.md"])
        XCTAssertEqual(try index.search("tag:project/atlas").map(\.path).sorted(), ["A.md", "B.md"])
    }

    func testSearchSyntaxAndRanking() throws {
        let index = try self.index([
            "Planning.md": "Something else entirely.\n",
            "Notes/Café visit.md": "We planned the trip to the café near the station.\n",
            "Notes/Station.md": "The station plan was cancelled. #travel\n",
            "Recipes/Bread.md": "Knead the dough. Plan ahead.\n",
        ])
        // Prefix match; a title match ranks first.
        XCTAssertEqual(try index.search("plan").first?.path, "Planning.md")
        // Diacritics and case are ignored.
        XCTAssertEqual(try index.search("CAFE").map(\.path), ["Notes/Café visit.md"])
        // Phrases, exclusion, folders and tags.
        XCTAssertEqual(try index.search("\"station plan\"").map(\.path), ["Notes/Station.md"])
        XCTAssertEqual(try index.search("plan -dough").map(\.path).contains("Recipes/Bread.md"), false)
        XCTAssertEqual(try index.search("plan path:Recipes").map(\.path), ["Recipes/Bread.md"])
        XCTAssertEqual(try index.search("plan #travel").map(\.path), ["Notes/Station.md"])
        // FTS5 syntax in the query is just text.
        XCTAssertNoThrow(try index.search("\"unbalanced OR NEAR( * ^"))
        // Snippets mark the matched words.
        let hit = try XCTUnwrap(index.search("cancelled").first)
        XCTAssertEqual(hit.snippet.matches.map { String(hit.snippet.text[$0]) }, ["cancelled"])
    }

    func testUnlinkedMentions() throws {
        let index = try self.index([
            "Atlas Plan.md": "---\naliases: [The Map]\n---\n\nThe plan.\n",
            "Linked.md": "See [[Atlas Plan]]. The atlas plan is good.\n",
            "Unlinked.md": "We should revisit the atlas plan soon.\n",
            "Alias.md": "Bring the map.\n",
            "Unrelated.md": "Atlas and plan, but not together.\n",
        ])
        let mentions = try index.unlinkedMentions(of: "Atlas Plan.md")
        XCTAssertEqual(Set(mentions.map(\.source)), ["Unlinked.md", "Alias.md"])
        XCTAssertEqual(mentions.first { $0.source == "Alias.md" }?.name, "The Map")
    }

    func testQuickSwitcherOrdering() throws {
        let index = try self.index([
            "Plan.md": "", "Planning.md": "", "Project plan.md": "", "Pull later now.md": "",
            "Archive/Old plan.md": "---\naliases: [Legacy]\n---\n",
        ])
        // Exact, then prefix, then the rest by fzf-style score (shorter, tighter matches first).
        XCTAssertEqual(try index.quickSwitch("plan").map(\.path).prefix(4),
                       ["Plan.md", "Planning.md", "Archive/Old plan.md", "Project plan.md"])
        XCTAssertEqual(try index.quickSwitch("pln").first?.path, "Plan.md")
        XCTAssertEqual(try index.quickSwitch("legacy").first?.alias, "Legacy")
        XCTAssertEqual(try index.quickSwitch("archive/old").first?.path, "Archive/Old plan.md")
        XCTAssertEqual(try index.quickSwitch("zzz"), [])
    }

    func testHeadingsForCompletion() throws {
        let index = try self.index(["Plan.md": "# Plan\n\n## Goals\n\n> ### Goals!\n\n## Risks [open]\n\n## Next steps\n"])
        let headings = try index.headings(of: "Plan.md")
        XCTAssertEqual(headings.map(\.text), ["Plan", "Goals", "Goals!", "Risks [open]", "Next steps"])
        XCTAssertEqual(headings.map(\.depth), [1, 2, 3, 2, 2])
        XCTAssertEqual(try index.headings(of: "Missing.md"), [])

        XCTAssertEqual(VaultIndex.matchingHeadings(headings, "").map(\.text), ["Plan", "Goals", "Goals!", "Risks [open]", "Next steps"])
        XCTAssertEqual(VaultIndex.matchingHeadings(headings, "go").map(\.text), ["Goals", "Goals!"])
        XCTAssertEqual(VaultIndex.matchingHeadings(headings, "nst").map(\.text), ["Next steps"])
        XCTAssertEqual(VaultIndex.matchingHeadings(headings, "risks open").map(\.text), ["Risks [open]"], "matched as a link writes it")
        let twice = headings + [PageExtract.Heading(depth: 3, text: "goals")]
        XCTAssertEqual(VaultIndex.matchingHeadings(twice, "goals").map(\.text), ["Goals", "Goals!"], "a heading a link can't tell apart is offered once")
    }

    func testFuzzyMatchingRanksAnyList() {
        let commands = [("New Page", ["create"]), ("Sync Now", []), ("Add Page to Favourites", ["star", "bookmark"]), ("Today's Note", ["daily"])]
        func titles(_ q: String) -> [String] { VaultIndex.fuzzyMatching(commands, q) { [$0.0] + $0.1 }.map(\.0) }
        XCTAssertEqual(titles(""), commands.map(\.0))
        XCTAssertEqual(titles("sync"), ["Sync Now"])
        XCTAssertEqual(titles("star"), ["Add Page to Favourites"], "by a keyword")
        XCTAssertEqual(titles("page"), ["New Page", "Add Page to Favourites"], "the shorter title first")
        XCTAssertEqual(titles("TODAY"), ["Today's Note"])
        XCTAssertEqual(titles("np"), ["New Page"])
        XCTAssertEqual(titles("zzz"), [])
    }

    // MARK: Snapshots

    func testSealedSnapshotRoundTrip() throws {
        let sealer = TestSealer()
        let index = try self.index(["A.md": "[[B]] #tag searchable words\n", "Spec.md": ""], files: ["img.png"])
        let snapshot = try index.snapshot(sealedWith: sealer)
        // Nothing readable in it.
        XCTAssertNil(snapshot.range(of: Data("searchable".utf8)))
        XCTAssertNil(snapshot.range(of: Data("A.md".utf8)))

        let loaded = try VaultIndex(snapshot: snapshot, sealedWith: sealer)
        XCTAssertEqual(loaded.pageCount, 2)
        XCTAssertEqual(try loaded.search("searchable").map(\.path), ["A.md"])
        XCTAssertEqual(try loaded.tags().map(\.tag), ["tag"])
        // The file set came back too: adding B resolves A's link.
        try loaded.upsertPage("B.md", source: "")
        XCTAssertEqual(try loaded.backlinks(to: "B.md").map(\.source), ["A.md"])

        var tampered = snapshot
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try VaultIndex(snapshot: tampered, sealedWith: sealer))
        XCTAssertThrowsError(try VaultIndex(snapshot: snapshot, sealedWith: TestSealer()))
        var otherVersion = snapshot
        otherVersion[11] = 99
        XCTAssertThrowsError(try VaultIndex(snapshot: otherVersion, sealedWith: sealer)) { error in
            XCTAssertEqual(error as? VaultIndex.SnapshotError, .schemaVersion(found: 99, expected: VaultIndex.schemaVersion))
        }
        XCTAssertThrowsError(try VaultIndex(snapshot: Data("nope".utf8), sealedWith: sealer))
    }

    // MARK: Performance (roadmap Phase 1 exit criteria: open < 1 s, search < 100 ms at 5,000 pages)

    func testFiveThousandPages() throws {
        let words = ["atlas", "neutrino", "encryption", "graph", "backlink", "garden", "river", "station", "café",
                     "bread", "planning", "meeting", "quarter", "roadmap", "sync", "vault", "editor", "search"]
        var rng = SystemRandomNumberGenerator()
        func paragraph(_ n: Int) -> String { (0..<n).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }
        var pages: [String: String] = [:]
        for i in 0..<5_000 {
            let links = (0..<4).map { _ in "[[Page \(Int.random(in: 0..<5_000, using: &rng))]]" }.joined(separator: " ")
            pages["Folder \(i % 50)/Page \(i).md"] = "# Page \(i)\n\n\(paragraph(120)) \(links) #topic/\(i % 20)\n\n- [ ] \(paragraph(20))\n\n\(paragraph(150))\n"
        }

        var clock = ContinuousClock.now
        let index = try self.index(pages)
        let build = ContinuousClock.now - clock

        let sealer = TestSealer()
        clock = .now
        let snapshot = try index.snapshot(sealedWith: sealer)
        let save = ContinuousClock.now - clock
        clock = .now
        let loaded = try VaultIndex(snapshot: snapshot, sealedWith: sealer)
        let open = ContinuousClock.now - clock

        var searches: [Duration] = []
        for query in ["encryption roadmap", "\"river station\"", "plan #topic/3", "café", "backl"] {
            clock = .now
            _ = try loaded.search(query)
            searches.append(ContinuousClock.now - clock)
        }
        clock = .now
        _ = try loaded.quickSwitch("pg 42")
        let switcher = ContinuousClock.now - clock
        clock = .now
        _ = try loaded.backlinks(to: "Folder 0/Page 0.md")
        let backlinks = ContinuousClock.now - clock

        print("5,000 pages: build \(build), snapshot \(snapshot.count / 1_000_000) MB in \(save), open \(open), "
              + "search max \(searches.max()!), switcher \(switcher), backlinks \(backlinks)")
        XCTAssertEqual(loaded.pageCount, 5_000)
        // The roadmap's Phase 1 exit criteria. Debug builds on a CI runner meet them with room to spare.
        XCTAssertLessThan(open, .seconds(1))
        XCTAssertLessThan(searches.max()!, .milliseconds(100))
        XCTAssertLessThan(switcher, .milliseconds(100))
        XCTAssertLessThan(backlinks, .milliseconds(50))
    }
}

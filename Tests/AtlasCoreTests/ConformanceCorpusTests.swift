import Foundation
import XCTest
@testable import AtlasCore

/// Runs the Atlas Markdown conformance corpus (SPEC §9), vendored from
/// neutrino/specs/atlas-markdown/corpus by scripts/sync-atlas-markdown-corpus.sh.
///
/// There is no parser yet, so these tests cover the parts of the spec that don't need one:
/// - the tree model reads and writes every expected tree exactly;
/// - extraction (check E) runs on the expected trees;
/// - link resolution and link writing are checked against the vault fixture.
///
/// Checks P, R and C need the parser and serializer, and arrive with them.
final class ConformanceCorpusTests: XCTestCase {
    struct Manifest: Decodable {
        struct Case: Decodable { let id: String; let description: String }
        let specVersion: String
        let cases: [Case]
        let resolve: [String]
    }

    struct VaultFixture: Decodable {
        struct Resolve: Decodable { let from: String; let target: String; let expect: String?; let why: String }
        struct Write: Decodable { let file: String; let expect: String }
        let files: [String]
        let resolve: [Resolve]
        let write: [Write]
    }

    static let corpus: URL = {
        guard let url = Bundle.module.url(forResource: "atlas-markdown", withExtension: nil) else {
            fatalError("vendored corpus missing; run scripts/sync-atlas-markdown-corpus.sh")
        }
        return url
    }()

    func load<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: Self.corpus.appendingPathComponent(path)))
    }

    func manifest() throws -> Manifest { try load(Manifest.self, "manifest.json") }

    /// Runs one case, reporting a throw as that case's failure so the remaining cases still run.
    func checkCase(_ id: String, _ body: () throws -> Void) {
        do { try body() } catch { XCTFail("\(id): \(error)") }
    }

    func testCorpusMatchesTheImplementedSpecVersion() throws {
        XCTAssertEqual(try manifest().specVersion, AtlasMarkdown.specVersion,
                       "the vendored corpus is for a different spec version than AtlasCore implements")
    }

    /// Every expected tree decodes into `MarkdownNode` and encodes back to the identical JSON:
    /// same keys, explicit nulls included. That pins the model to SPEC §3–§4.
    func testTreeModelRoundTripsEveryExpectedTree() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let data = try Data(contentsOf: Self.corpus.appendingPathComponent("cases/\(c.id)/ast.json"))
                let node = try JSONDecoder().decode(MarkdownNode.self, from: data)
                let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
                let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as! NSDictionary
                XCTAssertEqual(reencoded, original, "\(c.id): ast.json does not survive a decode/encode round trip")
            }
        }
    }

    /// Check E, applied to the expected tree rather than a parsed one.
    func testExtractionMatchesEveryCase() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let tree = try load(MarkdownNode.self, "cases/\(c.id)/ast.json")
                let expected = try load(PageExtract.self, "cases/\(c.id)/extract.json")
                let actual = PageExtract(page: tree)
                XCTAssertEqual(actual.links, expected.links, "\(c.id): links")
                XCTAssertEqual(actual.embeds, expected.embeds, "\(c.id): embeds")
                XCTAssertEqual(actual.tags, expected.tags, "\(c.id): tags")
                XCTAssertEqual(actual.aliases, expected.aliases, "\(c.id): aliases")
                XCTAssertEqual(actual.headings, expected.headings, "\(c.id): headings")
                XCTAssertEqual(actual.blockIds, expected.blockIds, "\(c.id): blockIds")
            }
        }
    }

    func testLinkResolutionMatchesTheVaultFixtures() throws {
        for name in try manifest().resolve {
            let fixture = try load(VaultFixture.self, "resolve/\(name).json")
            let resolver = LinkResolver(files: fixture.files)
            for c in fixture.resolve {
                XCTAssertEqual(resolver.resolve(c.target, from: c.from), c.expect,
                               "\(name): \"\(c.target)\" from \(c.from) (\(c.why))")
            }
            for c in fixture.write {
                XCTAssertEqual(resolver.linkTarget(for: c.file), c.expect, "\(name): link written for \(c.file)")
            }
        }
    }

    /// A corpus with the wrong cases is worse than none, so prove the loader sees all of it.
    func testEveryListedCaseIsPresent() throws {
        let m = try manifest()
        XCTAssertFalse(m.cases.isEmpty)
        for c in m.cases {
            for file in ["input.md", "ast.json", "extract.json"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: Self.corpus.appendingPathComponent("cases/\(c.id)/\(file)").path),
                              "\(c.id) is missing \(file)")
            }
        }
    }
}

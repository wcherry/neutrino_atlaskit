import Foundation
import XCTest
@testable import AtlasCore

/// Runs the Atlas Markdown conformance corpus (SPEC §9), vendored from
/// neutrino/specs/atlas-markdown/corpus by scripts/sync-atlas-markdown-corpus.sh.
///
/// - **P**: parsing each `input.md` gives exactly `ast.json`.
/// - **R**: a document opened from `input.md` and saved without edits gives back its exact bytes.
/// - **C**: canonical serialization of `ast.json` gives `canonical.md` (or `input.md`), which
///   parses back to `ast.json`.
/// - **E**: extraction gives `extract.json`, both from the expected tree and from the parsed one.
/// - The tree model reads and writes every expected tree exactly.
/// - Link resolution and link writing match the vault fixture.
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

    /// Check P: parsing `input.md` gives exactly `ast.json`.
    func testParsingMatchesEveryCase() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let input = try String(contentsOf: Self.corpus.appendingPathComponent("cases/\(c.id)/input.md"), encoding: .utf8)
                let expected = try load(MarkdownNode.self, "cases/\(c.id)/ast.json")
                let actual = AtlasMarkdown.parse(input)
                if actual != expected {
                    XCTFail("\(c.id): parsed tree differs from ast.json\n\(Self.firstDifference(expected, actual))")
                }
            }
        }
    }

    /// Check R: open and save without edits, byte for byte. The document's blocks must also be
    /// the parsed tree, so preservation can't pass by ignoring the parser.
    func testRoundTripWithoutEditsMatchesEveryCase() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let input = try String(contentsOf: Self.corpus.appendingPathComponent("cases/\(c.id)/input.md"), encoding: .utf8)
                let document = MarkdownDocument(source: input)
                XCTAssertEqual(document.serialized(), input, "\(c.id): saving without edits changed the bytes")
                XCTAssertEqual(document.tree, try load(MarkdownNode.self, "cases/\(c.id)/ast.json"), "\(c.id): document tree")
            }
        }
    }

    /// Check C: canonical form, and that it parses back to the same tree.
    func testCanonicalSerializationMatchesEveryCase() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let dir = Self.corpus.appendingPathComponent("cases/\(c.id)")
                let canonicalURL = FileManager.default.fileExists(atPath: dir.appendingPathComponent("canonical.md").path)
                    ? dir.appendingPathComponent("canonical.md") : dir.appendingPathComponent("input.md")
                let expected = try String(contentsOf: canonicalURL, encoding: .utf8)
                let tree = try load(MarkdownNode.self, "cases/\(c.id)/ast.json")
                let written = AtlasMarkdown.serializeCanonical(tree)
                XCTAssertEqual(written, expected, "\(c.id): canonical form")
                XCTAssertEqual(AtlasMarkdown.parse(written), tree, "\(c.id): canonical form does not parse back to ast.json")
            }
        }
    }

    /// Check E on parsed input, which is how an app actually indexes a page.
    func testExtractionFromParsedInputMatchesEveryCase() throws {
        for c in try manifest().cases {
            checkCase(c.id) {
                let input = try String(contentsOf: Self.corpus.appendingPathComponent("cases/\(c.id)/input.md"), encoding: .utf8)
                let expected = try load(PageExtract.self, "cases/\(c.id)/extract.json")
                XCTAssertEqual(PageExtract(page: AtlasMarkdown.parse(input)), expected, "\(c.id): extract from parsed input")
            }
        }
    }

    /// The first line where two trees' pretty JSON differs, with a little context.
    static func firstDifference(_ expected: MarkdownNode, _ actual: MarkdownNode) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let e = String(decoding: try! encoder.encode(expected), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let a = String(decoding: try! encoder.encode(actual), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let i = (0..<min(e.count, a.count)).first(where: { e[$0] != a[$0] }) ?? min(e.count, a.count)
        let window = max(0, i - 4)..<i + 3
        return "expected:\n" + e[window.clamped(to: e.indices)].joined(separator: "\n")
            + "\nactual:\n" + a[window.clamped(to: a.indices)].joined(separator: "\n")
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

import XCTest
@testable import AtlasCore

/// Deterministic fuzzing of the parser, from the same character mix that found the crashes and
/// text losses fixed in `ParserRegressionTests`. Two properties:
/// - parsing never traps, whatever the input;
/// - every character from the parser's reserved ranges (U+E000–U+E0FF, U+2E3C–U+2E42) that the
///   input contains is still in the tree. That is where the parser's own markers live,
///   so this is where its bookkeeping could swallow or corrupt the user's text.
///
/// Inputs containing `]:` (reference definitions) or `|` (tables, which drop excess cells) are
/// skipped for the second property: there the spec itself takes text out of the tree.
final class ParserFuzzTests: XCTestCase {
    private static let pieces: [String] = Array("[[]]!#=^$|\\`*_~<>-+.:() \t\n").map(String.init) + [
        "a", "x", "1", "```", "``", "$$", "[!note]", "==", "#t", "<b>", "[^", "[^1]", "^[",
        "\u{E000}", "\u{E001}", "\u{E011}", "\u{E020}", "\u{E0FF}",
        "\u{2E3C}", "\u{2E3D}", "\u{2E3E}", "\u{2E3F}", "\u{2E40}", "\u{2E41}", "\u{2E42}",
    ]

    /// A small linear congruential generator, so the inputs are the same on every machine.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func allText(_ node: MarkdownNode) -> String {
        switch node {
        case .text(let v), .inlineCode(let v), .html(let v), .yaml(let v), .inlineMath(let v): return v
        case .code(let l, let m, let v, _): return (l ?? "") + (m ?? "") + v
        case .math(_, let v, _): return v
        case .link(let u, let t, let k): return u + (t ?? "") + k.map(allText).joined()
        case .image(let u, let t, let a): return u + (t ?? "") + a
        case .wikiLink(let r), .embed(let r): return r.target + (r.heading ?? "") + (r.blockId ?? "") + (r.alias ?? "")
        case .tag(let n): return n
        case .callout(let t, _, let title, _, let k): return t + (title ?? []).map(allText).joined() + k.map(allText).joined()
        case .footnoteReference(let i, let l): return i + (l ?? "")
        case .footnoteDefinition(let i, let l, let k): return i + (l ?? "") + k.map(allText).joined()
        default: return node.children.map(allText).joined()
        }
    }

    /// Two properties that must hold for every input, unlike canonical round-tripping, which
    /// a few pathological trees can't satisfy (SPEC §8.4):
    /// - saving a document without edits gives back its exact bytes (§8.1);
    /// - the serializer's `exact` flag is truthful: when it says exact, the text parses back
    ///   to the block, so an editor that trusts the flag never saves a silent change.
    func testSavingIsExactAndTheExactFlagIsTruthful() {
        var rng = Generator(state: 0x5A7E)
        let pieces = Self.pieces + ["www.x.com", "http://a.b", "- ", "1. ", "> ", "---", "| a |", "\n\n", "&amp;", "&#10;", "^id"]
        for _ in 0..<1500 {
            let source = (0..<rng.next(60)).map { _ in pieces[rng.next(pieces.count)] }.joined()
            let document = MarkdownDocument(source: source)
            XCTAssertEqual(document.serialized(), source, "saving without edits changed \(source.debugDescription)")
            var previousText: String? = nil
            for (i, block) in document.blocks.enumerated() {
                let (text, exact) = AtlasMarkdown.serializeBlock(block, after: i > 0 ? document.blocks[i - 1] : nil,
                                                                 previousText: previousText, atFileStart: i == 0)
                if exact, case .yaml = block {} else if exact {
                    var context = previousText.map { $0 + "\n\n" } ?? ""
                    let offset = previousText.map { AtlasMarkdown.parse($0 + "\n").children.count } ?? 0
                    context += text + "\n"
                    if case .footnoteDefinition = block { previousText = text; continue }
                    if Self.containsFootnoteReference(block) { previousText = text; continue }
                    let parsed = AtlasMarkdown.parse(context).children
                    XCTAssertTrue(offset < parsed.count && parsed[offset] == block,
                                  "exact claimed for \(text.debugDescription) from \(source.debugDescription)")
                }
                previousText = text
            }
        }
    }

    private static func containsFootnoteReference(_ node: MarkdownNode) -> Bool {
        if case .footnoteReference = node { return true }
        return node.children.contains(where: containsFootnoteReference)
    }

    func testParserNeverTrapsAndKeepsReservedCharacters() {
        var rng = Generator(state: 0xA71A5)
        for _ in 0..<5000 {
            let source = (0..<rng.next(80)).map { _ in Self.pieces[rng.next(Self.pieces.count)] }.joined()
            let text = allText(AtlasMarkdown.parse(source))
            guard !source.contains("]:"), !source.contains("|") else { continue }
            for scalar in source.unicodeScalars where SourcePreprocessor.isReserved(scalar) {
                let want = source.unicodeScalars.filter { $0 == scalar }.count
                let got = text.unicodeScalars.filter { $0 == scalar }.count
                if got < want {
                    XCTFail("lost U+\(String(scalar.value, radix: 16, uppercase: true)) from \(source.debugDescription)")
                    return
                }
            }
        }
    }
}

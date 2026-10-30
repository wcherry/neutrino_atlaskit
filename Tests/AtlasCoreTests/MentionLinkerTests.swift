import Foundation
import XCTest
@testable import AtlasCore

final class MentionLinkerTests: XCTestCase {
    private func link(_ source: String, _ name: String = "Plan", as target: String = "Plan") -> String? {
        AtlasMarkdown.linkingMentions(of: name, as: target, in: source)?.text
    }

    func testMentionsBecomeLinksKeepingTheirWords() {
        XCTAssertEqual(link("We went over the plan today. Plan B next.\n"),
                       "We went over the [[plan]] today. [[Plan]] B next.\n")
        XCTAssertEqual(AtlasMarkdown.linkingMentions(of: "Plan", as: "Plan", in: "plan and plan\n")?.linked, 2)
        XCTAssertEqual(link("- the plan\n> **plan** here\n# Plan\n"), "- the [[plan]]\n> **[[plan]]** here\n# [[Plan]]\n")
    }

    func testATargetThatIsntTheWordsKeepsThemAsTheAlias() {
        XCTAssertEqual(link("see the plan\n", as: "Projects/Plan"), "see the [[Projects/Plan|plan]]\n")
        XCTAssertEqual(link("a cafe nearby\n", "Café", as: "Café"), "a [[Café|cafe]] nearby\n")
    }

    func testOnlyPlainText() {
        XCTAssertNil(link("planning and planned\n"), "whole words only")
        XCTAssertNil(link("`plan` and $plan$ and [plan](u) and [[Plan]] and #plan\n"))
        XCTAssertNil(link("```\nplan\n```\n"))
        XCTAssertNil(link("---\ntitle: plan\n---\n"))
        XCTAssertNil(link("Pl**an** split by syntax\n"))
        XCTAssertNil(link("nothing here\n"))
        XCTAssertEqual(link("`plan` but also plan\n"), "`plan` but also [[plan]]\n")
    }

    func testANameWithSpaces() {
        XCTAssertEqual(link("the Q4 plan is due\n", "Q4 plan", as: "Q4 plan"), "the [[Q4 plan]] is due\n")
    }

    /// On random pages, a result is never wrong: it parses to the old tree plus new links only
    /// (`linkingMentions` checks this itself; here, that it never traps and the text only grows).
    func testRandomPages() {
        var state: UInt64 = 0x4E17
        func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) }
        let pieces = ["plan", "Plan", " ", "\n", "**", "_", "`", "[[", "]]", "[", "](u)", "#", "> ", "- ", "plans", "é", "|", "\\", "$", "---\n", "```\n", "==", "~"]
        for _ in 0..<3000 {
            let source = (0..<next(30)).map { _ in pieces[next(pieces.count)] }.joined()
            if let (text, count) = AtlasMarkdown.linkingMentions(of: "plan", as: "Plan", in: source) {
                XCTAssertGreaterThan(count, 0)
                XCTAssertGreaterThan(text.count, source.count)
            }
        }
    }
}

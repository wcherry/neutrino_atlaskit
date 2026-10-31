import AtlasCore
import XCTest
@testable import AtlasEditor

final class SlashCommandTests: XCTestCase {
    /// `‸` marks the cursor (tables use `|`).
    private func context(_ marked: String) -> SlashContext? {
        let cursor = (marked as NSString).range(of: "‸").location
        let text = marked.replacingOccurrences(of: "‸", with: "")
        return MarkdownEditing.slashContext(in: text, cursor: cursor, syntax: AtlasMarkdown.syntax(of: text))
    }

    /// Applies the command with this id where `‸` is, and returns the text with `‸` at the new cursor.
    private func apply(_ id: String, _ marked: String) -> String {
        let cursor = (marked as NSString).range(of: "‸").location
        let text = marked.replacingOccurrences(of: "‸", with: "")
        let context = MarkdownEditing.slashContext(in: text, cursor: cursor, syntax: AtlasMarkdown.syntax(of: text))!
        let command = SlashCommand.builtIn().first { $0.id == id }!
        let edit = MarkdownEditing.apply(command, in: context, text: text)
        return (edit.applied(to: text) as NSString).replacingCharacters(in: NSRange(location: edit.selection.lowerBound, length: 0), with: "‸")
    }

    func testTheMenuOpensAfterASlashAtALineStartOrAfterASpace() {
        XCTAssertEqual(context("/‸"), SlashContext(range: 0..<1, query: ""))
        XCTAssertEqual(context("Text /hea‸"), SlashContext(range: 5..<9, query: "hea"))
        XCTAssertEqual(context("- item\n  /ta‸"), SlashContext(range: 9..<12, query: "ta"))
        XCTAssertNil(context("and/or‸"), "not inside a word")
        XCTAssertNil(context("1/2‸"))
        XCTAssertNil(context("/two words‸"), "a space ends it")
        XCTAssertNil(context("`/code‸`"))
        XCTAssertNil(context("```\n/inside‸\n```\n"))
        XCTAssertNil(context("/" + String(repeating: "a", count: 31) + "‸"))
    }

    func testMatching() {
        let all = SlashCommand.builtIn()
        func ids(_ q: String) -> [String] { MarkdownEditing.slashCommands(all, matching: q).map(\.id) }
        XCTAssertEqual(ids("").count, all.count)
        XCTAssertEqual(ids("head"), ["h1", "h2", "h3"])
        XCTAssertEqual(ids("h2"), ["h2"])
        XCTAssertEqual(ids("todo"), ["task"])
        XCTAssertEqual(ids("li").first, "link", "a title prefix comes before a word or keyword match")
        XCTAssertTrue(ids("li").contains("bullet"), "Bulleted list has a word starting with it")
        XCTAssertEqual(ids("zzz"), [])
    }

    func testLineCommandsKeepTheLinesText() {
        XCTAssertEqual(apply("h1", "/h1‸"), "# ‸")
        XCTAssertEqual(apply("h2", "Plans /h2‸"), "## Plans‸")
        XCTAssertEqual(apply("h1", "## Plans /h1‸"), "# Plans‸", "replaces the heading marker")
        XCTAssertEqual(apply("task", "- milk /ta‸"), "- [ ] milk‸", "a list item becomes a task")
        XCTAssertEqual(apply("bullet", "  1. one /bu‸"), "  - one‸", "keeps the indentation")
        XCTAssertEqual(apply("quote", "Said /quo‸ it"), "> Said ‸ it")
        XCTAssertEqual(apply("number", "a\n/num‸\nb"), "a\n1. ‸\nb")
    }

    func testInsertCommands() {
        XCTAssertEqual(apply("code", "/code‸"), "```‸\n\n```")
        XCTAssertEqual(apply("code", "Para\n/code‸"), "Para\n\n```‸\n\n```", "a block gets a blank line after text")
        XCTAssertEqual(apply("divider", "Para /div‸"), "Para \n\n---‸", "never a setext underline")
        XCTAssertEqual(apply("divider", "/div‸ after"), "---‸\n\n after")
        XCTAssertEqual(apply("math", "  /math‸"), "$$\n‸\n$$", "an empty line's whitespace goes too")
        XCTAssertEqual(apply("table", "/tab‸"), "| Column | Column |\n| --- | --- |\n| ‸ |  |")
        XCTAssertEqual(apply("callout", "/call‸"), "> [!note]\n> ‸")
        XCTAssertEqual(apply("link", "See /link‸"), "See [[‸")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 5))!
        let commands = SlashCommand.builtIn(date: date, calendar: calendar)
        XCTAssertEqual(commands.first { $0.id == "date" }?.action, .insert("2026-10-30"))
        XCTAssertEqual(commands.first { $0.id == "time" }?.action, .insert("09:05"))
    }

    func testEveryBlockCommandMakesWhatItSays() {
        // Each block command, alone on a page, parses as the block it names.
        let expected: [String: (MarkdownNode) -> Bool] = [
            "code": { if case .code = $0 { return true } else { return false } },
            "math": { if case .math = $0 { return true } else { return false } },
            "table": { if case .table = $0 { return true } else { return false } },
            "divider": { if case .thematicBreak = $0 { return true } else { return false } },
            "callout": { if case .callout = $0 { return true } else { return false } },
        ]
        for (id, isIt) in expected {
            let text = apply(id, "Para\n/x‸").replacingOccurrences(of: "‸", with: "")
            let blocks = AtlasMarkdown.parse(text).children
            XCTAssertEqual(blocks.count, 2, id)
            XCTAssertTrue(blocks.last.map(isIt) ?? false, "\(id): \(text)")
        }
    }
}

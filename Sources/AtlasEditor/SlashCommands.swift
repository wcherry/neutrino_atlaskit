import AtlasCore
import Foundation

/// A command in the `/` menu (roadmap Phase 1, "a `/` command menu"). Typing `/` at the start
/// of a line or after a space opens it; the text typed after the `/` narrows it, and choosing a
/// command replaces the `/` and that text. Every command edits Markdown: what's saved is still
/// exactly what a person could have typed.
public struct SlashCommand: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        /// Makes the line a heading, list item, task or quote, keeping its text: the line's
        /// existing heading, list, task or quote marker is replaced.
        case linePrefix(String)
        /// Inserts `text` where the `/` was, with the cursor `cursor` UTF-16 units into it (at
        /// its end when nil). A block goes on a line of its own, after a blank line if the line
        /// before has text, so a `---` can't turn the paragraph above into a heading.
        case insert(String, cursor: Int? = nil, block: Bool = false)
    }

    public var id: String
    public var title: String
    /// Other words that find it, such as `h1` or `todo`.
    public var keywords: [String]
    public var action: Action

    public init(id: String, title: String, keywords: [String] = [], action: Action) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.action = action
    }

    /// The commands every editor has. `date` fills the date and time commands.
    public static func builtIn(date: Date = Date(), calendar: Calendar = .current) -> [SlashCommand] {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let table = "| Column | Column |\n| --- | --- |\n|  |  |"
        return [
            SlashCommand(id: "h1", title: "Heading 1", keywords: ["h1", "title"], action: .linePrefix("# ")),
            SlashCommand(id: "h2", title: "Heading 2", keywords: ["h2", "subtitle"], action: .linePrefix("## ")),
            SlashCommand(id: "h3", title: "Heading 3", keywords: ["h3"], action: .linePrefix("### ")),
            SlashCommand(id: "bullet", title: "Bulleted list", keywords: ["ul", "unordered"], action: .linePrefix("- ")),
            SlashCommand(id: "number", title: "Numbered list", keywords: ["ol", "ordered"], action: .linePrefix("1. ")),
            SlashCommand(id: "task", title: "Task", keywords: ["todo", "checkbox", "checklist"], action: .linePrefix("- [ ] ")),
            SlashCommand(id: "quote", title: "Quote", keywords: ["blockquote"], action: .linePrefix("> ")),
            SlashCommand(id: "callout", title: "Callout", keywords: ["note", "admonition", "info"], action: .insert("> [!note]\n> ", block: true)),
            SlashCommand(id: "code", title: "Code block", keywords: ["fence", "snippet"], action: .insert("```\n\n```", cursor: 3, block: true)),
            SlashCommand(id: "math", title: "Math block", keywords: ["latex", "equation", "formula"], action: .insert("$$\n\n$$", cursor: 3, block: true)),
            SlashCommand(id: "table", title: "Table", keywords: ["grid"], action: .insert(table, cursor: table.utf16.count - 5, block: true)),
            SlashCommand(id: "divider", title: "Divider", keywords: ["hr", "rule", "line", "separator"], action: .insert("---", block: true)),
            SlashCommand(id: "link", title: "Link to page", keywords: ["wiki", "page"], action: .insert("[[")),
            SlashCommand(id: "date", title: "Today's date", keywords: ["today", "now"], action: .insert(format("yyyy-MM-dd"))),
            SlashCommand(id: "time", title: "Current time", keywords: ["now", "clock"], action: .insert(format("HH:mm"))),
        ]
    }
}

/// The `/` being typed: its range, `/` included, and the text after it.
public struct SlashContext: Equatable, Sendable {
    public var range: Range<Int>
    public var query: String

    public init(range: Range<Int>, query: String) {
        self.range = range
        self.query = query
    }
}

extension MarkdownEditing {
    /// The `/` command being typed at `cursor`, if any: a `/` at the start of the line or after
    /// whitespace, followed by up to 30 characters with no whitespace or `/`. Not in code, math
    /// or frontmatter, so paths and dates (`and/or`, `1/2`) don't open the menu.
    public static func slashContext(in text: String, cursor: Int, syntax: PageSyntax) -> SlashContext? {
        let ns = text as NSString
        guard cursor <= ns.length, !isInCode(cursor, syntax), !isInVerbatimBlock(cursor, syntax) else { return nil }
        let line = lineContent(ns, at: cursor)
        let before = ns.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let slash = before.range(of: "/", options: .backwards) else { return nil }
        let query = String(before[slash.upperBound...])
        guard query.count <= 30, !query.contains(where: { $0.isWhitespace }) else { return nil }
        if slash.lowerBound > before.startIndex, !before[before.index(before: slash.lowerBound)].isWhitespace { return nil }
        let start = cursor - query.utf16.count - 1
        return SlashContext(range: start..<cursor, query: query)
    }

    /// The commands `query` finds: those whose title or a keyword starts with it, or whose title
    /// has a word starting with it, ignoring case. Titles that start with it come first; otherwise
    /// the given order is kept. All of them for an empty query.
    public static func slashCommands(_ commands: [SlashCommand], matching query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let found = commands.filter { c in
            c.title.lowercased().hasPrefix(q) || words(c.title).contains { $0.hasPrefix(q) } || c.keywords.contains { $0.lowercased().hasPrefix(q) }
        }
        return found.filter { $0.title.lowercased().hasPrefix(q) } + found.filter { !$0.title.lowercased().hasPrefix(q) }
    }

    /// Choosing `command`: the `/` and its query are removed and the command applied.
    public static func apply(_ command: SlashCommand, in context: SlashContext, text: String) -> TextEdit {
        let ns = text as NSString
        let line = lineContent(ns, at: context.range.lowerBound)
        let lineText = ns.substring(with: line)
        let slashAt = context.range.lowerBound - line.location
        // The line's text with the `/` command taken out, as UTF-16 offsets into `lineText`.
        let head = (lineText as NSString).substring(to: slashAt)
        let tail = (lineText as NSString).substring(from: slashAt + context.range.count)

        switch command.action {
        case .linePrefix(let prefix):
            let (indent, marker) = blockMarker(head)
            var body = (head as NSString).substring(from: indent.utf16.count + marker.utf16.count)
            let cursorInBody = body.utf16.count
            body += tail
            if tail.isEmpty { body = String(body.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }
            let newLine = indent + prefix + body
            let cursor = line.location + indent.utf16.count + prefix.utf16.count + min(cursorInBody, body.utf16.count)
            return TextEdit(range: line.location..<(line.location + line.length), replacement: newLine, selection: cursor..<cursor)

        case .insert(let inserted, let cursor, let block):
            var before = "", after = ""
            if block {
                if !head.trimmingCharacters(in: .whitespaces).isEmpty {
                    before = "\n\n"
                } else if line.location > 0 {
                    let previous = lineContent(ns, at: line.location - 1)
                    if !ns.substring(with: previous).trimmingCharacters(in: .whitespaces).isEmpty { before = "\n" }
                }
                if !tail.trimmingCharacters(in: .whitespaces).isEmpty { after = "\n\n" }
            }
            // A block on an otherwise empty line replaces the line's whitespace too.
            let range = block && head.trimmingCharacters(in: .whitespaces).isEmpty
                ? line.location..<context.range.upperBound : context.range
            let replacement = before + inserted + after
            let at = range.lowerBound + before.utf16.count + (cursor ?? inserted.utf16.count)
            return TextEdit(range: range, replacement: replacement, selection: at..<at)
        }
    }

    /// The indentation and heading, quote, list or task marker at the start of a line.
    private static func blockMarker(_ line: String) -> (indent: String, marker: String) {
        let ns = line as NSString
        let pattern = #"^([ \t]*)(#{1,6} |> ?|[-*+] \[[ xX]\] |[-*+] |\d{1,9}[.)] )?"#
        guard let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return ("", "") }
        let indent = ns.substring(with: m.range(at: 1))
        let marker = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        return (indent, marker)
    }
}

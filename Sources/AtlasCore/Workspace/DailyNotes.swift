import Foundation

/// Fills a page template's variables (roadmap Phase 1, "Organisation"):
/// - `{{title}}`: the new page's title;
/// - `{{date}}`: the date as `yyyy-MM-dd`;
/// - `{{time}}`: the time as `HH:mm`;
/// - `{{date:FORMAT}}`: the date in a Unicode date format, such as `{{date:EEEE d MMMM}}`.
///
/// Anything else between braces is left as written.
public enum PageTemplate {
    public static func render(_ template: String, title: String, date: Date,
                              calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        guard template.contains("{{") else { return template }
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.dateFormat = pattern
            return f.string(from: date)
        }
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { rest = rest[open.lowerBound...]; break }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            switch name {
            case "title": out += title
            case "date": out += format("yyyy-MM-dd")
            case "time": out += format("HH:mm")
            case _ where name.hasPrefix("date:") && name.count > 5: out += format(String(name.dropFirst(5)))
            default: out += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

/// Where daily notes go and what they start with. One note per day, named by its date, so every
/// device opens the same page for the same day.
///
/// Two devices that create the same day's note before syncing produce one file per device at
/// one path. Sync keeps a single page when their content is identical (`VaultSync` adopts it),
/// and a conflicted copy otherwise. So the default template is empty, and a template should
/// avoid what differs between devices, such as `{{time}}`.
public struct DailyNotes: Equatable, Sendable {
    /// The folder, relative to the vault; empty for the vault's root.
    public var folder: String
    /// The file name's date format (Unicode), without `.md`.
    public var format: String
    public var template: String

    public init(folder: String = "Daily", format: String = "yyyy-MM-dd", template: String = "") {
        self.folder = folder
        self.format = format
        self.template = template
    }

    private func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// The day's note: `folder/<date>.md`. A `/` the format produces is kept out of the name.
    public func path(for date: Date, calendar: Calendar = .current) -> String {
        let name = formatter(calendar).string(from: date).replacingOccurrences(of: "/", with: "-") + ".md"
        let folder = self.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return folder.isEmpty ? name : folder + "/" + name
    }

    /// The day a note is for, if `path` is a daily note.
    public func date(of path: String, calendar: Calendar = .current) -> Date? {
        let folder = self.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let prefix = folder.isEmpty ? "" : folder + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".md") else { return nil }
        let name = String(path.dropFirst(prefix.count).dropLast(3))
        guard !name.contains("/"), let date = formatter(calendar).date(from: name) else { return nil }
        return path == self.path(for: date, calendar: calendar) ? date : nil
    }
}

extension VaultWorkspace {
    /// The day's note, created from the template if there isn't one yet. Returns its path.
    @discardableResult
    public func dailyNote(for date: Date, settings: DailyNotes, calendar: Calendar = .current) throws -> String {
        let path = settings.path(for: date, calendar: calendar)
        if !contains(path) {
            let text = PageTemplate.render(settings.template, title: VaultWorkspace.title(of: path), date: date, calendar: calendar)
            try write(text: text, at: path)
        }
        return path
    }
}

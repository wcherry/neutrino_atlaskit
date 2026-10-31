import Foundation
import XCTest
@testable import AtlasCore

@MainActor
final class DailyNotesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 5))! }

    func testTemplates() {
        func render(_ t: String) -> String { PageTemplate.render(t, title: "Standup", date: day, calendar: calendar) }
        XCTAssertEqual(render("# {{title}}\n\n{{date}} {{time}}\n"), "# Standup\n\n2026-10-30 09:05\n")
        XCTAssertEqual(render("{{date:EEEE d MMMM yyyy}}"), "Friday 30 October 2026")
        XCTAssertEqual(render("{{ title }} {{unknown}} {{date:}} {{open"), "Standup {{unknown}} {{date:}} {{open")
        XCTAssertEqual(render("no variables"), "no variables")
    }

    func testPathsAndDates() {
        let notes = DailyNotes()
        XCTAssertEqual(notes.path(for: day, calendar: calendar), "Daily/2026-10-30.md")
        XCTAssertEqual(notes.date(of: "Daily/2026-10-30.md", calendar: calendar).map { calendar.component(.day, from: $0) }, 30)
        XCTAssertNil(notes.date(of: "Daily/Notes.md", calendar: calendar))
        XCTAssertNil(notes.date(of: "Other/2026-10-30.md", calendar: calendar))
        XCTAssertEqual(DailyNotes(folder: "", format: "dd/MM/yyyy").path(for: day, calendar: calendar), "30-10-2026.md")
        XCTAssertEqual(DailyNotes(folder: "/Journal/").path(for: day, calendar: calendar), "Journal/2026-10-30.md")
    }

    func testTheDailyNoteIsCreatedOnceFromTheTemplate() throws {
        let w = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        let settings = DailyNotes(template: "# {{date:d MMMM}}\n\n")
        let path = try w.dailyNote(for: day, settings: settings, calendar: calendar)
        XCTAssertEqual(path, "Daily/2026-10-30.md")
        XCTAssertEqual(try w.text(at: path), "# 30 October\n\n")
        try w.write(text: "# 30 October\n\nWritten.\n", at: path)
        XCTAssertEqual(try w.dailyNote(for: day, settings: settings, calendar: calendar), path)
        XCTAssertEqual(try w.text(at: path), "# 30 October\n\nWritten.\n", "opening it again doesn't reset it")
    }

    func testPageTemplates() throws {
        let w = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: FakeDrive())
        XCTAssertEqual(w.templates().map(\.name), ["Meeting"], "the built-ins, in an empty vault")

        try w.write(text: "# {{title}}\n\nRead on {{date}}.\n", at: "Templates/Book.md")
        try w.write(text: "# Our meeting: {{title}}\n", at: "Templates/meeting.md")
        try w.write(text: "nested", at: "Templates/Old/Book.md")
        try w.write(text: "not a template", at: "Notes/Book.md")
        try w.write(Data([1]), at: "Templates/cover.png")
        let templates = w.templates()
        XCTAssertEqual(templates, [Template(name: "Book", source: .page("Templates/Book.md")),
                                   Template(name: "meeting", source: .page("Templates/meeting.md"))],
                       "pages replace a built-in of the same name; the shallowest wins; attachments aren't templates")
        XCTAssertEqual(w.templates(in: "Nowhere").map(\.name), ["Meeting"])

        let first = try w.createPage(from: templates[0], titled: "Dune", in: "Reading", date: day, calendar: calendar)
        XCTAssertEqual(first, "Reading/Dune.md")
        XCTAssertEqual(try w.text(at: first), "# Dune\n\nRead on 2026-10-30.\n")
        let second = try w.createPage(from: templates[0], titled: "Dune", in: "Reading", date: day, calendar: calendar)
        XCTAssertEqual(try w.text(at: second), "# Dune 2\n\nRead on 2026-10-30.\n", "{{title}} is the title the page gets")

        let meeting = try w.createPage(from: Template.builtIn[0], titled: "Standup", date: day, calendar: calendar)
        XCTAssertEqual(try w.text(at: meeting), "# Standup\n\nFriday 30 October 2026 · Attendees: \n\n## Agenda\n\n- \n\n## Notes\n\n## Action items\n\n- [ ] \n")
        let tasks = AtlasMarkdown.syntax(of: try w.text(at: meeting)!).spans.filter { if case .syntax(.taskMarker) = $0.kind { return true } else { return false } }
        XCTAssertEqual(tasks.count, 1, "the action item is a task")
    }

    /// Two devices create the same day's note before either syncs: identical content is one page.
    func testTwoDevicesCreatingTheSameDayKeepOnePage() async throws {
        let drive = FakeDrive()
        let a = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: drive)
        let b = try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: drive)
        try a.dailyNote(for: day, settings: DailyNotes(), calendar: calendar)
        try b.dailyNote(for: day, settings: DailyNotes(), calendar: calendar)
        try await a.sync()
        try await b.sync()
        try await a.sync()
        XCTAssertEqual(a.paths, ["Daily/2026-10-30.md"])
        XCTAssertEqual(b.paths, ["Daily/2026-10-30.md"])
        XCTAssertEqual(drive.snapshot.count, 1)
    }
}

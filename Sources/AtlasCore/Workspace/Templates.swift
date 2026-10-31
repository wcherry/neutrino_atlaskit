import Foundation

/// A page template (roadmap Phase 1, "Organisation"): a page in the vault's templates folder, or
/// one built in. Creating a page from it fills its variables with `PageTemplate.render`.
public struct Template: Equatable, Hashable, Sendable {
    public enum Source: Equatable, Hashable, Sendable {
        /// A page in the templates folder, at this path.
        case page(String)
        /// Built into Atlas, with this text.
        case builtIn(String)
    }

    public var name: String
    public var source: Source

    public init(name: String, source: Source) {
        self.name = name
        self.source = source
    }

    /// Templates every vault has. A page in the templates folder with the same name replaces one.
    public static let builtIn: [Template] = [
        Template(name: "Meeting", source: .builtIn(
            "# {{title}}\n\n{{date:EEEE d MMMM yyyy}} · Attendees: \n\n## Agenda\n\n- \n\n## Notes\n\n## Action items\n\n- [ ] \n")),
    ]
}

extension VaultWorkspace {
    /// The templates to offer: the pages in `folder` and its subfolders (named by title; the
    /// shallowest wins a clash), then the built-ins they don't replace, all by name.
    public func templates(in folder: String = "Templates") -> [Template] {
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var byName: [String: Template] = [:]
        for path in paths where Self.isPage(path) && !prefix.isEmpty && path.hasPrefix(prefix + "/") {
            let name = Self.title(of: path), key = AtlasMarkdown.matchKey(name)
            if case .page(let other)? = byName[key]?.source, other.split(separator: "/").count <= path.split(separator: "/").count { continue }
            byName[key] = Template(name: name, source: .page(path))
        }
        for template in Template.builtIn where byName[AtlasMarkdown.matchKey(template.name)] == nil {
            byName[AtlasMarkdown.matchKey(template.name)] = template
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new page titled `title` in `folder`, from `template` with its variables filled in
    /// (`{{title}}` is the title the page gets, numbered if it was taken). Returns its path.
    @discardableResult
    public func createPage(from template: Template, titled title: String, in folder: String = "", date: Date = Date(),
                           calendar: Calendar = .current) throws -> String {
        let text: String
        switch template.source {
        case .builtIn(let t): text = t
        case .page(let path): text = try self.text(at: path) ?? ""
        }
        let path = freePagePath(titled: title, in: folder)
        try write(text: PageTemplate.render(text, title: Self.title(of: path), date: date, calendar: calendar), at: path)
        return path
    }
}

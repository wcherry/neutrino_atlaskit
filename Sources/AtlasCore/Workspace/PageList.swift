import Foundation

/// An ordered list of pages, by path: favourites, and the recently opened pages (roadmap
/// Phase 1, "Favourites / pinned pages; recently opened"). The app keeps one of each per vault on
/// the device, as paths only; paths are file names, which the server already sees.
public struct PageList: Equatable, Codable, Sendable {
    public private(set) var paths: [String]
    /// The most it keeps: opening a page past it drops the oldest. Nil keeps every page.
    public var limit: Int?

    public init(_ paths: [String] = [], limit: Int? = nil) {
        var seen = Set<String>()
        self.paths = paths.filter { seen.insert($0).inserted }
        self.limit = limit
        trim()
    }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Puts `path` first, as the page opened last.
    public mutating func moveToFront(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        trim()
    }

    /// Adds `path` at the end, unless it's already there.
    public mutating func add(_ path: String) {
        guard !contains(path) else { return }
        paths.append(path)
        trim()
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Adds `path`, or removes it when it's there.
    public mutating func toggle(_ path: String) {
        if contains(path) { remove(path) } else { add(path) }
    }

    /// After the vault changes: follows pages that moved (`moved` maps old path to new), and drops
    /// the pages `exists` says are gone, keeping the order.
    public mutating func update(moved: [String: String], exists: (String) -> Bool) {
        var seen = Set<String>()
        paths = paths.map { moved[$0] ?? $0 }.filter { exists($0) && seen.insert($0).inserted }
    }

    private mutating func trim() {
        if let limit, paths.count > limit { paths.removeLast(paths.count - limit) }
    }
}

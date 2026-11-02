import Foundation

extension VaultWorkspace {
    /// Moves every file in folder `old` (pages and attachments, at any depth) to folder `new`,
    /// rewriting the links to each as a rename does. `new` may be a rename (`Work` → `Archive`)
    /// or a move (`Work` → `Archive/Work`). Nothing moves if any file would land on one that's
    /// already there, or if `new` is inside `old`. Returns how many pages had links rewritten.
    @discardableResult
    public func moveFolder(from old: String, to new: String) async throws -> Int {
        let old = Self.trimmedFolder(old), new = Self.trimmedFolder(new)
        guard !old.isEmpty, old != new else { return 0 }
        guard !(new + "/").hasPrefix(old + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        let moving = paths.filter { $0.hasPrefix(old + "/") }
        let moves = moving.map { ($0, Self.join(new, String($0.dropFirst(old.count + 1)))) }
        guard !moves.contains(where: { contains($0.1) }) else { throw CocoaError(.fileWriteFileExists) }
        var rewritten = 0
        for (from, to) in moves { rewritten += try await move(from: from, to: to) }
        return rewritten
    }

    /// Where a file dropped on `folder` goes: the same name, in that folder (`""` is the vault's root).
    public static func path(of file: String, movedInto folder: String) -> String {
        join(trimmedFolder(folder), (file as NSString).lastPathComponent)
    }

    /// Where a folder dropped on `folder` goes: the same name, in that folder.
    public static func folder(_ moving: String, movedInto folder: String) -> String {
        join(trimmedFolder(folder), (trimmedFolder(moving) as NSString).lastPathComponent)
    }

    nonisolated static func trimmedFolder(_ folder: String) -> String {
        folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}

import Foundation

extension VaultWorkspace {
    /// Saves `data` as a file named `name` in `folder`, numbered if the name is taken
    /// (`photo 2.png`), and returns its path. Like any write, sync encrypts and uploads it.
    @discardableResult
    public func addAttachment(_ data: Data, named name: String, in folder: String) throws -> String {
        var clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        // Not hidden: a leading `.` would keep it out of an export and an Obsidian vault.
        while clean.hasPrefix(".") { clean.removeFirst() }
        let ext = (clean as NSString).pathExtension
        var base = (clean as NSString).deletingPathExtension
        if base.isEmpty { base = "Attachment" }
        func named(_ stem: String) -> String { Self.join(folder, ext.isEmpty ? stem : stem + "." + ext) }
        var path = named(base)
        var n = 2
        while contains(path) { path = named("\(base) \(n)"); n += 1 }
        try write(data, at: path)
        return path
    }

    /// The name for an image pasted without one, as Obsidian names them:
    /// `Pasted image 20261102111900.png`.
    public static func pastedImageName(extension ext: String, date: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(f.string(from: date)).\(ext)"
    }
}

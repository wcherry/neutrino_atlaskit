import Foundation
import os

/// Where AtlasKit and the Atlas apps log. Each entry goes to Apple's unified log (subsystem
/// `com.neutrino.atlas`, for Console) and to a buffer of this run's last 5,000 entries, which
/// the Mac app's Help › Show Logs reads: the unified log takes seconds to read back. The buffer is
/// memory only. Never log page content: only paths (file names, which Drive has in plaintext
/// anyway), ids, counts, sizes, statuses and errors.
public enum AtlasLog {
    public static let subsystem = "com.neutrino.atlas"
    public static let app = Channel("app")
    public static let sync = Channel("sync")
    public static let drive = Channel("drive")
    public static let editor = Channel("editor")
    public static let images = Channel("images")

    public enum Level: String, Sendable, Comparable {
        case info, notice, error

        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        private var rank: Int { self == .info ? 0 : self == .notice ? 1 : 2 }
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        /// In order of logging, from the start of the run.
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    /// One category of entries.
    public struct Channel: Sendable {
        public let category: String
        private let logger: Logger

        init(_ category: String) {
            self.category = category
            logger = Logger(subsystem: AtlasLog.subsystem, category: category)
        }

        /// What happened, for following a problem through.
        public func info(_ message: String) { log(.info, message) }
        /// Something unexpected that Atlas carried on from.
        public func notice(_ message: String) { log(.notice, message) }
        /// Something that failed.
        public func error(_ message: String) { log(.error, message) }

        private func log(_ level: Level, _ message: String) {
            switch level {
            case .info: logger.info("\(message)")
            case .notice: logger.notice("\(message)")
            case .error: logger.error("\(message)")
            }
            buffer.append(level, category, message)
        }
    }

    /// This run's entries, oldest first, after `id` when given.
    public static func entries(after id: Int? = nil) -> [Entry] { buffer.entries(after: id) }

    static let limit = 5_000
    private static let buffer = Buffer()

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [Entry] = []
        private var next = 0

        func append(_ level: Level, _ category: String, _ message: String) {
            lock.lock()
            defer { lock.unlock() }
            kept.append(Entry(id: next, date: Date(), level: level, category: category, message: message))
            next += 1
            if kept.count > AtlasLog.limit { kept.removeFirst(kept.count - AtlasLog.limit) }
        }

        func entries(after id: Int?) -> [Entry] {
            lock.lock()
            defer { lock.unlock() }
            guard let id else { return kept }
            return Array(kept.drop { $0.id <= id })
        }
    }
}

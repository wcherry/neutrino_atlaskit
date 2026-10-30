import Foundation
import SQLite3

/// A thin wrapper over the system SQLite, just enough for the vault index.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    /// A fresh in-memory database.
    init() throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Failure(code: rc, message: "could not open an in-memory database")
        }
        handle = db
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw Failure(code: rc, message: message)
        }
    }

    /// Runs `sql` with `bindings`, calling `row` for each result row. Statements are cached.
    @discardableResult
    func query(_ sql: String, _ bindings: [Value] = [], row: ((Row) throws -> Void)? = nil) throws -> Int {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        for (i, value) in bindings.enumerated() { try bind(value, at: Int32(i + 1), in: statement) }
        var count = 0
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw failure(rc) }
            count += 1
            try row?(Row(statement: statement))
        }
        return count
    }

    var lastInsertedRow: Int64 { sqlite3_last_insert_rowid(handle) }

    /// A savepoint, so transactions nest (a page update inside a batch).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT tx")
        do {
            let result = try body()
            try execute("RELEASE tx")
            return result
        } catch {
            try? execute("ROLLBACK TO tx")
            try? execute("RELEASE tx")
            throw error
        }
    }

    // MARK: Snapshots

    /// The whole database as bytes (`sqlite3_serialize`).
    func serialized() throws -> Data {
        var size: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(handle, "main", &size, 0) else { throw Failure(code: SQLITE_NOMEM, message: "serialize failed") }
        defer { sqlite3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    /// Replaces this database's contents with `data`, as produced by `serialized()`.
    func load(_ data: Data) throws {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements = [:]
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(data.count)) else { throw Failure(code: SQLITE_NOMEM, message: "out of memory") }
        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                     sqlite3_int64(data.count), sqlite3_int64(data.count), flags)
        guard rc == SQLITE_OK else { throw failure(rc) }
    }

    // MARK: -

    enum Value {
        case int(Int64), double(Double), text(String), null
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(statement, i) else { return nil }
            return String(cString: p)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw failure(rc) }
        statements[sql] = statement
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: Value, at i: Int32, in statement: OpaquePointer) throws {
        let rc: Int32
        switch value {
        case .int(let v): rc = sqlite3_bind_int64(statement, i, v)
        case .double(let v): rc = sqlite3_bind_double(statement, i, v)
        case .text(let v): rc = sqlite3_bind_text(statement, i, v, -1, Self.transient)
        case .null: rc = sqlite3_bind_null(statement, i)
        }
        guard rc == SQLITE_OK else { throw failure(rc) }
    }

    private func failure(_ rc: Int32) -> Failure {
        Failure(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

import Foundation
import SQLite3

/// A value SQLite stores.
public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

public protocol SQLBindable: Sendable { var sqlValue: SQLValue { get } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row, read by column name.
public struct SQLRow: Sendable {
    let values: [String: SQLValue]
    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }
    public func string(_ column: String) -> String? {
        switch self[column] {
        case .text(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        default: nil
        }
    }
    public func int(_ column: String) -> Int? {
        switch self[column] {
        case .int(let i): Int(i)
        case .double(let d): Int(d)
        case .text(let s): Int(s)
        default: nil
        }
    }
    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

/// A SQLite database on one serial actor, in WAL mode. Migrations are plain
/// SQL, applied in order and counted with `PRAGMA user_version`; append a
/// new one, never edit an old one.
public actor SQLiteDatabase {
    private var handle: OpaquePointer?
    public let url: URL

    public init(url: URL, migrations: [String]) throws {
        self.url = url
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw LowtideError.invalid("Database: \(message)")
        }
        handle = db
        try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;")
        try Self.migrate(db, migrations)
    }

    isolated deinit { sqlite3_close_v2(handle) }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQL error"
            sqlite3_free(error)
            throw LowtideError.invalid("Database: \(message)")
        }
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func migrate(_ db: OpaquePointer?, _ migrations: [String]) throws {
        let version = scalar(db, "PRAGMA user_version")
        for (index, sql) in migrations.enumerated() where index + 1 > version {
            try exec(db, "BEGIN; \(sql); PRAGMA user_version=\(index + 1); COMMIT;")
        }
    }

    @discardableResult
    public func execute(_ sql: String, _ bindings: [any SQLBindable] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ bindings: [any SQLBindable] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLRow] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError() }
            var values: [String: SQLValue] = [:]
            for column in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, column))
                values[name] = switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    .blob(Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))))
                default: .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    /// Runs `body` in one transaction; rolls back if it throws.
    public func transaction<T: Sendable>(_ body: (isolated SQLiteDatabase) throws -> T) throws -> T {
        try Self.exec(handle, "BEGIN IMMEDIATE")
        do {
            let value = try body(self)
            try Self.exec(handle, "COMMIT")
            return value
        } catch {
            try? Self.exec(handle, "ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [any SQLBindable]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding.sqlValue {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .blob(let value):
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
            }
        }
        return statement
    }

    private func lastError() -> LowtideError {
        .invalid("Database: \(String(cString: sqlite3_errmsg(handle)))")
    }
}

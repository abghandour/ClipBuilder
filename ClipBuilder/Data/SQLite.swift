import Foundation
import SQLite3

/// Minimal SQLite3 wrapper. Not thread-safe on its own — always used from
/// inside the `Database` actor, which serializes access per profile.
nonisolated enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var description: String {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .prepare(let m, let sql): return "SQLite prepare failed: \(m) — \(sql)"
        case .step(let m, let sql): return "SQLite step failed: \(m) — \(sql)"
        }
    }
}

nonisolated enum SQLValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    var intValue: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        default: return nil
        }
    }

    var boolValue: Bool { (intValue ?? 0) != 0 }
}

typealias SQLRow = [String: SQLValue]

private nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = db
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .integer(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case .blob(let v):
                v.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(stmt, idx, bytes.baseAddress, Int32(v.count), sqliteTransient)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    /// Run a statement that returns no rows.
    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(errorMessage, sql: sql)
        }
    }

    /// Run several `;`-separated statements (schema creation).
    func executeScript(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.step(errorMessage, sql: sql)
            }
            var row: SQLRow = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, col))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, col)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, col) {
                        row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, col))))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// True if `SELECT <column> FROM <table> LIMIT 0` compiles — the same
    /// probe the Python app uses to detect missing columns before ALTER.
    func hasColumn(_ column: String, table: String) -> Bool {
        (try? execute("SELECT \(column) FROM \(table) LIMIT 0")) != nil
    }
}

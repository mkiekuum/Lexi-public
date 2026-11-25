import Foundation
import CSQLite

public enum SQLValue: Equatable {
    case null, integer(Int64), real(Double), text(String)
    public var string: String? {
        switch self { case .text(let x): return x; case .integer(let x): return String(x); case .real(let x): return String(x); case .null: return nil }
    }
    public var double: Double? {
        switch self { case .integer(let x): return Double(x); case .real(let x): return x; case .text(let x): return Double(x); case .null: return nil }
    }
}

public final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    public init(path: String, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let h = handle { sqlite3_close(h) }; handle = nil
            throw LexiError.database(message)
        }
        sqlite3_busy_timeout(handle, 8000)
        if !readOnly {
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
        }
    }
    deinit { if let h = handle { sqlite3_close(h) } }
    public func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error() }
    }
    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String: SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            var row: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT:
                    if let ptr = sqlite3_column_text(statement, i) {
                        row[name] = .text(String(cString: ptr))
                    } else { row[name] = .null }
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
    public func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> SQLValue {
        (try query(sql, values).first?.values.first) ?? .null
    }
    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let st = statement else {
            throw error()
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(st, index)
                case .integer(let v): code = sqlite3_bind_int64(st, index, v)
                case .real(let v): code = sqlite3_bind_double(st, index, v)
                case .text(let v):
                    code = v.withCString { sqlite3_bind_text(st, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                }
                if code != SQLITE_OK { throw error() }
            }
        } catch { sqlite3_finalize(st); throw error }
        return st
    }
    private func error() -> LexiError { .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection missing") }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let nesting = transactionDepth
        let savepoint = "lexi_nested_\(nesting)"
        try execute(nesting == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute(nesting == 0 ? "COMMIT" : "RELEASE SAVEPOINT \(savepoint)")
            return result
        } catch {
            if nesting == 0 { try? execute("ROLLBACK") }
            else {
                try? execute("ROLLBACK TO SAVEPOINT \(savepoint)")
                try? execute("RELEASE SAVEPOINT \(savepoint)")
            }
            throw error
        }
    }
    public func backup(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let src = handle else { throw LexiError.database("Database is closed") }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let dst = destination else {
            if let d = destination { sqlite3_close(d) }
            throw LexiError.database("Could not open backup database")
        }
        defer { sqlite3_close(dst) }
        sqlite3_busy_timeout(dst, 8000)
        guard let task = sqlite3_backup_init(dst, "main", src, "main") else { throw LexiError.database("Could not create backup") }
        var result: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(30)
        repeat {
            result = sqlite3_backup_step(task, 128)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                guard Date() < deadline else { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let closeResult = sqlite3_backup_finish(task)
        guard result == SQLITE_DONE && closeResult == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(dst))
            let sourcePath = sqlite3_db_filename(src, "main")
                .map { String(cString: $0) } ?? "unknown"
            throw LexiError.database("Backup failed (step \(result), finish \(closeResult)): \(detail); source=\(sourcePath), destination=\(url.path)")
        }
        let journalResult = sqlite3_exec(dst, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        guard journalResult == SQLITE_OK else {
            throw LexiError.database("Backup could not be finalized as a standalone SQLite file: \(String(cString: sqlite3_errmsg(dst)))")
        }
    }
}

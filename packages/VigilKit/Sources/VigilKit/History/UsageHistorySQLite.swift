import Foundation
import SQLite3

struct UsageHistorySQLiteFailure: Error {
    let code: Int32
    let extendedCode: Int32
    let message: String
    let sql: String?

    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

/// One short-lived, fully serialized SQLite connection. The store still uses
/// its external history flock for cross-process migration and destructive
/// deletion, while SQLite supplies transactional durability within the DB.
final class UsageHistorySQLiteConnection {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not allocate a database handle."
            let extended = opened.map(sqlite3_extended_errcode) ?? result
            if let opened { sqlite3_close_v2(opened) }
            throw UsageHistorySQLiteFailure(
                code: result,
                extendedCode: extended,
                message: message,
                sql: nil
            )
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)

        do {
            guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
                throw failure(sql: "busy_timeout")
            }
            try execute("PRAGMA busy_timeout=5000")
            let journalMode = try scalarText("PRAGMA journal_mode=WAL")
            guard journalMode?.lowercased() == "wal" else {
                throw UsageHistorySQLiteFailure(
                    code: SQLITE_CANTOPEN,
                    extendedCode: SQLITE_CANTOPEN,
                    message: "SQLite could not enable WAL journaling.",
                    sql: "PRAGMA journal_mode=WAL"
                )
            }
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA trusted_schema=OFF")
            try createSchema()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        _ = sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw UsageHistorySQLiteFailure(
                code: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE,
                message: "The SQLite connection is closed.",
                sql: sql
            )
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw UsageHistorySQLiteFailure(
                code: result,
                extendedCode: sqlite3_extended_errcode(handle),
                message: message,
                sql: sql
            )
        }
    }

    func prepare(_ sql: String) throws -> UsageHistorySQLiteStatement {
        guard let handle else {
            throw UsageHistorySQLiteFailure(
                code: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE,
                message: "The SQLite connection is closed.",
                sql: sql
            )
        }
        return try UsageHistorySQLiteStatement(database: handle, sql: sql)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT TRANSACTION")
            return value
        } catch {
            try? execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    private func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.text(at: 0)
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_samples (
                id TEXT PRIMARY KEY NOT NULL,
                account_key TEXT NOT NULL,
                source TEXT NOT NULL CHECK(source IN ('observed', 'providerBackfill')),
                recorded_ms REAL NOT NULL,
                effective_end_ms REAL NOT NULL,
                retrieved_ms REAL NOT NULL,
                payload_digest BLOB NOT NULL,
                payload BLOB NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_account_recorded_idx
            ON history_samples(account_key, recorded_ms, retrieved_ms, id)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_account_source_recorded_idx
            ON history_samples(account_key, source, recorded_ms, retrieved_ms, id)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_exact_payload_idx
            ON history_samples(account_key, recorded_ms, payload_digest)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_effective_end_idx
            ON history_samples(effective_end_ms)
            """
        )
        try execute("PRAGMA user_version=1")
    }

    private func failure(sql: String?) -> UsageHistorySQLiteFailure {
        guard let handle else {
            return UsageHistorySQLiteFailure(
                code: SQLITE_MISUSE,
                extendedCode: SQLITE_MISUSE,
                message: "The SQLite connection is closed.",
                sql: sql
            )
        }
        return UsageHistorySQLiteFailure(
            code: sqlite3_errcode(handle),
            extendedCode: sqlite3_extended_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle)),
            sql: sql
        )
    }
}

final class UsageHistorySQLiteStatement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?
    let sql: String

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        self.sql = sql
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            if let prepared { sqlite3_finalize(prepared) }
            throw UsageHistorySQLiteFailure(
                code: result,
                extendedCode: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database)),
                sql: sql
            )
        }
        statement = prepared
    }

    deinit {
        if let statement { sqlite3_finalize(statement) }
    }

    func bind(_ value: String, at index: Int32) throws {
        try check(
            sqlite3_bind_text(statement, index, value, -1, transientDestructor()),
            operation: "bind text"
        )
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value), operation: "bind number")
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value), operation: "bind integer")
    }

    func bind(_ value: Data, at index: Int32) throws {
        guard value.count <= Int(Int32.max) else {
            throw UsageHistorySQLiteFailure(
                code: SQLITE_TOOBIG,
                extendedCode: SQLITE_TOOBIG,
                message: "A history payload is too large for SQLite.",
                sql: sql
            )
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                transientDestructor()
            )
        }
        try check(result, operation: "bind payload")
    }

    func bindNull(at index: Int32) throws {
        try check(sqlite3_bind_null(statement, index), operation: "bind null")
    }

    /// Returns true for a row and false when the statement has completed.
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw UsageHistorySQLiteFailure(
                code: result,
                extendedCode: sqlite3_extended_errcode(database),
                message: String(cString: sqlite3_errmsg(database)),
                sql: sql
            )
        }
    }

    func text(at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func double(at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func data(at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else {
            throw UsageHistorySQLiteFailure(
                code: result,
                extendedCode: sqlite3_extended_errcode(database),
                message: "SQLite could not \(operation): \(String(cString: sqlite3_errmsg(database)))",
                sql: sql
            )
        }
    }

    private func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

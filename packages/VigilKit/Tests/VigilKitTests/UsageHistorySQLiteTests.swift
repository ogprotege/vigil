import Foundation
import SQLite3
import XCTest
@testable import VigilKit

final class UsageHistorySQLiteTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    func testSummaryAndCursorPagesAreFilteredAndNewestFirst() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let observed = (0..<5).map {
            sample(
                source: .observed,
                accountKey: "claude:a",
                offset: $0,
                value: Double($0)
            )
        }
        let backfill = (5..<7).map {
            sample(
                source: .providerBackfill,
                accountKey: "claude:a",
                offset: $0,
                value: Double($0)
            )
        }
        try store.importObserved(observed, now: base.addingTimeInterval(10))
        try store.importBackfill(backfill, now: base.addingTimeInterval(10))

        XCTAssertEqual(
            try store.summary(accountKey: "claude:a"),
            UsageHistorySummary(
                sampleCount: 7,
                observedCount: 5,
                providerBackfillCount: 2,
                oldestRecordedAt: base,
                newestRecordedAt: base.addingTimeInterval(6)
            )
        )
        XCTAssertEqual(
            try store.summary(source: .providerBackfill).sampleCount,
            2
        )

        let first = try store.page(accountKey: "claude:a", limit: 3)
        XCTAssertEqual(first.samples.map(\.recordedAt), [6, 5, 4].map(offsetDate))
        let second = try store.page(
            accountKey: "claude:a",
            limit: 3,
            cursor: try XCTUnwrap(first.nextCursor)
        )
        XCTAssertEqual(second.samples.map(\.recordedAt), [3, 2, 1].map(offsetDate))
        let third = try store.page(
            accountKey: "claude:a",
            limit: 3,
            cursor: try XCTUnwrap(second.nextCursor)
        )
        XCTAssertEqual(third.samples.map(\.recordedAt), [0].map(offsetDate))
        XCTAssertNil(third.nextCursor)

        let imported = try store.page(
            accountKey: "claude:a",
            source: .providerBackfill,
            limit: 50
        )
        XCTAssertEqual(imported.samples.map(\.source), [.providerBackfill, .providerBackfill])
    }

    func testLegacyJSONMigrationIsRetrySafeAndDeletesOnlyAfterCommit() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let legacyURL = directory.appendingPathComponent(UsageHistoryStore.legacyFilename)
        let original = sample(
            source: .observed,
            accountKey: "claude:legacy",
            offset: 0,
            value: 42
        )
        let data = try encodeLegacy([original])
        try data.write(to: legacyURL)

        XCTAssertEqual(try store.load(), [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    UsageHistoryStore.databaseFilename
                ).path
            )
        )

        // Models a crash after SQLite commit but before legacy-source deletion.
        try data.write(to: legacyURL)
        XCTAssertEqual(try store.load(), [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testLegacyIdentityCollisionRollsBackAndPreservesSource() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let identifier = UUID()
        let original = sample(
            id: identifier,
            source: .observed,
            accountKey: "claude:collision",
            offset: 0,
            value: 1
        )
        let changed = sample(
            id: identifier,
            source: .observed,
            accountKey: "claude:collision",
            offset: 0,
            value: 2
        )
        try store.importObserved([original], now: base)
        let legacyURL = directory.appendingPathComponent(UsageHistoryStore.legacyFilename)
        let legacy = try encodeLegacy([changed])
        try legacy.write(to: legacyURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case StorePersistenceError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)

        try FileManager.default.removeItem(at: legacyURL)
        XCTAssertEqual(try store.load(), [original])
    }

    func testSameUUIDWithDifferentPayloadIsRejected() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let identifier = UUID()
        let original = sample(
            id: identifier,
            source: .observed,
            accountKey: "claude:identity",
            offset: 0,
            value: 1
        )
        let changed = sample(
            id: identifier,
            source: .observed,
            accountKey: "claude:identity",
            offset: 0,
            value: 2
        )
        try store.importObserved([original], now: base)

        XCTAssertThrowsError(try store.importObserved([changed], now: base)) { error in
            guard case StorePersistenceError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(try store.load(), [original])
    }

    func testExactPayloadDedupDeterministicallyKeepsLatestRetrieval() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let older = UsageHistorySample(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            source: .observed,
            accountKey: "claude:dedup",
            providerId: "claude",
            recordedAt: base,
            retrievedAt: base,
            metrics: [
                UsageHistoryMetric(
                    id: "value",
                    label: "Value",
                    value: 1,
                    unit: "units",
                    kind: .spend
                ),
            ]
        )
        let newer = UsageHistorySample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            source: .observed,
            accountKey: older.accountKey,
            providerId: older.providerId,
            recordedAt: older.recordedAt,
            retrievedAt: base.addingTimeInterval(60),
            metrics: older.metrics
        )

        try store.importObserved([newer, older], now: newer.retrievedAt)
        XCTAssertEqual(try store.load().map(\.id), [newer.id])
        try store.importObserved([older], now: newer.retrievedAt)
        XCTAssertEqual(try store.load().map(\.id), [newer.id])
    }

    func testAccountDeleteRemovesAnAccountWithACorruptPayload() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let corrupt = sample(
            source: .observed,
            accountKey: "claude:corrupt-account",
            offset: 0,
            value: 1
        )
        let retained = sample(
            source: .observed,
            accountKey: "claude:retained-account",
            offset: 1,
            value: 2
        )
        try store.importObserved([corrupt, retained], now: base.addingTimeInterval(2))
        try withRawDatabase(
            at: directory.appendingPathComponent(UsageHistoryStore.databaseFilename)
        ) { database in
            try execute(
                database,
                sql: "UPDATE history_samples SET payload = X'00'"
                    + " WHERE id = '\(corrupt.id.uuidString)'"
            )
        }

        try store.delete(accountKey: corrupt.accountKey)
        XCTAssertEqual(try store.load(), [retained])
    }

    func testDeleteAllRecoversFromACorruptDatabase() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let databaseURL = directory.appendingPathComponent(
            UsageHistoryStore.databaseFilename
        )
        try Data("not-a-sqlite-database".utf8).write(to: databaseURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case StorePersistenceError.corruptData = error else {
                return XCTFail("Expected corruptData, got \(error)")
            }
        }
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testDatabaseHasRequiredIndexesAndWALMode() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        try store.importObserved(
            [sample(source: .observed, accountKey: "claude:index", offset: 0, value: 1)],
            now: base
        )
        let databaseURL = directory.appendingPathComponent(
            UsageHistoryStore.databaseFilename
        )

        let configured = try UsageHistorySQLiteConnection(path: databaseURL.path)
        XCTAssertEqual(try pragmaInteger(configured, "synchronous"), 2)
        XCTAssertEqual(try pragmaInteger(configured, "secure_delete"), 1)
        XCTAssertEqual(try pragmaInteger(configured, "busy_timeout"), 5_000)
        configured.close()

        try withRawDatabase(at: databaseURL) { database in
            XCTAssertEqual(try scalarText(database, sql: "PRAGMA journal_mode"), "wal")
            let indexes = try stringColumn(
                database,
                sql: "SELECT name FROM pragma_index_list('history_samples')",
                column: 0
            )
            XCTAssertTrue(indexes.contains("history_account_recorded_idx"))
            XCTAssertTrue(indexes.contains("history_account_source_recorded_idx"))
            XCTAssertTrue(indexes.contains("history_exact_payload_idx"))
            XCTAssertTrue(indexes.contains("history_effective_end_idx"))
        }
    }

    func testLiveWALAndSharedMemorySidecarsAreOwnerOnly() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        try store.importObserved(
            [sample(source: .observed, accountKey: "claude:files", offset: 0, value: 1)],
            now: base
        )
        let databaseURL = directory.appendingPathComponent(
            UsageHistoryStore.databaseFilename
        )

        try withRawDatabase(at: databaseURL) { database in
            try execute(database, sql: "BEGIN TRANSACTION")
            _ = try scalarText(database, sql: "SELECT id FROM history_samples LIMIT 1")
            try store.importObserved(
                [sample(source: .observed, accountKey: "claude:files", offset: 1, value: 2)],
                now: base.addingTimeInterval(1)
            )

            for suffix in ["-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
                XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            }
            try execute(database, sql: "COMMIT TRANSACTION")
        }
    }

    func testAppendAtTenThousandRowsDoesNotDecodeOrReturnTheArchive() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(
            directory: directory,
            maximumObservedEntries: 20_000,
            maximumProviderBackfillEntries: 20_000
        )
        let imported = (0..<10_000).map { index in
            sample(
                source: .providerBackfill,
                accountKey: "openai:large",
                offset: 0,
                value: Double(index)
            )
        }
        try store.importBackfill(imported, now: base.addingTimeInterval(20_000))
        XCTAssertEqual(try store.summary().sampleCount, 10_000)

        // A corrupt unrelated row proves append did not decode every payload.
        // The old whole-file implementation could not complete this mutation.
        let databaseURL = directory.appendingPathComponent(
            UsageHistoryStore.databaseFilename
        )
        try withRawDatabase(at: databaseURL) { database in
            try execute(
                database,
                sql: "UPDATE history_samples SET payload = X'00'"
                    + " WHERE id = '\(imported[0].id.uuidString)'"
            )
        }
        let appended: Void = try store.append(
            snapshot: snapshot(
                key: "openai:large",
                time: base,
                value: 81
            ),
            now: base.addingTimeInterval(20_001)
        )
        _ = appended
        XCTAssertEqual(try store.summary().sampleCount, 10_001)
        XCTAssertThrowsError(try store.load()) { error in
            guard case StorePersistenceError.corruptData = error else {
                return XCTFail("Expected corruptData, got \(error)")
            }
        }
    }

    private func offsetDate(_ offset: Int) -> Date {
        base.addingTimeInterval(Double(offset))
    }

    private func sample(
        id: UUID = UUID(),
        source: UsageHistorySource,
        accountKey: String,
        offset: Int,
        value: Double
    ) -> UsageHistorySample {
        UsageHistorySample(
            id: id,
            source: source,
            accountKey: accountKey,
            providerId: source == .observed ? "claude" : "openai",
            recordedAt: offsetDate(offset),
            retrievedAt: base.addingTimeInterval(30_000),
            metrics: [
                UsageHistoryMetric(
                    id: "value",
                    label: "Value",
                    value: value,
                    unit: "units",
                    kind: .spend
                ),
            ]
        )
    }

    private func snapshot(key: String, time: Date, value: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: "claude",
            accountKey: key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: time,
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: value,
                    resetsAt: time.addingTimeInterval(18_000),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
    }

    private func encodeLegacy(_ samples: [UsageHistorySample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            SQLiteLegacyEnvelope(schemaVersion: 1, samples: samples)
        )
    }

    private func withRawDatabase(
        at url: URL,
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw sqliteError(result, database: database)
        }
        defer { sqlite3_close_v2(database) }
        try body(database)
    }

    private func pragmaInteger(
        _ database: UsageHistorySQLiteConnection,
        _ name: String
    ) throws -> Int {
        let statement = try database.prepare("PRAGMA \(name)")
        guard try statement.step() else {
            throw NSError(
                domain: "UsageHistorySQLiteTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing PRAGMA \(name) result"]
            )
        }
        return statement.int(at: 0)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw sqliteError(result, database: database)
        }
    }

    private func scalarText(_ database: OpaquePointer, sql: String) throws -> String? {
        try stringColumn(database, sql: sql, column: 0).first
    }

    private func stringColumn(
        _ database: OpaquePointer,
        sql: String,
        column: Int32
    ) throws -> [String] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(prepared, database: database)
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else {
                throw sqliteError(result, database: database)
            }
            if let value = sqlite3_column_text(statement, column) {
                values.append(String(cString: value))
            }
        }
    }

    private func sqliteError(_ code: Int32, database: OpaquePointer?) -> NSError {
        NSError(
            domain: "UsageHistorySQLiteTests",
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: database.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "SQLite error \(code)",
            ]
        )
    }
}

private struct SQLiteLegacyEnvelope: Codable {
    let schemaVersion: Int
    let samples: [UsageHistorySample]
}

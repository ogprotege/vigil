import Darwin
import CryptoKit
import Foundation

public struct UsageHistorySummary: Equatable, Sendable {
    public let sampleCount: Int
    public let observedCount: Int
    public let providerBackfillCount: Int
    public let oldestRecordedAt: Date?
    public let newestRecordedAt: Date?

    public init(
        sampleCount: Int,
        observedCount: Int,
        providerBackfillCount: Int,
        oldestRecordedAt: Date?,
        newestRecordedAt: Date?
    ) {
        self.sampleCount = sampleCount
        self.observedCount = observedCount
        self.providerBackfillCount = providerBackfillCount
        self.oldestRecordedAt = oldestRecordedAt
        self.newestRecordedAt = newestRecordedAt
    }
}

/// Stable keyset cursor for history ordered newest first. Unlike an offset,
/// this does not skip or repeat existing rows when a newer sample arrives.
public struct UsageHistoryCursor: Codable, Equatable, Sendable {
    public let recordedAt: Date
    public let retrievedAt: Date
    public let id: UUID

    public init(recordedAt: Date, retrievedAt: Date, id: UUID) {
        self.recordedAt = UsageHistoryDate.normalized(recordedAt)
        self.retrievedAt = UsageHistoryDate.normalized(retrievedAt)
        self.id = id
    }

    public init(sample: UsageHistorySample) {
        self.init(
            recordedAt: sample.recordedAt,
            retrievedAt: sample.retrievedAt,
            id: sample.id
        )
    }
}

public struct UsageHistoryPage: Equatable, Sendable {
    /// Always ordered from newest to oldest.
    public let samples: [UsageHistorySample]
    /// Pass this to the next `page` call. `nil` means the query is exhausted.
    public let nextCursor: UsageHistoryCursor?

    public init(samples: [UsageHistorySample], nextCursor: UsageHistoryCursor?) {
        self.samples = samples
        self.nextCursor = nextCursor
    }
}

/// Transactional, cross-process history shared by the app and widget.
///
/// Samples are independent SQLite rows, so a normal append validates and
/// decodes only rows that could represent the same logical fetch. The external
/// history flock remains the process-wide boundary for retry-safe JSON
/// migration and delete-all; each operation otherwise uses a short-lived
/// FULLMUTEX SQLite connection in WAL mode.
public struct UsageHistoryStore: Sendable {
    public static let defaultRetentionDays = 400.0
    public static let defaultMaximumObservedEntries = 120_000
    public static let defaultMaximumProviderBackfillEntries = 5_000

    /// Kept as a source-compatibility alias. History has independent source
    /// budgets, so this is not a total archive-entry limit.
    @available(*, deprecated, message: "Use the source-specific maximum constants.")
    public static let defaultMaximumEntries = defaultMaximumObservedEntries

    static let databaseFilename = "usage-history-v2.sqlite3"
    static let legacyFilename = "usage-history-v1.json"
    static let lockFilename = "usage-history-v1.lock"

    private struct LegacyEnvelope: Codable {
        let schemaVersion: Int
        var samples: [UsageHistorySample]
    }

    private enum DatabaseOperation {
        case read
        case write
    }

    private struct StoredRow {
        let id: String
        let accountKey: String
        let source: String
        let recordedMilliseconds: Double
        let effectiveEndMilliseconds: Double
        let retrievedMilliseconds: Double
        let payloadDigest: Data
        let payload: Data
    }

    private struct PayloadIdentity: Encodable {
        let source: UsageHistorySource
        let accountKey: String
        let providerId: String
        let accountLabel: String?
        let planLabel: String?
        let periodEnd: Date?
        let status: SnapshotStatus
        let windows: [UsageHistoryWindow]
        let metrics: [UsageHistoryMetric]
        let quantities: [UsageHistoryQuantity]

        init(sample: UsageHistorySample) {
            self.source = sample.source
            self.accountKey = sample.accountKey
            self.providerId = sample.providerId
            self.accountLabel = sample.accountLabel
            self.planLabel = sample.planLabel
            self.periodEnd = sample.periodEnd
            self.status = sample.status
            self.windows = sample.windows
            self.metrics = sample.metrics
            self.quantities = sample.quantities
        }
    }

    private let directory: URL
    private let databaseURL: URL
    private let legacyURL: URL
    private let lockURL: URL
    private let retentionDays: Double
    private let maximumObservedEntries: Int
    private let maximumProviderBackfillEntries: Int

    public init(
        directory: URL,
        retentionDays: Double = Self.defaultRetentionDays,
        maximumObservedEntries: Int = Self.defaultMaximumObservedEntries,
        maximumProviderBackfillEntries: Int = Self.defaultMaximumProviderBackfillEntries
    ) {
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent(Self.databaseFilename)
        self.legacyURL = directory.appendingPathComponent(Self.legacyFilename)
        self.lockURL = directory.appendingPathComponent(Self.lockFilename)
        self.retentionDays = max(1, retentionDays)
        self.maximumObservedEntries = max(2, maximumObservedEntries)
        self.maximumProviderBackfillEntries = max(2, maximumProviderBackfillEntries)
    }

    /// Compatibility initializer for callers that previously supplied one
    /// cap. The value applies independently to each provenance source.
    @available(*, deprecated, message: "Use maximumObservedEntries and maximumProviderBackfillEntries.")
    public init(
        directory: URL,
        retentionDays: Double = Self.defaultRetentionDays,
        maximumEntries: Int
    ) {
        self.init(
            directory: directory,
            retentionDays: retentionDays,
            maximumObservedEntries: maximumEntries,
            maximumProviderBackfillEntries: maximumEntries
        )
    }

    /// Compatibility bulk read, ordered oldest first. New screens should use
    /// `summary` and `page` so archive size does not determine launch cost.
    public func load() throws -> [UsageHistorySample] {
        try withDatabase(operation: .read) { database in
            try readSamples(
                database: database,
                sql: Self.rowSelection
                    + " ORDER BY recorded_ms ASC, retrieved_ms ASC, id ASC",
                bind: { _ in }
            )
        }
    }

    /// Compatibility account read, ordered oldest first.
    public func load(accountKey: String) throws -> [UsageHistorySample] {
        try withDatabase(operation: .read) { database in
            try readSamples(
                database: database,
                sql: Self.rowSelection
                    + " WHERE account_key = ?"
                    + " ORDER BY recorded_ms ASC, retrieved_ms ASC, id ASC",
                bind: { statement in
                    try statement.bind(accountKey, at: 1)
                }
            )
        }
    }

    public func summary(
        accountKey: String? = nil,
        source: UsageHistorySource? = nil
    ) throws -> UsageHistorySummary {
        try withDatabase(operation: .read) { database in
            var conditions: [String] = []
            if accountKey != nil { conditions.append("account_key = ?") }
            if source != nil { conditions.append("source = ?") }
            let whereClause = conditions.isEmpty
                ? ""
                : " WHERE " + conditions.joined(separator: " AND ")
            let statement = try database.prepare(
                """
                SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN source = 'observed' THEN 1 ELSE 0 END), 0),
                       COALESCE(SUM(CASE WHEN source = 'providerBackfill' THEN 1 ELSE 0 END), 0),
                       MIN(recorded_ms), MAX(recorded_ms)
                FROM history_samples\(whereClause)
                """
            )
            var index: Int32 = 1
            if let accountKey {
                try statement.bind(accountKey, at: index)
                index += 1
            }
            if let source {
                try statement.bind(source.rawValue, at: index)
            }
            guard try statement.step() else {
                return UsageHistorySummary(
                    sampleCount: 0,
                    observedCount: 0,
                    providerBackfillCount: 0,
                    oldestRecordedAt: nil,
                    newestRecordedAt: nil
                )
            }
            return UsageHistorySummary(
                sampleCount: statement.int(at: 0),
                observedCount: statement.int(at: 1),
                providerBackfillCount: statement.int(at: 2),
                oldestRecordedAt: statement.double(at: 3).map(Self.date(milliseconds:)),
                newestRecordedAt: statement.double(at: 4).map(Self.date(milliseconds:))
            )
        }
    }

    /// Keyset-paged history, newest first. Limits are clamped to `1...1000`.
    public func page(
        accountKey: String? = nil,
        source: UsageHistorySource? = nil,
        limit: Int = 100,
        cursor: UsageHistoryCursor? = nil
    ) throws -> UsageHistoryPage {
        let boundedLimit = min(1_000, max(1, limit))
        return try withDatabase(operation: .read) { database in
            var conditions: [String] = []
            if accountKey != nil { conditions.append("account_key = ?") }
            if source != nil { conditions.append("source = ?") }
            if cursor != nil {
                conditions.append(
                    """
                    (recorded_ms < ?
                     OR (recorded_ms = ? AND retrieved_ms < ?)
                     OR (recorded_ms = ? AND retrieved_ms = ? AND id < ?))
                    """
                )
            }
            let whereClause = conditions.isEmpty
                ? ""
                : " WHERE " + conditions.joined(separator: " AND ")
            let statement = try database.prepare(
                Self.rowSelection
                    + whereClause
                    + " ORDER BY recorded_ms DESC, retrieved_ms DESC, id DESC"
                    + " LIMIT ?"
            )
            var index: Int32 = 1
            if let accountKey {
                try statement.bind(accountKey, at: index)
                index += 1
            }
            if let source {
                try statement.bind(source.rawValue, at: index)
                index += 1
            }
            if let cursor {
                let recorded = Self.milliseconds(cursor.recordedAt)
                let retrieved = Self.milliseconds(cursor.retrievedAt)
                try statement.bind(recorded, at: index)
                try statement.bind(recorded, at: index + 1)
                try statement.bind(retrieved, at: index + 2)
                try statement.bind(recorded, at: index + 3)
                try statement.bind(retrieved, at: index + 4)
                try statement.bind(cursor.id.uuidString, at: index + 5)
                index += 6
            }
            try statement.bind(Int64(boundedLimit + 1), at: index)

            var samples: [UsageHistorySample] = []
            while try statement.step() {
                samples.append(try decodeAndValidate(row: row(from: statement)))
            }
            let hasMore = samples.count > boundedLimit
            if hasMore { samples.removeLast(samples.count - boundedLimit) }
            return UsageHistoryPage(
                samples: samples,
                nextCursor: hasMore ? samples.last.map(UsageHistoryCursor.init(sample:)) : nil
            )
        }
    }

    /// Archives one accepted provider snapshot as an observation made by
    /// Vigil. Both times equal the snapshot fetch time by definition.
    public func append(snapshot: ProviderSnapshot, now: Date = Date()) throws {
        try mutate(adding: [UsageHistorySample(snapshot: snapshot)], now: now)
    }

    /// Imports observations produced by an earlier Vigil storage schema while
    /// preserving stable identifiers and original observation times.
    public func importObserved(
        _ samples: [UsageHistorySample],
        now: Date = Date()
    ) throws {
        guard samples.allSatisfy({ $0.source == .observed }) else {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: "Observed imports must use observed provenance."
            )
        }
        try mutate(adding: samples, now: now)
    }

    /// Imports official provider history without presenting its bucket time as
    /// a live device observation.
    public func importBackfill(
        _ samples: [UsageHistorySample],
        now: Date = Date()
    ) throws {
        guard samples.allSatisfy({ $0.source == .providerBackfill }) else {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: "Backfill imports must use providerBackfill provenance."
            )
        }
        try mutate(adding: samples, now: now)
    }

    public func delete(accountKey: String) throws {
        try withDatabase(operation: .write) { database in
            try database.transaction {
                let statement = try database.prepare(
                    "DELETE FROM history_samples WHERE account_key = ?"
                )
                try statement.bind(accountKey, at: 1)
                _ = try statement.step()
            }
        }
    }

    /// Removes the SQLite database, WAL/SHM sidecars, rollback journal, and a
    /// legacy source even when either data store is corrupt. The empty lock
    /// remains as the stable cross-process coordination point.
    public func deleteAll() throws {
        try PersistenceFileIO.withExclusiveLock(at: lockURL) {
            for url in sqliteFiles + [legacyURL] {
                try PersistenceFileIO.removeIfPresent(at: url)
            }
        }
    }

    private func mutate(adding samples: [UsageHistorySample], now: Date) throws {
        try validateInput(samples, now: now)
        try withDatabase(operation: .write) { database in
            try database.transaction {
                for sample in samples.sorted(by: Self.sampleOrder) {
                    try insertDeduplicated(sample, database: database)
                }
                try pruneExpired(database: database, now: now)
                let affected = Set(samples.map {
                    AccountSource(accountKey: $0.accountKey, source: $0.source)
                })
                for key in affected {
                    try enforceCap(
                        database: database,
                        accountKey: key.accountKey,
                        source: key.source
                    )
                }
            }
        }
    }

    private struct AccountSource: Hashable {
        let accountKey: String
        let source: UsageHistorySource
    }

    private func insertDeduplicated(
        _ sample: UsageHistorySample,
        database: UsageHistorySQLiteConnection
    ) throws {
        if let saved = try storedSample(withID: sample.id, database: database) {
            guard saved == sample else {
                throw StorePersistenceError.writeFailed(
                    path: databaseURL.path,
                    reason: "A different history sample already uses this identifier."
                )
            }
            return
        }

        let candidates = try samples(
            accountKey: sample.accountKey,
            recordedAt: sample.recordedAt,
            payloadDigest: try Self.payloadDigest(sample),
            database: database
        ).filter { $0.hasSamePayload(as: sample) }
        if !candidates.isEmpty {
            let winner = (candidates + [sample]).max(by: Self.canonicalDuplicateOrder)!
            if winner.id != sample.id {
                // Repair any duplicate rows while preserving the deterministic
                // existing winner. A retry then performs no writes.
                for candidate in candidates where candidate.id != winner.id {
                    try delete(id: candidate.id, database: database)
                }
                return
            }
            for candidate in candidates {
                try delete(id: candidate.id, database: database)
            }
        }
        try insert(sample, database: database)
    }

    private func insert(
        _ sample: UsageHistorySample,
        database: UsageHistorySQLiteConnection
    ) throws {
        let payload: Data
        let digest: Data
        do {
            payload = try Self.encoder().encode(sample)
            digest = try Self.payloadDigest(sample)
        } catch {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: error.localizedDescription
            )
        }
        let statement = try database.prepare(
            """
            INSERT INTO history_samples(
                id, account_key, source, recorded_ms, effective_end_ms,
                retrieved_ms, payload_digest, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(sample.id.uuidString, at: 1)
        try statement.bind(sample.accountKey, at: 2)
        try statement.bind(sample.source.rawValue, at: 3)
        try statement.bind(Self.milliseconds(sample.recordedAt), at: 4)
        try statement.bind(
            Self.milliseconds(sample.periodEnd ?? sample.recordedAt),
            at: 5
        )
        try statement.bind(Self.milliseconds(sample.retrievedAt), at: 6)
        try statement.bind(digest, at: 7)
        try statement.bind(payload, at: 8)
        _ = try statement.step()
    }

    private func storedSample(
        withID id: UUID,
        database: UsageHistorySQLiteConnection
    ) throws -> UsageHistorySample? {
        let statement = try database.prepare(
            Self.rowSelection + " WHERE id = ? LIMIT 1"
        )
        try statement.bind(id.uuidString, at: 1)
        guard try statement.step() else { return nil }
        return try decodeAndValidate(row: row(from: statement))
    }

    private func samples(
        accountKey: String,
        recordedAt: Date,
        payloadDigest: Data,
        database: UsageHistorySQLiteConnection
    ) throws -> [UsageHistorySample] {
        try readSamples(
            database: database,
            sql: Self.rowSelection
                + " WHERE account_key = ? AND recorded_ms = ? AND payload_digest = ?"
                + " ORDER BY retrieved_ms ASC, id ASC",
            bind: { statement in
                try statement.bind(accountKey, at: 1)
                try statement.bind(Self.milliseconds(recordedAt), at: 2)
                try statement.bind(payloadDigest, at: 3)
            }
        )
    }

    private func delete(id: UUID, database: UsageHistorySQLiteConnection) throws {
        let statement = try database.prepare("DELETE FROM history_samples WHERE id = ?")
        try statement.bind(id.uuidString, at: 1)
        _ = try statement.step()
    }

    private func pruneExpired(
        database: UsageHistorySQLiteConnection,
        now: Date
    ) throws {
        let cutoff = now.addingTimeInterval(-retentionDays * 86_400)
        let statement = try database.prepare(
            "DELETE FROM history_samples WHERE effective_end_ms < ?"
        )
        try statement.bind(Self.milliseconds(cutoff), at: 1)
        _ = try statement.step()
    }

    /// Preserves the oldest row plus the newest `cap - 1`, matching the JSON
    /// store's retention semantics without selecting or decoding the archive.
    private func enforceCap(
        database: UsageHistorySQLiteConnection,
        accountKey: String,
        source: UsageHistorySource
    ) throws {
        let cap = source == .observed
            ? maximumObservedEntries
            : maximumProviderBackfillEntries
        let statement = try database.prepare(
            """
            DELETE FROM history_samples
            WHERE id IN (
                SELECT id
                FROM history_samples
                WHERE account_key = ? AND source = ?
                  AND id != COALESCE(
                      (
                          SELECT id FROM history_samples
                          WHERE account_key = ? AND source = ?
                          ORDER BY recorded_ms ASC, retrieved_ms ASC, id ASC
                          LIMIT 1
                      ),
                      ''
                  )
                ORDER BY recorded_ms ASC, retrieved_ms ASC, id ASC
                LIMIT MAX(
                    (
                        SELECT COUNT(*) FROM history_samples
                        WHERE account_key = ? AND source = ?
                    ) - ?,
                    0
                )
            )
            """
        )
        try statement.bind(accountKey, at: 1)
        try statement.bind(source.rawValue, at: 2)
        try statement.bind(accountKey, at: 3)
        try statement.bind(source.rawValue, at: 4)
        try statement.bind(accountKey, at: 5)
        try statement.bind(source.rawValue, at: 6)
        try statement.bind(Int64(cap), at: 7)
        _ = try statement.step()
    }

    private func readSamples(
        database: UsageHistorySQLiteConnection,
        sql: String,
        bind: (UsageHistorySQLiteStatement) throws -> Void
    ) throws -> [UsageHistorySample] {
        let statement = try database.prepare(sql)
        try bind(statement)
        var samples: [UsageHistorySample] = []
        while try statement.step() {
            samples.append(try decodeAndValidate(row: row(from: statement)))
        }
        return samples
    }

    private func row(from statement: UsageHistorySQLiteStatement) throws -> StoredRow {
        guard let id = statement.text(at: 0),
              let accountKey = statement.text(at: 1),
              let source = statement.text(at: 2),
              let recorded = statement.double(at: 3),
              let effectiveEnd = statement.double(at: 4),
              let retrieved = statement.double(at: 5),
              let payloadDigest = statement.data(at: 6),
              let payload = statement.data(at: 7)
        else {
            throw StorePersistenceError.corruptData(
                path: databaseURL.path,
                reason: "A history row is missing required columns."
            )
        }
        return StoredRow(
            id: id,
            accountKey: accountKey,
            source: source,
            recordedMilliseconds: recorded,
            effectiveEndMilliseconds: effectiveEnd,
            retrievedMilliseconds: retrieved,
            payloadDigest: payloadDigest,
            payload: payload
        )
    }

    private func decodeAndValidate(row: StoredRow) throws -> UsageHistorySample {
        let sample: UsageHistorySample
        do {
            sample = try Self.decoder().decode(UsageHistorySample.self, from: row.payload)
        } catch {
            throw StorePersistenceError.corruptData(
                path: databaseURL.path,
                reason: "A history row payload cannot be decoded: \(error.localizedDescription)"
            )
        }
        if let reason = validationFailure(in: [sample]) {
            throw StorePersistenceError.corruptData(path: databaseURL.path, reason: reason)
        }
        let expectedDigest: Data
        do {
            expectedDigest = try Self.payloadDigest(sample)
        } catch {
            throw StorePersistenceError.corruptData(
                path: databaseURL.path,
                reason: "A history row payload cannot be fingerprinted: \(error.localizedDescription)"
            )
        }
        guard row.id == sample.id.uuidString,
              row.accountKey == sample.accountKey,
              row.source == sample.source.rawValue,
              row.recordedMilliseconds == Self.milliseconds(sample.recordedAt),
              row.effectiveEndMilliseconds
                == Self.milliseconds(sample.periodEnd ?? sample.recordedAt),
              row.retrievedMilliseconds == Self.milliseconds(sample.retrievedAt),
              row.payloadDigest == expectedDigest
        else {
            throw StorePersistenceError.corruptData(
                path: databaseURL.path,
                reason: "A history row index does not match its payload."
            )
        }
        return sample
    }

    private func withDatabase<T>(
        operation: DatabaseOperation,
        _ body: (UsageHistorySQLiteConnection) throws -> T
    ) throws -> T {
        try PersistenceFileIO.withExclusiveLock(at: lockURL) {
            do {
                try prepareDatabaseFile()
                let database = try UsageHistorySQLiteConnection(path: databaseURL.path)
                defer { database.close() }
                try secureSQLiteFiles()
                try migrateLegacyIfNeeded(database: database)
                let value = try body(database)
                try secureSQLiteFiles()
                return value
            } catch let error as StorePersistenceError {
                throw error
            } catch let error as UsageHistorySQLiteFailure {
                throw persistenceError(from: error, operation: operation)
            } catch {
                switch operation {
                case .read:
                    throw StorePersistenceError.readFailed(
                        path: databaseURL.path,
                        reason: error.localizedDescription
                    )
                case .write:
                    throw StorePersistenceError.writeFailed(
                        path: databaseURL.path,
                        reason: error.localizedDescription
                    )
                }
            }
        }
    }

    private func prepareDatabaseFile() throws {
        try PersistenceFileIO.ensureDirectory(directory)
        let descriptor = Darwin.open(
            databaseURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        var open = true
        defer { if open { _ = Darwin.close(descriptor) } }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            open = false
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        open = false
        try PersistenceFileIO.secureRegularFileIfPresent(at: databaseURL)
    }

    private var sqliteFiles: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ]
    }

    private func secureSQLiteFiles() throws {
        for url in sqliteFiles {
            try PersistenceFileIO.secureRegularFileIfPresent(at: url)
        }
    }

    /// Retry-safe migration: every validated row commits in one SQLite
    /// transaction before the source is removed. If deletion fails, the next
    /// call repeats idempotent inserts and tries the source removal again.
    private func migrateLegacyIfNeeded(
        database: UsageHistorySQLiteConnection
    ) throws {
        guard let data = try PersistenceFileIO.readIfPresent(at: legacyURL) else {
            return
        }
        let envelope: LegacyEnvelope
        do {
            envelope = try Self.decoder().decode(LegacyEnvelope.self, from: data)
        } catch {
            throw StorePersistenceError.corruptData(
                path: legacyURL.path,
                reason: error.localizedDescription
            )
        }
        guard envelope.schemaVersion == 1 else {
            throw StorePersistenceError.corruptData(
                path: legacyURL.path,
                reason: "Unsupported history schema version \(envelope.schemaVersion)."
            )
        }
        if let reason = validationFailure(in: envelope.samples) {
            throw StorePersistenceError.corruptData(path: legacyURL.path, reason: reason)
        }
        try database.transaction {
            for sample in envelope.samples.sorted(by: Self.sampleOrder) {
                try insertDeduplicated(sample, database: database)
            }
            try pruneExpired(database: database, now: Date())
            let affected = Set(envelope.samples.map {
                AccountSource(accountKey: $0.accountKey, source: $0.source)
            })
            for key in affected {
                try enforceCap(
                    database: database,
                    accountKey: key.accountKey,
                    source: key.source
                )
            }
        }
        try PersistenceFileIO.removeIfPresent(at: legacyURL)
    }

    private func persistenceError(
        from error: UsageHistorySQLiteFailure,
        operation: DatabaseOperation
    ) -> StorePersistenceError {
        let reason = error.sql.map { "\(error.message) [\($0)]" } ?? error.message
        if error.isCorruption {
            return .corruptData(path: databaseURL.path, reason: reason)
        }
        switch operation {
        case .read:
            return .readFailed(path: databaseURL.path, reason: reason)
        case .write:
            return .writeFailed(path: databaseURL.path, reason: reason)
        }
    }

    private func validateInput(_ samples: [UsageHistorySample], now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else {
            throw StorePersistenceError.writeFailed(
                path: databaseURL.path,
                reason: "Invalid pruning time."
            )
        }
        if let reason = validationFailure(in: samples) {
            throw StorePersistenceError.writeFailed(path: databaseURL.path, reason: reason)
        }
    }

    private func validationFailure(in samples: [UsageHistorySample]) -> String? {
        var sampleIDs = Set<UUID>()
        for sample in samples {
            guard sampleIDs.insert(sample.id).inserted else {
                return "History contains duplicate sample identifiers."
            }
            guard validText(sample.accountKey, maximum: 512),
                  validText(sample.providerId, maximum: 256),
                  validDate(sample.recordedAt), validDate(sample.retrievedAt),
                  sample.periodEnd.map(validDate) ?? true,
                  sample.periodEnd.map({ $0 >= sample.recordedAt }) ?? true
            else { return "A sample has invalid identity or timestamps." }
            guard optionalText(sample.accountLabel), optionalText(sample.planLabel) else {
                return "A sample label is invalid."
            }
            for window in sample.windows {
                guard validText(window.id, maximum: 512), optionalText(window.label),
                      window.utilization.isFinite, (0...100).contains(window.utilization),
                      validOptionalNumber(window.used, minimum: 0),
                      validOptionalNumber(window.limit, minimum: 0, exclusive: true),
                      validOptionalNumber(window.remaining, minimum: 0),
                      window.windowSeconds.map({ $0 > 0 }) ?? true,
                      window.resetAt.map(validDate) ?? true
                else { return "A history window contains invalid values." }
                let expected = UsageHistoryWindow.segmentIdentity(
                    providerId: sample.providerId,
                    windowId: window.id,
                    resetAt: window.resetAt
                )
                guard window.segmentId == expected else {
                    return "A history window has an invalid segment identity."
                }
            }
            for metric in sample.metrics {
                guard validText(metric.id, maximum: 512),
                      validText(metric.label, maximum: 1_024),
                      metric.value.isFinite,
                      metric.unit.map({ validText($0, maximum: 64) }) ?? true
                else { return "A history metric contains invalid values." }
            }
            for quantity in sample.quantities {
                guard validText(quantity.id, maximum: 512),
                      validText(quantity.label, maximum: 1_024),
                      quantity.value.isFinite, quantity.value >= 0,
                      validText(quantity.unit, maximum: 64)
                else { return "A history quantity contains invalid values." }
            }
        }
        return nil
    }

    private func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    private func optionalText(_ value: String?) -> Bool {
        value.map { validText($0, maximum: 1_024) } ?? true
    }

    private func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite
    }

    private func validOptionalNumber(
        _ value: Double?,
        minimum: Double,
        exclusive: Bool = false
    ) -> Bool {
        guard let value else { return true }
        return value.isFinite && (exclusive ? value > minimum : value >= minimum)
    }

    private static let rowSelection =
        """
        SELECT id, account_key, source, recorded_ms, effective_end_ms,
               retrieved_ms, payload_digest, payload
        FROM history_samples
        """

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1_000).rounded()
    }

    private static func date(milliseconds: Double) -> Date {
        UsageHistoryDate.normalized(
            Date(timeIntervalSince1970: milliseconds / 1_000)
        )
    }

    private static func payloadDigest(_ sample: UsageHistorySample) throws -> Data {
        let canonical = try encoder().encode(PayloadIdentity(sample: sample))
        return Data(SHA256.hash(data: canonical))
    }

    private static func sampleOrder(
        _ lhs: UsageHistorySample,
        _ rhs: UsageHistorySample
    ) -> Bool {
        (lhs.recordedAt, lhs.retrievedAt, lhs.id.uuidString)
            < (rhs.recordedAt, rhs.retrievedAt, rhs.id.uuidString)
    }

    private static func canonicalDuplicateOrder(
        _ lhs: UsageHistorySample,
        _ rhs: UsageHistorySample
    ) -> Bool {
        (lhs.retrievedAt, lhs.id.uuidString) < (rhs.retrievedAt, rhs.id.uuidString)
    }
}

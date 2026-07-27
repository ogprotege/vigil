import Foundation
import XCTest
@testable import VigilKit

final class UsageHistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    func testObservedSnapshotPreservesNormalizedFieldsAndPersists() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let reset = base.addingTimeInterval(18_000)
        let snapshot = makeSnapshot(
            time: base,
            utilization: 25,
            reset: reset,
            used: 50,
            limit: 200,
            remaining: 150,
            metrics: [
                UsageMetric(
                    id: "balance",
                    label: "Credit balance",
                    kind: .balance,
                    value: 12.5,
                    unit: "USD",
                    secondary: false
                ),
            ]
        )

        try store.append(snapshot: snapshot, now: base)
        let sample = try XCTUnwrap(
            UsageHistoryStore(directory: directory).load().only
        )

        XCTAssertEqual(sample.source, .observed)
        XCTAssertEqual(sample.source.displayLabel, "Observed by Vigil")
        XCTAssertEqual(sample.accountKey, snapshot.accountKey)
        XCTAssertEqual(sample.providerId, snapshot.providerId)
        XCTAssertEqual(sample.accountLabel, snapshot.accountLabel)
        XCTAssertEqual(sample.planLabel, snapshot.planLabel)
        XCTAssertEqual(sample.recordedAt, base)
        XCTAssertEqual(sample.retrievedAt, base)
        XCTAssertEqual(sample.status, .ok)
        XCTAssertEqual(sample.windows.first?.id, "session")
        XCTAssertEqual(sample.windows.first?.label, "Five hour")
        XCTAssertEqual(sample.windows.first?.utilization, 25)
        XCTAssertEqual(sample.windows.first?.used, 50)
        XCTAssertEqual(sample.windows.first?.limit, 200)
        XCTAssertEqual(sample.windows.first?.remaining, 150)
        XCTAssertEqual(sample.windows.first?.resetAt, reset)
        XCTAssertEqual(sample.windows.first?.windowSeconds, 18_000)
        XCTAssertEqual(sample.windows.first?.secondary, false)
        XCTAssertEqual(sample.metrics.first?.id, "balance")
        XCTAssertEqual(sample.metrics.first?.label, "Credit balance")
        XCTAssertEqual(sample.metrics.first?.kind, .balance)
        XCTAssertEqual(sample.metrics.first?.value, 12.5)
        XCTAssertEqual(sample.metrics.first?.unit, "USD")
        XCTAssertEqual(sample.metrics.first?.secondary, false)
    }

    func testResetTimestampStartsANewSegment() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let first = makeSnapshot(
            time: base,
            utilization: 25,
            reset: base.addingTimeInterval(18_000)
        )
        let second = makeSnapshot(
            time: base.addingTimeInterval(60),
            utilization: 25,
            reset: base.addingTimeInterval(36_000)
        )

        try store.append(snapshot: first, now: second.fetchedAt)
        try store.append(snapshot: second, now: second.fetchedAt)
        let samples = try store.load()

        XCTAssertEqual(samples.count, 2)
        XCTAssertNotEqual(samples[0].windows[0].segmentId, samples[1].windows[0].segmentId)
    }

    func testFractionalDatesSurvivePersistenceWithoutBreakingSegments() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let fetched = base.addingTimeInterval(0.123)
        let reset = base.addingTimeInterval(18_000.456)
        try store.append(
            snapshot: makeSnapshot(time: fetched, utilization: 25, reset: reset),
            now: fetched
        )

        let sample = try XCTUnwrap(try store.load().only)
        XCTAssertEqual(
            sample.recordedAt.timeIntervalSince1970,
            fetched.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(sample.windows.first?.resetAt).timeIntervalSince1970,
            reset.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testStablePlateauKeepsEveryDistinctSuccessfulObservation() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        for minute in 0..<4 {
            let time = base.addingTimeInterval(Double(minute * 60))
            try store.append(
                snapshot: makeSnapshot(time: time, utilization: 25),
                now: time
            )
        }

        let samples = try store.load()
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(
            samples.map(\.recordedAt),
            (0..<4).map { base.addingTimeInterval(Double($0 * 60)) }
        )
    }

    func testExactDuplicateFetchRemainsIdempotent() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let snapshot = makeSnapshot(time: base, utilization: 25)

        try store.append(snapshot: snapshot, now: base)
        try store.append(snapshot: snapshot, now: base)

        XCTAssertEqual(try store.load().count, 1)
    }

    func testExactDuplicateIsRemovedWhenAnotherPayloadSharesItsFetchTime() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let first = makeSnapshot(time: base, utilization: 25)
        let other = makeSnapshot(time: base, utilization: 50)

        try store.append(snapshot: first, now: base)
        try store.append(snapshot: other, now: base)
        try store.append(snapshot: first, now: base)

        XCTAssertEqual(
            try store.load().map { $0.windows[0].utilization }.sorted(),
            [25, 50]
        )
    }

    func testChangedValuesAreNotDeduplicated() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        for (minute, value) in [10.0, 20.0, 30.0].enumerated() {
            let time = base.addingTimeInterval(Double(minute * 60))
            try store.append(
                snapshot: makeSnapshot(time: time, utilization: value),
                now: time
            )
        }
        XCTAssertEqual(try store.load().map { $0.windows[0].utilization }, [10, 20, 30])
    }

    func testBackfillHasDistinctProvenanceAndTimes() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let recorded = base.addingTimeInterval(-86_400)
        let sample = makeBackfill(recordedAt: recorded, retrievedAt: base)

        try store.importBackfill([sample], now: base)
        let imported = try store.load()

        XCTAssertEqual(imported.only?.source, .providerBackfill)
        XCTAssertEqual(imported.only?.source.displayLabel, "Imported from provider")
        XCTAssertEqual(imported.only?.recordedAt, recorded)
        XCTAssertEqual(imported.only?.retrievedAt, base)
    }

    func testBackfillImportRejectsObservedProvenance() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let observed = UsageHistorySample(snapshot: makeSnapshot(time: base, utilization: 1))

        XCTAssertThrowsError(try store.importBackfill([observed], now: base)) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
    }

    func testInvalidRemainingValueFailsBeforePersistence() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let invalid = UsageHistorySample(
            source: .observed,
            accountKey: "claude:invalid-remaining",
            providerId: "claude",
            recordedAt: base,
            retrievedAt: base,
            windows: [
                UsageHistoryWindow(
                    providerId: "claude",
                    id: "session",
                    utilization: 50,
                    remaining: .infinity
                ),
            ]
        )

        XCTAssertThrowsError(try store.importObserved([invalid], now: base)) { error in
            guard case StorePersistenceError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testObservedImportPreservesStableIdentityAndIsIdempotent() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let stableID = UUID(uuidString: "E47B469D-6D1E-4024-8298-BC96AD916F8D")!
        let sample = UsageHistorySample(
            id: stableID,
            source: .observed,
            accountKey: "moonshot:legacy",
            providerId: "moonshot",
            recordedAt: base,
            retrievedAt: base,
            metrics: [
                UsageHistoryMetric(
                    id: "legacy_balance_usd",
                    label: "Earlier observed balance",
                    value: 8.25,
                    unit: "USD",
                    kind: .balance
                ),
            ]
        )

        try store.importObserved([sample], now: base)
        try store.importObserved([sample], now: base)

        let loaded = try XCTUnwrap(try store.load().only)
        XCTAssertEqual(loaded.id, stableID)
        XCTAssertEqual(loaded.source, .observed)
        XCTAssertEqual(loaded.recordedAt, base)
        XCTAssertEqual(loaded.retrievedAt, base)
        XCTAssertEqual(loaded.metrics.first?.value, 8.25)
    }

    func testObservedImportRejectsProviderBackfillProvenance() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())

        XCTAssertThrowsError(
            try store.importObserved(
                [makeBackfill(recordedAt: base, retrievedAt: base)],
                now: base
            )
        ) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
    }

    func testExactBackfillImportIsIdempotent() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let sample = makeBackfill(recordedAt: base, retrievedAt: base)
        try store.importBackfill([sample], now: base)
        try store.importBackfill([sample], now: base)
        XCTAssertEqual(try store.load().count, 1)
    }

    func testAccountAndFullDeletion() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        try store.append(snapshot: makeSnapshot(key: "claude:a", time: base, utilization: 10), now: base)
        try store.append(snapshot: makeSnapshot(key: "claude:b", time: base, utilization: 20), now: base)

        try store.delete(accountKey: "claude:a")
        XCTAssertEqual(try store.load().map(\.accountKey), ["claude:b"])

        try store.deleteAll()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(UsageHistoryStore.databaseFilename).path
            )
        )
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCorruptionFailsClosedAndFullDeleteStillWorks() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let file = directory.appendingPathComponent(UsageHistoryStore.legacyFilename)
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)

        XCTAssertThrowsError(try store.load()) { error in
            guard case StorePersistenceError.corruptData = error else {
                return XCTFail("Expected corruptData, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try store.append(snapshot: makeSnapshot(time: base, utilization: 1), now: base)
        )
        XCTAssertThrowsError(try store.delete(accountKey: "claude:a"))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)

        try store.deleteAll()
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testHistoryFileAndLockUseOwnerOnlyPermissions() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        try store.append(snapshot: makeSnapshot(time: base, utilization: 1), now: base)

        let required = [
            UsageHistoryStore.databaseFilename,
            UsageHistoryStore.lockFilename,
        ]
        let optionalSidecars = [
            UsageHistoryStore.databaseFilename + "-wal",
            UsageHistoryStore.databaseFilename + "-shm",
        ].filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
        for name in required + optionalSidecars {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }

    func testMapperRetainsProviderSuppliedUsedAndLimit() throws {
        let body = Data(#"{"membershipType":"enterprise","billingCycleEnd":"2026-08-11T00:00:00Z","individualUsage":{"overall":{"used":71,"limit":10000}}}"#.utf8)
        let mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.cursor, body: body))
        XCTAssertEqual(mapped.windows.first?.used, 71)
        XCTAssertEqual(mapped.windows.first?.limit, 10_000)
    }

    func testLegacyWindowWithoutAbsoluteValuesStillDecodes() throws {
        let data = Data(#"{"id":"session","label":null,"utilization":42,"resetsAt":null,"windowSeconds":18000,"secondary":false}"#.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: data)
        XCTAssertNil(window.used)
        XCTAssertNil(window.limit)
        XCTAssertEqual(window.utilization, 42)
    }

    private func makeSnapshot(
        key: String = "claude:a",
        time: Date,
        utilization: Double,
        reset: Date? = nil,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        metrics: [UsageMetric] = []
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: "claude",
            accountKey: key,
            accountLabel: "Primary",
            planLabel: "Max",
            fetchedAt: time,
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: utilization,
                    resetsAt: reset,
                    windowSeconds: 18_000,
                    secondary: false,
                    label: "Five hour",
                    used: used,
                    limit: limit,
                    remaining: remaining
                ),
            ],
            metrics: metrics
        )
    }

    private func makeBackfill(recordedAt: Date, retrievedAt: Date) -> UsageHistorySample {
        UsageHistorySample(
            source: .providerBackfill,
            accountKey: "openai:org",
            providerId: "openai",
            recordedAt: recordedAt,
            retrievedAt: retrievedAt,
            metrics: [
                UsageHistoryMetric(
                    id: "input_tokens",
                    label: "Input tokens",
                    value: 2_000,
                    unit: "tokens",
                    kind: .spend
                ),
            ]
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

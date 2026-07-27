import Foundation
import XCTest
@testable import VigilKit

final class UsageHistoryRetentionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    func testAgePruningDropsSamplesOlderThanFourHundredDays() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let old = base.addingTimeInterval(-401 * 86_400)
        try store.append(snapshot: snapshot(time: old, value: 1), now: old)
        try store.append(snapshot: snapshot(time: base, value: 2), now: base)

        XCTAssertEqual(try store.load().map(\.recordedAt), [base])
    }

    func testEntryCapIsIndependentPerAccountAndPreservesOldestAndNewest() throws {
        let store = UsageHistoryStore(
            directory: try TestSupport.tempDirectory(),
            maximumObservedEntries: 4
        )
        for minute in 0..<6 {
            for (offset, key) in ["claude:a", "claude:b"].enumerated() {
                let time = base.addingTimeInterval(Double(minute * 60 + offset))
                try store.append(
                    snapshot: snapshot(key: key, time: time, value: Double(minute + 1)),
                    now: time
                )
            }
        }

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 8)
        for key in ["claude:a", "claude:b"] {
            let account = loaded.filter { $0.accountKey == key }
            XCTAssertEqual(account.count, 4)
            XCTAssertEqual(
                account.compactMap { $0.windows.first?.utilization },
                [1, 4, 5, 6]
            )
        }
    }

    func testConcurrentStoreInstancesDoNotLoseObservations() async throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory, maximumObservedEntries: 100)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<48 {
                group.addTask {
                    let time = self.base.addingTimeInterval(Double(index))
                    try UsageHistoryStore(
                        directory: directory,
                        maximumObservedEntries: 100
                    ).append(
                        snapshot: self.snapshot(
                            key: "claude:\(index)",
                            time: time,
                            value: Double(index)
                        ),
                        now: self.base.addingTimeInterval(100)
                    )
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(try store.load().count, 48)
        XCTAssertEqual(Set(try store.load().map(\.accountKey)).count, 48)
    }

    func testHighCardinalityBackfillCannotEvictObservedHistory() {
        let observed = (0..<300).map { index in
            historySample(
                source: .observed,
                accountKey: "claude:\(index % 3)",
                index: index,
                value: Double(index)
            )
        }
        let backfill = (0..<5_001).map { index in
            historySample(
                source: .providerBackfill,
                accountKey: "openai:large-organization",
                index: 10_000 + index,
                value: Double(index)
            )
        }

        let retained = UsageHistoryRetention.pruned(
            UsageHistoryRetention.deduplicated(observed + backfill),
            now: base.addingTimeInterval(20_000),
            retentionDays: 400,
            maximumObservedEntries: 5_000,
            maximumProviderBackfillEntries: 5_000
        )

        let retainedObserved = retained.filter { $0.source == .observed }
        let retainedBackfill = retained.filter { $0.source == .providerBackfill }
        XCTAssertEqual(retained.count, 5_300)
        XCTAssertEqual(retainedObserved.count, observed.count)
        XCTAssertEqual(Set(retainedObserved.map(\.id)), Set(observed.map(\.id)))
        XCTAssertEqual(retainedBackfill.count, 5_000)
    }

    func testStoreAppliesIndependentSourceBudgets() throws {
        let store = UsageHistoryStore(
            directory: try TestSupport.tempDirectory(),
            maximumObservedEntries: 4,
            maximumProviderBackfillEntries: 3
        )
        for index in 0..<4 {
            let time = base.addingTimeInterval(Double(index))
            try store.append(
                snapshot: snapshot(time: time, value: Double(index + 1)),
                now: time
            )
        }
        let imports = (0..<8).map { index in
            historySample(
                source: .providerBackfill,
                accountKey: "openai:org",
                index: 1_000 + index,
                value: Double(index)
            )
        }

        try store.importBackfill(imports, now: base.addingTimeInterval(2_000))

        let retained = try store.load()
        XCTAssertEqual(retained.filter { $0.source == .observed }.count, 4)
        XCTAssertEqual(retained.filter { $0.source == .providerBackfill }.count, 3)
        XCTAssertEqual(retained.count, 7)
    }

    func testAccountLoadFiltersWithoutChangingStoredHistory() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        try store.append(snapshot: snapshot(key: "claude:a", time: base, value: 1), now: base)
        try store.append(snapshot: snapshot(key: "claude:b", time: base, value: 2), now: base)

        XCTAssertEqual(try store.load(accountKey: "claude:a").map(\.accountKey), ["claude:a"])
        XCTAssertEqual(try store.load().count, 2)
    }

    func testNonOKStatusIsRetainedAsAnObservedGap() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        try store.append(
            snapshot: snapshot(time: base, value: 1, status: .network),
            now: base
        )
        XCTAssertEqual(try store.load().first?.status, .network)
    }

    func testTamperedSegmentIdentityFailsClosed() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let file = directory.appendingPathComponent(UsageHistoryStore.legacyFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            LegacyHistoryEnvelope(
                schemaVersion: 1,
                samples: [UsageHistorySample(snapshot: snapshot(time: base, value: 1))]
            )
        )
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var samples = try XCTUnwrap(envelope["samples"] as? [[String: Any]])
        var windows = try XCTUnwrap(samples[0]["windows"] as? [[String: Any]])
        windows[0]["segmentId"] = "tampered"
        samples[0]["windows"] = windows
        envelope["samples"] = samples
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        try tampered.write(to: file)

        XCTAssertThrowsError(try store.load()) { error in
            guard case StorePersistenceError.corruptData = error else {
                return XCTFail("Expected corruptData, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), tampered)
    }

    func testInvalidInputFailsWithoutOverwritingHistory() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        try store.append(snapshot: snapshot(time: base, value: 1), now: base)
        let invalid = snapshot(
            time: base.addingTimeInterval(60),
            value: .nan
        )

        XCTAssertThrowsError(try store.append(snapshot: invalid, now: invalid.fetchedAt)) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
        XCTAssertEqual(try store.load().count, 1)
    }

    func testSegmentIdentityCannotCollideThroughPunctuation() {
        let first = UsageHistoryWindow.segmentIdentity(
            providerId: "a|b",
            windowId: "c",
            resetAt: base
        )
        let second = UsageHistoryWindow.segmentIdentity(
            providerId: "a",
            windowId: "b|c",
            resetAt: base
        )
        XCTAssertNotEqual(first, second)
    }

    private func snapshot(
        key: String = "claude:a",
        time: Date,
        value: Double,
        status: SnapshotStatus = .ok
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: "claude",
            accountKey: key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: time,
            status: status,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: value,
                    resetsAt: base.addingTimeInterval(18_000),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
    }

    private func historySample(
        source: UsageHistorySource,
        accountKey: String,
        index: Int,
        value: Double
    ) -> UsageHistorySample {
        let providerId = source == .observed ? "claude" : "openai"
        return UsageHistorySample(
            source: source,
            accountKey: accountKey,
            providerId: providerId,
            recordedAt: base.addingTimeInterval(Double(index)),
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
}

private struct LegacyHistoryEnvelope: Codable {
    let schemaVersion: Int
    let samples: [UsageHistorySample]
}

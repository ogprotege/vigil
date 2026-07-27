import Foundation
import XCTest
import VigilKit
@testable import Vigil

@MainActor
final class LegacyUsageObservationMigrationTests: XCTestCase {
    func testStartupMigratesMoneyReadingsAsObservedHistoryAndDeletesLegacyFile() async throws {
        let directory = try temporaryDirectory()
        let account = AccountRef(
            key: "moonshot:active",
            providerId: "moonshot",
            label: "Personal",
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let recordedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60
        )
        let stableID = UUID(uuidString: "490BEF1C-B39F-4EB7-98C4-F9AE8DBBE146")!
        let active = LegacyUsageObservation(
            id: stableID,
            recordedAt: recordedAt,
            accountKey: account.key,
            providerId: account.providerId,
            spendUSD: 12.5,
            remainingUSD: 7.25,
            balanceUSD: 19.75
        )
        let removedAccountRow = LegacyUsageObservation(
            recordedAt: recordedAt,
            accountKey: "moonshot:removed",
            providerId: "moonshot",
            spendUSD: 99
        )
        try writeLegacy([active, removedAccountRow], to: directory)

        // Simulate termination after the normalized import committed but
        // before the legacy file was deleted. The startup retry must not add a
        // second row because migration preserves the legacy UUID.
        try UsageHistoryStore(directory: directory).importObserved(
            [try XCTUnwrap(active.historySample)]
        )

        let model = AppModel(vault: InMemoryCredentialsStore(), directory: directory)
        await model.prepareHistoryStateForTesting()

        XCTAssertFalse(legacyFile(in: directory).fileExists)
        let sample = try XCTUnwrap(model.history(for: account).only)
        XCTAssertEqual(sample.id, stableID)
        XCTAssertEqual(sample.source, .observed)
        XCTAssertEqual(sample.recordedAt, recordedAt)
        XCTAssertEqual(sample.retrievedAt, recordedAt)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: sample.metrics.map { ($0.id, $0.value) }),
            [
                "legacy_balance_usd": 19.75,
                "legacy_remaining_usd": 7.25,
                "legacy_spend_usd": 12.5,
            ]
        )
        XCTAssertTrue(
            try UsageHistoryStore(directory: directory)
                .load(accountKey: removedAccountRow.accountKey)
                .isEmpty,
            "Migration must not resurrect history for an account already removed."
        )

        let relaunched = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory
        )
        await relaunched.prepareHistoryStateForTesting()
        XCTAssertEqual(relaunched.history(for: account).map(\.id), [stableID])
    }

    func testFailedNormalizedImportPreservesLegacyFileByteForByte() async throws {
        let directory = try temporaryDirectory()
        let account = AccountRef(
            key: "moonshot:active",
            providerId: "moonshot",
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let original = try writeLegacy(
            [
                LegacyUsageObservation(
                    accountKey: account.key,
                    providerId: account.providerId,
                    balanceUSD: 8
                ),
            ],
            to: directory
        )
        try Data("{not-json".utf8).write(
            to: directory.appendingPathComponent("usage-history-v1.json")
        )

        let model = AppModel(vault: InMemoryCredentialsStore(), directory: directory)
        await model.prepareHistoryStateForTesting()

        XCTAssertEqual(try Data(contentsOf: legacyFile(in: directory)), original)
        XCTAssertTrue(
            model.storageErrorMessage?.contains("earlier observed money history") == true
                || model.storageErrorMessage?.contains("protected quota history") == true
        )
    }

    func testLegacyAccountCleanupRetainsOtherRowsThenRemovesEmptyFile() throws {
        let directory = try temporaryDirectory()
        let first = LegacyUsageObservation(
            accountKey: "claude:first",
            providerId: "claude",
            spendUSD: 1
        )
        let second = LegacyUsageObservation(
            accountKey: "claude:second",
            providerId: "claude",
            spendUSD: 2
        )
        try writeLegacy([first, second], to: directory)
        let store = LegacyUsageObservationStore(directory: directory)

        try store.removeAll(accountKey: first.accountKey)
        XCTAssertEqual(try store.load().map(\.accountKey), [second.accountKey])

        try store.removeAll(accountKey: second.accountKey)
        XCTAssertFalse(store.exists)
    }

    @discardableResult
    private func writeLegacy(
        _ observations: [LegacyUsageObservation],
        to directory: URL
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(observations)
        try data.write(to: legacyFile(in: directory), options: .atomic)
        return data
    }

    private func legacyFile(in directory: URL) -> URL {
        directory.appendingPathComponent("usage-observations.json")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VigilLegacyMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private extension URL {
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

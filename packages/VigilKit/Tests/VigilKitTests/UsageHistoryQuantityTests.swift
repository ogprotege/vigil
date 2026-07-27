import Foundation
import XCTest
@testable import VigilKit

final class UsageHistoryQuantityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    func testTokenAndRequestQuantitiesRoundTripWithoutMoneySemantics() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let sample = backfill(quantities: [
            UsageHistoryQuantity(
                id: "input_tokens",
                kind: .inputTokens,
                label: "Input tokens",
                value: 2_000,
                unit: "tokens"
            ),
            UsageHistoryQuantity(
                id: "cached_input_tokens",
                kind: .cachedInputTokens,
                label: "Cached input tokens",
                value: 500,
                unit: "tokens"
            ),
            UsageHistoryQuantity(
                id: "requests",
                kind: .requests,
                label: "Requests",
                value: 12,
                unit: "requests"
            ),
        ])

        try store.importBackfill([sample], now: base)
        let quantities = try XCTUnwrap(try store.load().first).quantities

        XCTAssertEqual(quantities.map(\.id), [
            "cached_input_tokens", "input_tokens", "requests",
        ])
        XCTAssertEqual(quantities.map(\.kind), [
            .cachedInputTokens, .inputTokens, .requests,
        ])
        XCTAssertEqual(try store.load().first?.periodEnd, base.addingTimeInterval(86_400))
        XCTAssertTrue(try store.load().first?.metrics.isEmpty == true)
    }

    func testLegacyHistoryWithoutQuantitiesDecodesAsEmpty() throws {
        let directory = try TestSupport.tempDirectory()
        let store = UsageHistoryStore(directory: directory)
        let file = directory.appendingPathComponent(UsageHistoryStore.legacyFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(
            QuantityLegacyEnvelope(
                schemaVersion: 1,
                samples: [backfill(quantities: [])]
            )
        )

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var samples = try XCTUnwrap(envelope["samples"] as? [[String: Any]])
        samples[0].removeValue(forKey: "quantities")
        samples[0].removeValue(forKey: "periodEnd")
        envelope["samples"] = samples
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)

        XCTAssertEqual(try store.load().first?.quantities, [])
        XCTAssertNil(try store.load().first?.periodEnd)
    }

    func testDifferentProviderBucketQuantitiesRemainDistinct() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let first = backfill(
            recordedAt: base,
            quantities: [quantity(value: 100)]
        )
        let second = backfill(
            recordedAt: base.addingTimeInterval(86_400),
            quantities: [quantity(value: 200)]
        )

        try store.importBackfill([first, second], now: second.recordedAt)
        XCTAssertEqual(try store.load().count, 2)
    }

    func testEqualProviderBucketsRemainDistinctPeriods() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let first = backfill(recordedAt: base, quantities: [quantity(value: 100)])
        let second = backfill(
            recordedAt: base.addingTimeInterval(86_400),
            quantities: [quantity(value: 100)]
        )

        try store.importBackfill([first, second], now: second.periodEnd ?? second.recordedAt)
        XCTAssertEqual(try store.load().count, 2)
    }

    func testInvalidQuantityFailsBeforePersistence() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let invalid = backfill(quantities: [quantity(value: .infinity)])

        XCTAssertThrowsError(try store.importBackfill([invalid], now: base)) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testBackfillPeriodCannotEndBeforeItStarts() throws {
        let store = UsageHistoryStore(directory: try TestSupport.tempDirectory())
        let invalid = UsageHistorySample(
            source: .providerBackfill,
            accountKey: "openai:org",
            providerId: "openai",
            recordedAt: base,
            periodEnd: base.addingTimeInterval(-1),
            retrievedAt: base
        )

        XCTAssertThrowsError(try store.importBackfill([invalid], now: base)) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
    }

    private func quantity(value: Double) -> UsageHistoryQuantity {
        UsageHistoryQuantity(
            id: "input_tokens",
            kind: .inputTokens,
            label: "Input tokens",
            value: value,
            unit: "tokens"
        )
    }

    private func backfill(
        recordedAt: Date? = nil,
        quantities: [UsageHistoryQuantity]
    ) -> UsageHistorySample {
        let start = recordedAt ?? base
        return UsageHistorySample(
            source: .providerBackfill,
            accountKey: "openai:org",
            providerId: "openai",
            recordedAt: start,
            periodEnd: start.addingTimeInterval(86_400),
            retrievedAt: base.addingTimeInterval(2 * 86_400),
            quantities: quantities
        )
    }
}

private struct QuantityLegacyEnvelope: Codable {
    let schemaVersion: Int
    let samples: [UsageHistorySample]
}

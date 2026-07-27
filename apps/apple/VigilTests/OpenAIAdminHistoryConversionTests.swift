import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class OpenAIAdminHistoryConversionTests: XCTestCase {
    func testConversionKeepsTokenGroupsAndCostsAsSeparateBackfillSamples() throws {
        let start = Date(timeIntervalSince1970: 1_730_419_200)
        let end = start.addingTimeInterval(86_400)
        let retrieved = end.addingTimeInterval(3_600)
        let tokens = ["gpt-5", "gpt-4.1"].map { model in
            OpenAIAdminTokenPoint(
                source: .providerBackfill,
                bucketStart: start,
                bucketEnd: end,
                inputTokens: 1_000,
                outputTokens: 500,
                cachedInputTokens: 200,
                inputAudioTokens: 10,
                outputAudioTokens: 5,
                requestCount: 4,
                model: model,
                retrievedAt: retrieved
            )
        }
        let cost = OpenAIAdminCostPoint(
            source: .providerBackfill,
            bucketStart: start,
            bucketEnd: end,
            amount: 1.25,
            currency: "USD",
            lineItem: "Responses API",
            retrievedAt: retrieved
        )
        let result = OpenAIAdminHistoryResult(
            tokenPoints: tokens,
            costPoints: [cost],
            retrievedAt: retrieved
        )

        let samples = result.historySamples(
            accountKey: "openai:admin-org",
            accountLabel: "Work API",
            planLabel: "Organization"
        )

        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.source == .providerBackfill })
        XCTAssertTrue(samples.allSatisfy { $0.recordedAt == start })
        XCTAssertTrue(samples.allSatisfy { $0.periodEnd == end })
        XCTAssertTrue(samples.allSatisfy { $0.retrievedAt == retrieved })
        let tokenSamples = samples.filter { !$0.quantities.isEmpty }
        XCTAssertEqual(tokenSamples.count, 1)
        XCTAssertTrue(tokenSamples.allSatisfy(\.metrics.isEmpty))
        XCTAssertTrue(tokenSamples.allSatisfy { $0.quantities.count == 12 })
        XCTAssertTrue(tokenSamples.flatMap(\.quantities).contains {
            $0.kind == .cachedInputTokens && $0.value == 200
        })
        let ids = Set(tokenSamples.flatMap(\.quantities).map(\.id))
        XCTAssertTrue(ids.contains { $0.contains("model=gpt-5") })
        XCTAssertTrue(ids.contains { $0.contains("model=gpt-4.1") })

        let costSample = try XCTUnwrap(samples.first { !$0.metrics.isEmpty })
        XCTAssertTrue(costSample.quantities.isEmpty)
        XCTAssertEqual(costSample.metrics.count, 1, "Cost must not be duplicated per token group")
        XCTAssertEqual(costSample.metrics[0].kind, .spend)
        XCTAssertEqual(costSample.metrics[0].value, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(costSample.metrics[0].unit, "USD")
    }
}

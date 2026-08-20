import XCTest
@testable import VigilKit

final class BoundedTransportPolicyTests: XCTestCase {
    func testRejectsRedirectsAndOversizedDeclaredOrReceivedBodies() {
        XCTAssertFalse(BoundedTransportPolicy.acceptsRedirects)
        XCTAssertEqual(BoundedTransportPolicy.maximumResponseBytes, 1_048_576)
        XCTAssertTrue(BoundedTransportPolicy.accepts(expectedContentLength: -1))
        XCTAssertTrue(
            BoundedTransportPolicy.accepts(
                expectedContentLength: Int64(BoundedTransportPolicy.maximumResponseBytes)
            )
        )
        XCTAssertFalse(
            BoundedTransportPolicy.accepts(
                expectedContentLength: Int64(BoundedTransportPolicy.maximumResponseBytes) + 1
            )
        )
        XCTAssertTrue(
            BoundedTransportPolicy.accepts(
                receivedByteCount: BoundedTransportPolicy.maximumResponseBytes
            )
        )
        XCTAssertFalse(
            BoundedTransportPolicy.accepts(
                receivedByteCount: BoundedTransportPolicy.maximumResponseBytes + 1
            )
        )
    }

    func testOversizedSuccessBodyIsNetworkAndDoesNotMap() {
        let huge = Data(count: BoundedTransportPolicy.maximumResponseBytes + 1)
        let outcome = UsageClient.classify(
            data: huge,
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .network)
        XCTAssertTrue(outcome.windows.isEmpty)
        XCTAssertTrue(outcome.metrics.isEmpty)
        XCTAssertNil(outcome.planLabel)
    }

    func testOversizedAuthAndRateLimitBodiesStillClassifyFromStatus() {
        let huge = Data(count: BoundedTransportPolicy.maximumResponseBytes + 1)
        XCTAssertEqual(
            UsageClient.classify(
                data: huge,
                statusCode: 429,
                spec: ProviderRegistry.claude
            ).status,
            .rateLimited
        )
        XCTAssertEqual(
            UsageClient.classify(
                data: huge,
                statusCode: 401,
                spec: ProviderRegistry.claude
            ).status,
            .authExpired
        )
    }
}

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
}

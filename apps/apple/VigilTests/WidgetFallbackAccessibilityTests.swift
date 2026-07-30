import XCTest
@testable import Vigil

/// The circular widget's fallback ring previously spoke its decorative
/// glyph and empty gauge as "V, 0%". Its spoken surface lives in
/// UsagePresentation, which both the widget target and this app-hosted
/// test bundle compile, so the exact strings are provable here.
final class WidgetFallbackAccessibilityTests: XCTestCase {
    func testCircularFallbackSpeaksUnlinkedState() {
        XCTAssertEqual(
            UsagePresentation.circularFallbackAccessibilityLabel(accountDisplayName: nil),
            "Vigil, no account linked"
        )
    }

    func testCircularFallbackSpeaksWaitingStateForALinkedAccount() {
        XCTAssertEqual(
            UsagePresentation.circularFallbackAccessibilityLabel(accountDisplayName: "Claude"),
            "Claude, waiting for first fetch"
        )
    }
}

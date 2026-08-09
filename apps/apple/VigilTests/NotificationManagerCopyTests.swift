import XCTest
import VigilKit
@testable import Vigil

final class NotificationManagerCopyTests: XCTestCase {
    private let account = AccountRef(
        key: "claude:private-account",
        providerId: "claude",
        label: "Personal",
        plan: nil
    )
    private let event = ThresholdEvent(
        windowId: "weekly",
        threshold: 95,
        utilization: 96
    )

    func testDetailedCopyIncludesProviderWindowAndUtilization() {
        let copy = NotificationManager.notificationCopy(
            event: event,
            account: account,
            hidesDetails: false
        )

        XCTAssertTrue(copy.title.contains("Claude"))
        XCTAssertTrue(copy.title.contains("weekly"))
        XCTAssertTrue(copy.title.contains("96%"))
    }

    func testPrivateCopyContainsNoProviderAccountWindowOrValue() {
        let copy = NotificationManager.notificationCopy(
            event: event,
            account: account,
            hidesDetails: true
        )
        let rendered = "\(copy.title) \(copy.body)".lowercased()

        XCTAssertFalse(rendered.contains("claude"))
        XCTAssertFalse(rendered.contains("personal"))
        XCTAssertFalse(rendered.contains("weekly"))
        XCTAssertFalse(rendered.contains("95"))
        XCTAssertFalse(rendered.contains("96"))
    }
}

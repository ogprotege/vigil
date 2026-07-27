import SwiftUI
import XCTest
@testable import Vigil

final class AppPrivacyPolicyTests: XCTestCase {
    func testPrivacyCoverIsAbsentOnlyWhileSceneIsActive() {
        XCTAssertFalse(AppPrivacyPolicy.showsPrivacyCover(for: .active))
        XCTAssertTrue(AppPrivacyPolicy.showsPrivacyCover(for: .inactive))
        XCTAssertTrue(AppPrivacyPolicy.showsPrivacyCover(for: .background))
    }

    func testProtectedContentIsHiddenWhileLockedOrCovered() {
        XCTAssertFalse(
            AppPrivacyPolicy.hidesProtectedContent(
                locked: false,
                scenePhase: .active
            )
        )
        XCTAssertTrue(
            AppPrivacyPolicy.hidesProtectedContent(
                locked: true,
                scenePhase: .active
            )
        )
        XCTAssertTrue(
            AppPrivacyPolicy.hidesProtectedContent(
                locked: false,
                scenePhase: .inactive
            )
        )
        XCTAssertTrue(
            AppPrivacyPolicy.hidesProtectedContent(
                locked: false,
                scenePhase: .background
            )
        )
    }

    func testLockUITestLaunchHookRequiresExactOptIn() {
        XCTAssertTrue(
            AppLockLaunchConfiguration.holdsLockForUITesting(
                environment: ["VIGIL_UI_TEST_LOCKED": "1"]
            )
        )
        XCTAssertFalse(
            AppLockLaunchConfiguration.holdsLockForUITesting(
                environment: ["VIGIL_UI_TEST_LOCKED": "true"]
            )
        )
        XCTAssertFalse(
            AppLockLaunchConfiguration.holdsLockForUITesting(environment: [:])
        )
    }
}

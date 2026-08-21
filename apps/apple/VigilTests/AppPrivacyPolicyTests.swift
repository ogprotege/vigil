import SwiftUI
import XCTest
@testable import Vigil

final class AppPrivacyPolicyTests: XCTestCase {
    func testPublicPrivacyAndSupportLinksUseHTTPS() {
        XCTAssertEqual(VigilLinks.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(VigilLinks.supportURL.scheme, "https")
        XCTAssertNotEqual(VigilLinks.privacyPolicyURL, VigilLinks.supportURL)
    }

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

    func testDeviceOwnerLockStaysClosedWhenPolicyIsUnavailable() {
        XCTAssertFalse(AppLockAuthentication.unlocksWhenPolicyUnavailable)
        XCTAssertEqual(
            UsagePresentation.hiddenUsageAccessibilityLabel,
            "Usage values hidden"
        )
        XCTAssertFalse(
            UsagePresentation.hiddenUsageAccessibilityLabel.localizedCaseInsensitiveContains("claude")
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

    func testActiveSceneUITestHookRequiresExactOptIn() {
        XCTAssertTrue(
            AppPrivacyLaunchConfiguration.forcesActiveSceneForUITesting(
                environment: ["VIGIL_UI_TEST_FORCE_ACTIVE": "1"]
            )
        )
        XCTAssertFalse(
            AppPrivacyLaunchConfiguration.forcesActiveSceneForUITesting(
                environment: ["VIGIL_UI_TEST_FORCE_ACTIVE": "true"]
            )
        )
        XCTAssertFalse(
            AppPrivacyLaunchConfiguration.forcesActiveSceneForUITesting(
                environment: [:]
            )
        )
    }

    func testStorageNoticeUITestHookRequiresExactOptIn() {
        XCTAssertTrue(
            AppStorageNoticeLaunchConfiguration.suppressesForUITesting(
                environment: ["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE": "1"]
            )
        )
        XCTAssertFalse(
            AppStorageNoticeLaunchConfiguration.suppressesForUITesting(
                environment: ["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE": "true"]
            )
        )
        XCTAssertFalse(
            AppStorageNoticeLaunchConfiguration.suppressesForUITesting(
                environment: [:]
            )
        )
    }

    func testRootDestinationLaunchHookCannotChangeReleaseNavigation() {
        #if DEBUG
        XCTAssertEqual(
            VigilLaunchConfiguration.destination(
                environment: ["VIGIL_TAB": "settings"]
            ),
            .settings
        )
        XCTAssertEqual(
            VigilLaunchConfiguration.destination(
                environment: ["VIGIL_TAB": "connections"]
            ),
            .connections
        )
        #endif
        XCTAssertEqual(
            VigilLaunchConfiguration.destination(
                environment: ["VIGIL_TAB": "not-a-destination"]
            ),
            .home
        )
        #if !DEBUG
        XCTAssertEqual(
            VigilLaunchConfiguration.destination(
                environment: ["VIGIL_TAB": "settings"]
            ),
            .home,
            "Release builds must ignore screenshot and UI-test navigation hooks"
        )
        #endif
    }
}

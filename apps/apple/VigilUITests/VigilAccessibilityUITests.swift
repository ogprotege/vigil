import UIKit
import XCTest

final class VigilAccessibilityUITests: XCTestCase {
    private enum ContentSizeScenario {
        case defaultSize
        case xxxl
        case accessibilityXXXL

        var category: UIContentSizeCategory? {
            switch self {
            case .defaultSize: nil
            case .xxxl: .extraExtraExtraLarge
            case .accessibilityXXXL: .accessibilityExtraExtraExtraLarge
            }
        }

        var name: String {
            switch self {
            case .defaultSize: "default"
            case .xxxl: "xxxl"
            case .accessibilityXXXL: "accessibility-xxxl"
            }
        }
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = nil
    }

    func testCriticalActionsAtDefaultContentSize() {
        assertCriticalActions(in: .defaultSize)
    }

    func testCriticalActionsAtXXXL() {
        assertCriticalActions(in: .xxxl)
    }

    func testCriticalActionsAtAccessibilityXXXL() {
        assertCriticalActions(in: .accessibilityXXXL)
    }

    func testDegradedHomeCardSpeaksDataAgeNotACheckTime() {
        // The Home card combines its children and replaces them with one
        // spoken summary, so the honest-freshness rule must hold for that
        // summary itself: a degraded snapshot's fetchedAt is when the shown
        // data was last accepted — polls may still run every minute — so
        // VoiceOver must age the data, never claim a check time.
        launch(tab: "home", demo: true, claudeProviderChanged: true)

        let claudeAccount = reachableElement("vigil.home.account.claude")
        let spoken = claudeAccount.label
        XCTAssertTrue(
            spoken.contains("Provider changed"),
            "The drifted demo account must speak its status. Spoken: \(spoken)"
        )
        XCTAssertTrue(
            spoken.contains("Data from"),
            "VoiceOver must age retained data, not claim a check. Spoken: \(spoken)"
        )
        XCTAssertFalse(
            spoken.contains("Last checked"),
            "A degraded snapshot's fetchedAt is not a check time. Spoken: \(spoken)"
        )
    }

    func testDiagnosticExportIsReachableAtDefaultContentSize() {
        launch(tab: "settings", demo: true)

        assertReachableInScrollView("vigil.settings.exportDiagnostics")
    }

    func testDiagnosticExportIsReachableAtAccessibilityXXXL() {
        launch(
            tab: "settings",
            demo: true,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        assertReachableInScrollView("vigil.settings.exportDiagnostics")
    }

    func testDiagnosticExportIsReachableAtXXXL() {
        launch(
            tab: "settings",
            demo: true,
            contentSizeCategory: .extraExtraExtraLarge
        )

        assertReachableInScrollView("vigil.settings.exportDiagnostics")
    }

    func testAccountRemovalConfirmationIsReachable() {
        launch(tab: "connections", demo: true)

        let remove = app.buttons["vigil.accounts.remove.claude"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        XCTAssertTrue(remove.isHittable)
        remove.tap()

        let confirmationTitle = app.staticTexts["Remove Claude?"]
        XCTAssertTrue(
            confirmationTitle.waitForExistence(timeout: 5),
            "Remove must present a destructive confirmation before changing data."
        )
        let destructiveAction = app.buttons["Remove account"]
        XCTAssertTrue(destructiveAction.exists)
    }

    private func assertCriticalActions(in scenario: ContentSizeScenario) {
        assertFirstRunSetupRoutes(in: scenario)
        assertHomeAndAccountDetailRoutes(in: scenario)
    }

    private func assertFirstRunSetupRoutes(in scenario: ContentSizeScenario) {
        let routes = [
            (identifier: "vigil.setup.claude", destination: "Sign in with Claude"),
            (identifier: "vigil.setup.codex", destination: "Sign in with Codex"),
            (identifier: "vigil.setup.other", destination: "Other provider"),
        ]

        launch(
            tab: "home",
            demo: false,
            contentSizeCategory: scenario.category
        )

        for route in routes {
            let action = reachableElement(route.identifier)
            if route.identifier == "vigil.setup.other" {
                attachScreenshot(named: "add-account-\(scenario.name)")
            }
            tapVisiblePortion(of: action)

            XCTAssertTrue(
                app.navigationBars[route.destination].waitForExistence(timeout: 5),
                "\(route.identifier) must open \(route.destination) at \(scenario.name)."
            )

            let close = app.buttons["vigil.addAccount.close"]
            XCTAssertTrue(
                close.waitForExistence(timeout: 5),
                "The \(route.destination) sheet must remain dismissible at \(scenario.name)."
            )
            close.tap()
            XCTAssertTrue(
                app.navigationBars["Vigil"].waitForExistence(timeout: 5),
                "Closing \(route.destination) must return to first-run setup at \(scenario.name)."
            )
        }
    }

    private func assertHomeAndAccountDetailRoutes(in scenario: ContentSizeScenario) {
        launch(
            tab: "home",
            demo: true,
            contentSizeCategory: scenario.category,
            claudeAuthExpired: true
        )

        let claudeAccount = reachableElement("vigil.home.account.claude")
        attachScreenshot(named: "home-\(scenario.name)")
        tapVisiblePortion(of: claudeAccount)

        XCTAssertTrue(
            app.navigationBars["Claude"].waitForExistence(timeout: 5),
            "The Claude Home summary must open account detail at \(scenario.name)."
        )
        XCTAssertTrue(
            app.staticTexts["This sign-in expired."].waitForExistence(timeout: 5),
            "Account detail must expose the expired-auth recovery state at \(scenario.name)."
        )

        let relink = reachableElement("vigil.account.relink")
        attachScreenshot(named: "account-detail-\(scenario.name)")
        tapVisiblePortion(of: relink)

        XCTAssertTrue(
            app.navigationBars["Sign in with Claude"].waitForExistence(timeout: 5),
            "Re-link must open the account's provider-specific flow at \(scenario.name)."
        )
    }

    private func launch(
        tab: String,
        demo: Bool,
        contentSizeCategory: UIContentSizeCategory? = nil,
        claudeAuthExpired: Bool = false,
        claudeProviderChanged: Bool = false
    ) {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_TAB"] = tab
        app.launchEnvironment["VIGIL_DEMO"] = demo ? "1" : "0"
        app.launchEnvironment["VIGIL_DEMO_CLAUDE_AUTH_EXPIRED"] = claudeAuthExpired ? "1" : "0"
        app.launchEnvironment["VIGIL_DEMO_CLAUDE_PROVIDER_CHANGED"] = claudeProviderChanged ? "1" : "0"
        app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
        if let contentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                contentSizeCategory.rawValue,
            ]
        }
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func reachableElement(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = element(identifier)
        let scrollView = app.scrollViews.firstMatch

        if target.waitForExistence(timeout: 2), hasSafeVisibleArea(target) {
            return target
        }

        for _ in 0..<10 where scrollView.exists {
            scrollToward(target, in: scrollView)
            if target.waitForExistence(timeout: 1), hasSafeVisibleArea(target) {
                return target
            }
        }

        XCTAssertTrue(
            target.exists,
            "Missing accessibility element \(identifier)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            target.isHittable,
            "Accessibility element \(identifier) could not be reached by scrolling",
            file: file,
            line: line
        )
        return target
    }

    /// XCTest may report a large Dynamic Type card as hittable when only a
    /// narrow strip is visible beneath the tab bar. Require a real tap target
    /// inside the content area, then tap the center of that visible portion.
    private func hasSafeVisibleArea(_ target: XCUIElement) -> Bool {
        guard target.exists, target.isHittable else { return false }
        return safeVisibleFrame(of: target).height >= 44
    }

    private func tapVisiblePortion(of target: XCUIElement) {
        let visibleFrame = safeVisibleFrame(of: target)
        XCTAssertGreaterThanOrEqual(
            visibleFrame.height,
            44,
            "The accessibility element must expose at least a 44-point tap target."
        )

        let frame = target.frame
        let tapPoint = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let offset = CGVector(
            dx: (tapPoint.x - frame.minX) / frame.width,
            dy: (tapPoint.y - frame.minY) / frame.height
        )
        target.coordinate(withNormalizedOffset: offset).tap()
    }

    private func safeVisibleFrame(of target: XCUIElement) -> CGRect {
        target.frame.intersection(safeApplicationFrame)
    }

    private var safeApplicationFrame: CGRect {
        app.frame.inset(
            by: UIEdgeInsets(top: 110, left: 8, bottom: 84, right: 8)
        )
    }

    /// Scroll in the direction of the target. Blind upward swipes can push a
    /// partially clipped first card farther behind the navigation bar,
    /// especially at accessibility sizes after an alert is dismissed.
    private func scrollToward(_ target: XCUIElement, in scrollView: XCUIElement) {
        guard target.exists else {
            scrollView.swipeUp()
            return
        }
        let frame = target.frame
        if frame.midY < safeApplicationFrame.midY {
            scrollView.swipeDown()
        } else {
            scrollView.swipeUp()
        }
    }

    private func assertReachableInScrollView(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = reachableElement(identifier, file: file, line: line)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

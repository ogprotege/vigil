import XCTest

final class VigilPrivacyLockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_DEMO"] = "1"
        app.launchEnvironment["VIGIL_TAB"] = "home"
        app.launchEnvironment["VIGIL_UI_TEST_LOCKED"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
    }

    func testLockIsModalAndBlocksAccountContentUntilForegroundUnlock() {
        let lockSurface = app.alerts["vigil.lock"]
        XCTAssertTrue(lockSurface.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Vigil is locked"].exists)

        let unlock = app.buttons["vigil.lock.unlock"]
        XCTAssertTrue(unlock.exists)
        XCTAssertTrue(unlock.isHittable)

        let protectedAccount = app.descendants(matching: .any)["vigil.home.account.claude"]
        XCTAssertFalse(
            protectedAccount.isHittable,
            "Locked account content must not receive accessibility activation."
        )
        XCTAssertFalse(
            app.buttons["Refresh limits"].isHittable,
            "The underlying RootView must not receive interaction while locked."
        )
        attachScreenshot(named: "privacy-lock-modal")

        unlock.tap()

        XCTAssertTrue(app.navigationBars["Limits"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["vigil.home.account.claude"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(lockSurface.exists)
        attachScreenshot(named: "privacy-lock-foreground-unlocked")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

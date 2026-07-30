import XCTest

/// The remove-account confirmation previously read its pending @State from a
/// Task that ran after dialog dismissal had already cleared it, so confirming
/// silently removed nothing. This walks the real dialog end to end: tap Remove
/// on a row, confirm, and require the row to leave the list with no
/// removal-error alert. The history-recovery dialog shares the same wiring and
/// the same failure mode, so it gets the same walk.
final class VigilAccountRemovalUITests: XCTestCase {
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

    func testConfirmingRemoveAccountRemovesTheRow() {
        launch()

        let removeButton = confirmRemovalOfKimiRow()

        expectation(
            for: NSPredicate(format: "exists == FALSE"),
            evaluatedWith: removeButton
        )
        waitForExpectations(timeout: 5)

        XCTAssertFalse(
            app.alerts["Account removal needs attention"].exists,
            "Confirmed removal must not end in a removal error"
        )
    }

    func testHistoryRecoveryDialogDeletesHistoryAndFinishesRemoval() {
        // When account-only removal is blocked by damaged history, the
        // recovery dialog's confirm is the last working exit: credentials are
        // already gone. Its action must actually finish the removal.
        launch(historyRecovery: true)

        let removeButton = confirmRemovalOfKimiRow()

        let recoveryTitle = app.staticTexts["Delete all local Vigil history?"]
        XCTAssertTrue(
            recoveryTitle.waitForExistence(timeout: 5),
            "Blocked removal must present the history-recovery dialog"
        )
        let recover = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier == %@",
                "Delete all history and finish removal", ""
            )
        ).firstMatch
        XCTAssertTrue(
            recover.waitForExistence(timeout: 2),
            "The recovery dialog must offer its destructive completion action"
        )
        recover.tap()

        expectation(
            for: NSPredicate(format: "exists == FALSE"),
            evaluatedWith: removeButton
        )
        waitForExpectations(timeout: 5)

        XCTAssertFalse(
            app.alerts["Account removal needs attention"].exists,
            "Recovery must finish the removal without a removal error"
        )
    }

    private func launch(historyRecovery: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_TAB"] = "connections"
        app.launchEnvironment["VIGIL_DEMO"] = "1"
        app.launchEnvironment["VIGIL_DEMO_CLAUDE_AUTH_EXPIRED"] = "0"
        app.launchEnvironment["VIGIL_DEMO_HISTORY_RECOVERY"] = historyRecovery ? "1" : "0"
        app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
        app.launch()
    }

    /// Taps Remove on the demo Kimi K3 row and confirms the first dialog,
    /// returning the row's remove button for leave-the-list expectations.
    private func confirmRemovalOfKimiRow() -> XCUIElement {
        let removeButton = app.descendants(matching: .any)["vigil.accounts.remove.kimi_code"]
        XCTAssertTrue(
            removeButton.waitForExistence(timeout: 5),
            "The demo Kimi K3 row must offer Remove account"
        )
        // A card taller than the visible strip under the tab bar still
        // reports isHittable, and its center tap then lands elsewhere.
        // Scroll until the button's full frame sits inside the window.
        let scrollView = app.scrollViews.firstMatch
        let window = app.windows.firstMatch
        var attempts = 0
        while attempts < 10, scrollView.exists {
            let visible = window.frame.insetBy(dx: 0, dy: 120)
            if removeButton.isHittable, visible.contains(removeButton.frame) {
                break
            }
            scrollView.swipeUp()
            attempts += 1
        }
        removeButton.tap()

        // SwiftUI's confirmationDialog is not reliably exposed as an XCUI
        // sheet; anchor on its message text instead. The dialog's confirm
        // button shares the row button's label but has no identifier.
        let dialogMessage = app.staticTexts[
            "This deletes the credential and saved usage from this device."
        ]
        XCTAssertTrue(
            dialogMessage.waitForExistence(timeout: 5),
            "Tapping Remove account must present the confirmation dialog"
        )
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier == %@", "Remove account", "")
        ).firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 2),
            "The confirmation dialog must offer its own Remove account action"
        )
        confirm.tap()
        return removeButton
    }
}

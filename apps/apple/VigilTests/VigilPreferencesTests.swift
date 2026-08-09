import SwiftUI
import XCTest
@testable import Vigil

final class VigilPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "vigil-preferences-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testDefaultsKeepAlertsAndAutomaticChecksEnabled() {
        let preferences = VigilPreferences(defaults: defaults, environment: [:])

        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertTrue(preferences.usageAlertsEnabled)
        XCTAssertFalse(preferences.automaticChecksPaused)
        XCTAssertFalse(preferences.widgetValuesHidden)
        XCTAssertFalse(preferences.notificationDetailsHidden)
    }

    func testAppearanceIncludesSystemLightAndDark() {
        XCTAssertEqual(VigilPreferences.Appearance.allCases, [.system, .light, .dark])
        XCTAssertNil(VigilPreferences.Appearance.system.colorScheme)
        XCTAssertEqual(VigilPreferences.Appearance.light.colorScheme, .light)
        XCTAssertEqual(VigilPreferences.Appearance.dark.colorScheme, .dark)
    }

    func testValuesRoundTripThroughSharedDefaults() {
        let first = VigilPreferences(defaults: defaults, environment: [:])
        first.appearance = .dark
        first.usageAlertsEnabled = false
        first.automaticChecksPaused = true
        first.widgetValuesHidden = true
        first.notificationDetailsHidden = true

        let second = VigilPreferences(defaults: defaults, environment: [:])
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertFalse(second.usageAlertsEnabled)
        XCTAssertTrue(second.automaticChecksPaused)
        XCTAssertTrue(second.widgetValuesHidden)
        XCTAssertTrue(second.notificationDetailsHidden)
    }

    func testInvalidStoredTypesFallBackSafely() {
        defaults.set("neon", forKey: "prefs.appearance")
        defaults.set("yes", forKey: "prefs.usageAlertsEnabled")
        defaults.set(1, forKey: "prefs.automaticChecksPaused")
        defaults.set(["hidden"], forKey: "prefs.widgetValuesHidden")
        defaults.set("private", forKey: "prefs.notificationDetailsHidden")

        let preferences = VigilPreferences(defaults: defaults, environment: [:])
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertTrue(preferences.usageAlertsEnabled)
        XCTAssertFalse(preferences.automaticChecksPaused)
        XCTAssertFalse(preferences.widgetValuesHidden)
        XCTAssertFalse(preferences.notificationDetailsHidden)
    }

    #if DEBUG
    func testScreenshotAppearanceOverrideDoesNotRewriteStoredChoice() {
        defaults.set("light", forKey: "prefs.appearance")

        let overridden = VigilPreferences(
            defaults: defaults,
            environment: ["VIGIL_APPEARANCE": "dark"]
        )

        XCTAssertEqual(overridden.appearance, .dark)
        XCTAssertEqual(defaults.string(forKey: "prefs.appearance"), "light")
    }
    #endif
}

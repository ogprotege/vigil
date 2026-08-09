import Foundation
import Observation
import SwiftUI

/// User-adjustable behavior shared by the app and widget. Callers provide the
/// UserDefaults suite so tests remain isolated and both production processes
/// can use the App Group without teaching VigilKit about UI preferences.
@Observable
final class VigilPreferences {
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    private enum Keys {
        static let appearance = "prefs.appearance"
        static let usageAlertsEnabled = "prefs.usageAlertsEnabled"
        static let automaticChecksPaused = "prefs.automaticChecksPaused"
        static let widgetValuesHidden = "prefs.widgetValuesHidden"
        static let notificationDetailsHidden = "prefs.notificationDetailsHidden"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var usageAlertsEnabled: Bool {
        didSet { defaults.set(usageAlertsEnabled, forKey: Keys.usageAlertsEnabled) }
    }

    /// Stops timer, background-task, and widget fetches. User-initiated
    /// refreshes and account verification remain available.
    var automaticChecksPaused: Bool {
        didSet { defaults.set(automaticChecksPaused, forKey: Keys.automaticChecksPaused) }
    }

    var widgetValuesHidden: Bool {
        didSet { defaults.set(widgetValuesHidden, forKey: Keys.widgetValuesHidden) }
    }

    var notificationDetailsHidden: Bool {
        didSet {
            defaults.set(notificationDetailsHidden, forKey: Keys.notificationDetailsHidden)
        }
    }

    init(
        defaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        let storedAppearance = Appearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        #if DEBUG
        // Deterministic App Store and UI-test captures without mutating the
        // user's saved choice. Release builds never honor environment input.
        self.appearance = Appearance(
            rawValue: environment["VIGIL_APPEARANCE"] ?? ""
        ) ?? storedAppearance
        #else
        self.appearance = storedAppearance
        #endif
        self.usageAlertsEnabled = Self.bool(
            defaults,
            key: Keys.usageAlertsEnabled,
            fallback: true
        )
        self.automaticChecksPaused = Self.bool(
            defaults,
            key: Keys.automaticChecksPaused,
            fallback: false
        )
        self.widgetValuesHidden = Self.bool(
            defaults,
            key: Keys.widgetValuesHidden,
            fallback: false
        )
        self.notificationDetailsHidden = Self.bool(
            defaults,
            key: Keys.notificationDetailsHidden,
            fallback: false
        )
    }

    private static func bool(
        _ defaults: UserDefaults,
        key: String,
        fallback: Bool
    ) -> Bool {
        guard let stored = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(stored) == CFBooleanGetTypeID()
        else { return fallback }
        return stored.boolValue
    }
}

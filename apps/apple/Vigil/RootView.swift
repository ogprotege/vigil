import SwiftUI

enum VigilLaunchDestination: String {
    case home
    case connections
    case settings
}

enum VigilLaunchConfiguration {
    static func destination(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VigilLaunchDestination {
        #if DEBUG
        let raw = environment["VIGIL_TAB"] ?? "home"
        if raw == "limits" { return .home }
        return VigilLaunchDestination(rawValue: raw) ?? .home
        #else
        return .home
        #endif
    }
}

struct RootView: View {
    /// `VIGIL_TAB` remains a deterministic UI-test and screenshot hook for
    /// shipping destinations. Production always launches Home.
    private let launchDestination = VigilLaunchConfiguration.destination()

    var body: some View {
        NavigationStack {
            launchView
        }
        .tint(VigilPalette.signal)
    }

    @ViewBuilder
    private var launchView: some View {
        switch launchDestination {
        case .home:
            DashboardView()
        case .connections:
            ConnectionsView()
        case .settings:
            SettingsView()
        }
    }
}

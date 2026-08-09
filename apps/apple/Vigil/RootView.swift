import SwiftUI

private enum VigilLaunchDestination: String {
    case home
    case connections
    case settings
}

struct RootView: View {
    /// `VIGIL_TAB` remains a deterministic UI-test and screenshot hook for
    /// shipping destinations. Production always launches Home.
    private let launchDestination: VigilLaunchDestination = {
        let raw = ProcessInfo.processInfo.environment["VIGIL_TAB"] ?? "home"
        if raw == "limits" { return .home }
        return VigilLaunchDestination(rawValue: raw) ?? .home
    }()

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

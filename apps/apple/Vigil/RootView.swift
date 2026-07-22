import SwiftUI

private enum VigilDestination: String {
    case home
    case models
    case connections
    case settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .models: return "Models"
        case .connections: return "Connections"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .models: return "cpu"
        case .connections: return "link"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    /// Default `.home`; the `VIGIL_TAB` launch environment can preselect a
    /// tab so screenshot tooling captures a specific screen deterministically.
    /// Accept legacy `limits` as an alias for `home`.
    @State private var selection: VigilDestination = {
        let raw = ProcessInfo.processInfo.environment["VIGIL_TAB"] ?? ""
        if raw == "limits" { return .home }
        return VigilDestination(rawValue: raw) ?? .home
    }()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label(VigilDestination.home.title, systemImage: VigilDestination.home.symbol)
            }
            .tag(VigilDestination.home)

            NavigationStack {
                ModelsView()
            }
            .tabItem {
                Label(VigilDestination.models.title, systemImage: VigilDestination.models.symbol)
            }
            .tag(VigilDestination.models)

            NavigationStack {
                ConnectionsView()
            }
            .tabItem {
                Label(
                    VigilDestination.connections.title,
                    systemImage: VigilDestination.connections.symbol
                )
            }
            .tag(VigilDestination.connections)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(
                    VigilDestination.settings.title,
                    systemImage: VigilDestination.settings.symbol
                )
            }
            .tag(VigilDestination.settings)
        }
        .tint(VigilPalette.signal)
    }
}

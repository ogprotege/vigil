import SwiftUI

private enum VigilDestination: String, CaseIterable, Identifiable {
    case limits
    case models
    case connections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .limits: return "Limits"
        case .models: return "Models"
        case .connections: return "Connections"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .limits: return "scope"
        case .models: return "cpu"
        case .connections: return "link"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    #if os(macOS)
    @State private var selection: VigilDestination? = .limits
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(VigilPalette.signal)
                        .frame(width: 36, height: 36)
                        .background(
                            VigilPalette.signal.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Vigil")
                            .font(.headline)
                            .foregroundStyle(VigilPalette.ink)
                        Text("The night watch")
                            .font(.caption2)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }
                    Spacer()
                }
                .padding(14)

                List(VigilDestination.allCases, selection: $selection) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .tag(destination)
                        .font(.body.weight(selection == destination ? .semibold : .regular))
                        .foregroundStyle(VigilPalette.ink)
                        .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
                .background(VigilPalette.canvas)
                .tint(VigilPalette.signal)
            }
            .background(VigilPalette.canvas)
            .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 240)
        } detail: {
            NavigationStack {
                destinationView(selection ?? .limits)
            }
        }
        .navigationSplitViewStyle(.balanced)
        #else
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label(VigilDestination.limits.title, systemImage: VigilDestination.limits.symbol)
            }

            NavigationStack {
                ModelsView()
            }
            .tabItem {
                Label(VigilDestination.models.title, systemImage: VigilDestination.models.symbol)
            }

            NavigationStack {
                ConnectionsView()
            }
            .tabItem {
                Label(
                    VigilDestination.connections.title,
                    systemImage: VigilDestination.connections.symbol
                )
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(
                    VigilDestination.settings.title,
                    systemImage: VigilDestination.settings.symbol
                )
            }
        }
        .tint(VigilPalette.signal)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func destinationView(_ destination: VigilDestination) -> some View {
        switch destination {
        case .limits:
            DashboardView()
        case .models:
            ModelsView()
        case .connections:
            ConnectionsView()
        case .settings:
            SettingsView()
        }
    }
    #endif
}

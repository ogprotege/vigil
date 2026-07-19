import SwiftUI
import VigilKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.accounts) { account in
                    AccountCardView(
                        account: account,
                        snapshot: model.snapshots[account.key],
                        nextAllowed: model.nextAllowed[account.key],
                        relink: { showAddAccount = true }
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Vigil")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        .refreshable {
            // Ledger-gated: a pull inside the budget is a no-op and the card
            // footer keeps showing "Updated X ago · next check at HH:mm".
            await model.refreshAll(surface: "pull")
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView()
        }
        .overlay {
            if !model.hasAccounts {
                EmptyDashboardView(addAccount: { showAddAccount = true })
            }
        }
        .alert(
            "Vigil couldn't save data",
            isPresented: Binding(
                get: { model.storageErrorMessage != nil },
                set: { if !$0 { model.dismissStorageError() } }
            )
        ) {
            // The binding setter advances the durable-error queue exactly
            // once when SwiftUI dismisses the alert.
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.storageErrorMessage ?? "")
        }
    }
}

struct EmptyDashboardView: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No accounts linked")
                .font(.title2.weight(.semibold))
            Text("Link a supported AI account to monitor rate windows, spend, or remaining balances.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: addAccount) {
                Label("Add Account", systemImage: "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

#Preview {
    NavigationStack {
        DashboardView()
    }
    .environment(AppModel(vault: InMemoryCredentialsStore(), directory: FileManager.default.temporaryDirectory))
}

import SwiftUI
import VigilKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var accountPendingRemoval: AccountRef?
    @State private var removalError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Accounts") {
                if model.accounts.isEmpty {
                    Text("No accounts linked.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack(spacing: 6) {
                                    Text(account.displayName)
                                    if ProviderPresentation.isExperimental(providerId: account.providerId) {
                                        ExperimentalBadge()
                                    }
                                }
                                if let label = account.label {
                                    Text(label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                accountPendingRemoval = account
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                Toggle("Require Face ID / Touch ID", isOn: Binding(
                    get: { model.lockEnabled },
                    set: { model.lockEnabled = $0 }
                ))
            } header: {
                Text("Security")
            } footer: {
                Text("Locks Vigil behind device-owner authentication whenever it returns to the foreground.")
            }

            Section("Privacy") {
                NavigationLink("How Vigil handles your data") {
                    PrivacyView()
                }
            }

            #if DEBUG
            Section("Debug") {
                Button("Simulate 79% → 81% (fires 80% notification)") {
                    Task { await simulateThresholdCrossing() }
                }
                .disabled(model.accounts.isEmpty)
            }
            #endif

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Polling floor", value: "5 min + jitter (provider contract)")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.displayName ?? "account")?",
            isPresented: .init(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) {
                if let account = accountPendingRemoval {
                    do {
                        try model.removeAccount(account)
                    } catch {
                        removalError = error.localizedDescription
                    }
                }
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: {
            Text("Deletes its credentials from the Keychain on this device. Re-adding will prompt a fresh link.")
        }
        .alert(
            "Account removal needs attention",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    #if DEBUG
    /// mac-checklist §M6 step 15: prove the notification pipeline end to end
    /// without waiting for real usage to cross 80%.
    private func simulateThresholdCrossing() async {
        guard let account = model.accounts.first else { return }
        let before = ProviderSnapshot(
            providerId: account.providerId, accountKey: account.key,
            accountLabel: account.label, planLabel: account.plan,
            fetchedAt: Date().addingTimeInterval(-60), status: .ok,
            windows: [UsageWindow(id: "session", utilization: 79, resetsAt: Date().addingTimeInterval(3600), windowSeconds: 18_000, secondary: false)]
        )
        let after = ProviderSnapshot(
            providerId: account.providerId, accountKey: account.key,
            accountLabel: account.label, planLabel: account.plan,
            fetchedAt: Date(), status: .ok,
            windows: [UsageWindow(id: "session", utilization: 81, resetsAt: Date().addingTimeInterval(3600), windowSeconds: 18_000, secondary: false)]
        )
        let events = ThresholdEngine.crossings(previous: before, current: after)
        await model.notifications.requestAuthorizationIfNeeded()
        _ = await model.notifications.deliver(events: events, account: account)
    }
    #endif
}

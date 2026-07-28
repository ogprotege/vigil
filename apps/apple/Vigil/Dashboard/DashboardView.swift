import SwiftUI
import VigilKit

/// Vigil's recurring job: rank linked accounts by required action, then show
/// one real provider value with its reset and freshness. Complete data belongs
/// in AccountDetailView.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var activeSetup: SetupRoute?
    @State private var isRefreshing = false
    @State private var refreshNotice: String?

    private var summaries: [AccountLimitSummary] {
        AccountLimitSummary.ranked(
            accounts: model.accounts,
            snapshots: model.snapshots,
            nextAllowed: model.nextAllowed
        )
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                if model.hasAccounts {
                    connectedContent
                } else {
                    firstRunContent
                }
            }
            .refreshable {
                if model.hasAccounts { await refresh() }
            }
        }
        .navigationTitle(model.hasAccounts ? "Limits" : "Vigil")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { connectedToolbar }
        .sheet(item: $activeSetup) { route in
            AddAccountView(initialRoute: route)
        }
        .task { model.startForegroundTimer() }
        .alert(
            "Vigil couldn't save data",
            isPresented: Binding(
                get: {
                    model.storageErrorMessage != nil
                        && !AppStorageNoticeLaunchConfiguration.suppressesForUITesting()
                },
                set: { if !$0 { model.dismissStorageError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.storageErrorMessage ?? "")
        }
    }

    private var firstRunContent: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.large) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Set up Vigil")
                    .font(
                        dynamicTypeSize.isAccessibilitySize
                            ? .title2.weight(.bold)
                            : .largeTitle.weight(.bold)
                    )
                    .foregroundStyle(VigilPalette.ink)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Connect an account to see its current limits, reset times, balances, and on-device observations.")
                        .font(.body)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 12) {
                Button { activeSetup = .claude } label: {
                    SetupChoiceRow(
                        symbol: "sparkles",
                        title: "Connect Claude",
                        detail: "Sign in through Claude and keep the connection renewable.",
                        tone: .primary
                    )
                }
                .accessibilityIdentifier("vigil.setup.claude")
                Button { activeSetup = .codex } label: {
                    SetupChoiceRow(
                        symbol: "terminal",
                        title: "Connect ChatGPT / Codex",
                        detail: "Use OpenAI's device authorization on this iPhone."
                    )
                }
                .accessibilityIdentifier("vigil.setup.codex")
                Button { activeSetup = .other } label: {
                    SetupChoiceRow(
                        symbol: "key.horizontal",
                        title: "Other provider",
                        detail: "Choose a provider and enter its API key or token.",
                        tone: .quiet
                    )
                }
                .accessibilityIdentifier("vigil.setup.other")
            }
            .buttonStyle(.plain)

            Label(
                "Credentials stay in this iPhone's Keychain. There is no Vigil account or analytics service.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, VigilSpacing.small)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(VigilSpacing.medium)
        .padding(.top, VigilSpacing.medium)
        .padding(.bottom, VigilSpacing.xLarge)
        .frame(maxWidth: .infinity)
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs attention first")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(VigilPalette.ink)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Each account shows its tightest current limit or its most useful provider value.")
                        .font(.subheadline)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let refreshNotice {
                StatusBannerView(
                    icon: "arrow.clockwise",
                    tint: VigilPalette.signal,
                    text: refreshNotice
                )
            }

            LazyVStack(spacing: 12) {
                ForEach(summaries) { summary in
                    NavigationLink {
                        AccountDetailView(
                            account: summary.account,
                            snapshot: summary.snapshot,
                            nextAllowed: summary.nextAllowed
                        )
                    } label: {
                        AccountLimitSummaryCard(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "vigil.home.account.\(summary.account.providerId)"
                    )
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(VigilSpacing.medium)
        .padding(.bottom, VigilSpacing.xLarge)
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var connectedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.hasAccounts {
                Button { Task { await refresh() } } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh limits", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)

                NavigationLink {
                    ConnectionsView()
                } label: {
                    Label("Accounts", systemImage: "person.2")
                }
            }

            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let report = await model.refreshAll(surface: "pull", bypassPollFloor: true)
        refreshNotice = report.userMessage
        isRefreshing = false

        Task {
            try? await Task.sleep(for: .seconds(5))
            if refreshNotice == report.userMessage { refreshNotice = nil }
        }
    }
}

#Preview {
    NavigationStack { DashboardView() }
        .environment(
            AppModel(
                vault: InMemoryCredentialsStore(),
                directory: FileManager.default.temporaryDirectory
            )
        )
}

import SwiftUI
import VigilKit

/// Home / Limits — token-monitor style: period picker, hero summary, LIMITS
/// section with a one-tap refresh, then compact per-provider cards with dual
/// session/weekly bars. Vigil's night-watch palette stays.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var isRefreshing = false

    private var hero: PeriodHeroSummary {
        PeriodHero.summary(
            period: model.selectedPeriod,
            accounts: model.accounts,
            snapshots: model.snapshots,
            observations: model.observations
        )
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    periodPicker
                    heroBlock

                    if model.hasAccounts {
                        limitsSection
                    } else {
                        EmptyDashboardView(addAccount: { showAddAccount = true })
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, VigilSpacing.medium)
                .padding(.top, VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await refresh()
            }
        }
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView()
        }
        .task {
            model.startForegroundTimer()
        }
        .alert(
            "Vigil couldn't save data",
            isPresented: Binding(
                get: { model.storageErrorMessage != nil },
                set: { if !$0 { model.dismissStorageError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.storageErrorMessage ?? "")
        }
    }

    private var periodPicker: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("Period", selection: Binding(
                get: { model.selectedPeriod },
                set: { model.selectedPeriod = $0 }
            )) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .accessibilityLabel("Usage period")
        }
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hero.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(VigilPalette.inkMuted)
                .tracking(0.6)
            Text(hero.primaryValue)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(VigilPalette.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let secondary = hero.secondaryValue {
                Text(secondary)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(VigilPalette.inkMuted)
            }
            Text(hero.detail)
                .font(.caption)
                .foregroundStyle(VigilPalette.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(alignment: .center) {
                Text("LIMITS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(VigilPalette.inkMuted)
                    .tracking(1.0)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(VigilPalette.signal)
                            .frame(width: 32, height: 32)
                            .background(
                                VigilPalette.signal.opacity(0.12),
                                in: Circle()
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh limits")
                .accessibilityHint("Fetches each provider when the shared poll floor allows")
            }

            VStack(spacing: VigilSpacing.medium) {
                ForEach(model.accounts) { account in
                    ProviderHomeCard(
                        account: account,
                        snapshot: model.snapshots[account.key],
                        nextAllowed: model.nextAllowed[account.key],
                        period: model.selectedPeriod,
                        relink: { showAddAccount = true }
                    )
                }
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshAll(surface: "pull")
        isRefreshing = false
    }
}

/// Compact token-monitor-style provider card: icon + name + updated, then
/// Session / Weekly (and Month when present) as dual progress columns.
struct ProviderHomeCard: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let period: UsagePeriod
    let relink: () -> Void

    private var displayWindows: [UsageWindow] {
        guard let snapshot else { return [] }
        let filtered = period.filteredWindows(snapshot.windows)
        // Prefer at most three primary-ish bars for the dual-column layout.
        let primary = filtered.filter { !UsagePresentation.isSpecialWindow($0) }
        let special = filtered.filter(UsagePresentation.isSpecialWindow)
        if primary.isEmpty { return Array(special.prefix(3)) }
        return Array((primary + special).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            header
            if let snapshot {
                statusBanner(snapshot)
            }

            if !displayWindows.isEmpty {
                windowGrid
            } else if let snapshot, !snapshot.metrics.isEmpty {
                metricsStrip(snapshot.metrics.filter { !$0.secondary })
            } else if snapshot == nil {
                Text("Waiting for first check")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
        .padding(VigilSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VigilPalette.surface.opacity(0.96),
            in: RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
                .stroke(VigilPalette.border.opacity(0.6), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VigilProviderMark(
                providerId: account.providerId,
                displayName: account.displayName,
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(1)
                    if ProviderPresentation.isExperimental(providerId: account.providerId) {
                        ExperimentalBadge()
                    }
                    if let plan = snapshot?.planLabel ?? account.plan, !plan.isEmpty {
                        Text(plan.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(VigilPalette.signal)
                    }
                }
                if let label = account.label, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(VigilPalette.inkFaint)
                        .lineLimit(1)
                }
                updatedLine
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var updatedLine: some View {
        if let snapshot, snapshot.fetchedAt > .distantPast {
            HStack(spacing: 4) {
                Text("Updated")
                Text(snapshot.fetchedAt, style: .relative)
                Text("ago")
                if let nextAllowed, nextAllowed > .now {
                    Text("· next \(nextAllowed.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(Staleness.tint(for: snapshot.fetchedAt))
        } else {
            Text("No successful update yet")
                .font(.caption2)
                .foregroundStyle(VigilPalette.inkFaint)
        }
    }

    @ViewBuilder
    private func statusBanner(_ snapshot: ProviderSnapshot) -> some View {
        switch snapshot.status {
        case .ok:
            EmptyView()
        case .rateLimited:
            StatusBannerView(
                icon: "hourglass",
                tint: VigilPalette.caution,
                text: nextAllowed.map {
                    "Cooldown · next check \($0.formatted(date: .omitted, time: .shortened))"
                } ?? "Provider cooldown"
            )
        case .authExpired:
            HStack {
                StatusBannerView(
                    icon: "key.slash",
                    tint: VigilPalette.critical,
                    text: "Sign-in expired."
                )
                Button("Re-link", action: relink)
                    .buttonStyle(.borderedProminent)
                    .tint(VigilPalette.signal)
                    .controlSize(.small)
            }
        case .schemaChanged:
            StatusBannerView(
                icon: "exclamationmark.triangle",
                tint: VigilPalette.critical,
                text: "Provider response changed — update Vigil."
            )
        case .network:
            StatusBannerView(
                icon: "wifi.slash",
                tint: VigilPalette.inkMuted,
                text: snapshot.windows.isEmpty
                    ? "Not reached yet."
                    : "Offline · last known values."
            )
        }
    }

    private var windowGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(displayWindows, id: \.id) { window in
                CompactLimitCell(window: window)
            }
        }
    }

    private func metricsStrip(_ metrics: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metrics.prefix(3), id: \.id) { metric in
                HStack {
                    Text(metric.label)
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                    Spacer()
                    Text(MetricFormat.value(metric))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(VigilPalette.ink)
                }
            }
        }
    }
}

/// One Session / Weekly cell: label, % left, bar, reset — token-monitor style.
struct CompactLimitCell: View {
    let window: UsageWindow

    private var remaining: Double {
        UsagePresentation.remainingPercent(for: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(shortTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VigilPalette.inkMuted)
                Spacer(minLength: 4)
                Text("\(Int(remaining.rounded()))% left")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(UsageTint.color(for: window.utilization))
            }
            LimitReservoirBar(
                remaining: remaining,
                tint: UsageTint.color(for: window.utilization)
            )
            CompactResetLabel(resetsAt: window.resetsAt)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(UsagePresentation.title(for: window)))
        .accessibilityValue(Text("\(Int(remaining.rounded())) percent left"))
    }

    private var shortTitle: String {
        let title = UsagePresentation.compactTitle(for: window)
        // Token-monitor uses "Session" / "Weekly" / "Monthly".
        if title.lowercased().contains("hour") || title.lowercased().hasPrefix("session") {
            return "Session"
        }
        if title.lowercased().hasPrefix("weekly") { return "Weekly" }
        if title.lowercased().hasPrefix("monthly") { return "Monthly" }
        return title
    }
}

struct CompactResetLabel: View {
    let resetsAt: Date?

    var body: some View {
        Group {
            if let resetsAt {
                if resetsAt > Date() {
                    HStack(spacing: 3) {
                        Text("Reset")
                        Text(resetsAt, style: .relative)
                    }
                } else {
                    Text("Reset due")
                }
            } else {
                Text("No reset")
            }
        }
        .font(.caption2)
        .foregroundStyle(VigilPalette.inkFaint)
    }
}

#Preview {
    NavigationStack {
        DashboardView()
    }
    .environment(
        AppModel(
            vault: InMemoryCredentialsStore(),
            directory: FileManager.default.temporaryDirectory
        )
    )
}

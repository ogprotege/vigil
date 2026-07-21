import SwiftUI
import VigilKit

/// Home / Limits — matched to token-monitor's Limits view: period picker,
/// hero, a single provider list with stacked Session/Weekly/model bars, and a
/// bottom-trailing refresh control (the circled button in your screenshot).
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var isRefreshing = false
    @State private var refreshNotice: String?

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
                    if let refreshNotice {
                        Text(refreshNotice)
                            .font(.caption)
                            .foregroundStyle(VigilPalette.inkMuted)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                VigilPalette.signal.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: VigilRadius.small)
                            )
                            .accessibilityLabel(refreshNotice)
                    }

                    if model.hasAccounts {
                        providerList
                    } else {
                        EmptyDashboardView(addAccount: { showAddAccount = true })
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, VigilSpacing.medium)
                .padding(.top, VigilSpacing.medium)
                .padding(.bottom, 72)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await refresh()
            }

            if model.hasAccounts {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        refreshFab
                    }
                    .padding(.trailing, VigilSpacing.medium)
                    .padding(.bottom, VigilSpacing.medium)
                }
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

    /// The circled control from token-monitor: always available, bottom-trailing.
    private var refreshFab: some View {
        Button {
            Task { await refresh() }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VigilPalette.ink)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                }
            }
            .frame(width: 44, height: 44)
            .background(VigilPalette.surfaceRaised.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(VigilPalette.border.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh limits")
        .accessibilityHint("Fetches each provider when the shared poll floor allows")
    }

    private var periodPicker: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("Period", selection: Binding(
                get: { model.selectedPeriod },
                set: { model.selectedPeriod = $0 }
            )) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title.uppercased()).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .accessibilityLabel("Usage period")
        }
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hero.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(VigilPalette.inkMuted)
                .tracking(0.8)
            Text(hero.primaryValue)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(VigilPalette.ink)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
            if let secondary = hero.secondaryValue {
                Text(secondary)
                    .font(.title3)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
            Text(hero.detail)
                .font(.caption)
                .foregroundStyle(VigilPalette.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One continuous panel — providers separated by hairlines, like token-monitor.
    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Divider().overlay(VigilPalette.ink.opacity(0.10))
                }
                ProviderHomeRow(
                    account: account,
                    snapshot: model.snapshots[account.key],
                    nextAllowed: model.nextAllowed[account.key],
                    period: model.selectedPeriod,
                    connectionLabel: model.connectionLabel(for: account),
                    relink: { showAddAccount = true }
                )
            }
        }
        .padding(.vertical, 4)
        .background(
            VigilPalette.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
                .stroke(VigilPalette.border.opacity(0.55), lineWidth: 1)
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let report = await model.refreshAll(surface: "pull")
        refreshNotice = report.userMessage
        isRefreshing = false
        // Clear the notice after it has been readable — keep the rows' own
        // "Updated / next check" lines as the durable truth.
        Task {
            try? await Task.sleep(for: .seconds(5))
            if refreshNotice == report.userMessage {
                refreshNotice = nil
            }
        }
    }
}

/// One provider block inside the shared list — matches token-monitor rows:
/// icon + name + plan on the right, "Updated · OAuth/API", then full-width
/// Session / Weekly / model bars stacked with % left and reset.
struct ProviderHomeRow: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let period: UsagePeriod
    let connectionLabel: String
    let relink: () -> Void

    private var displayWindows: [UsageWindow] {
        guard let snapshot else { return [] }
        let filtered = period.filteredWindows(snapshot.windows)
        let primary = filtered.filter { !UsagePresentation.isSpecialWindow($0) }
        let special = filtered.filter(UsagePresentation.isSpecialWindow)
        // Show primary first, then model caps (Fable, Opus, …) — up to 5 bars.
        if primary.isEmpty { return Array(special.prefix(5)) }
        return Array((primary + special).prefix(5))
    }

    private var planLabel: String? {
        let raw = snapshot?.planLabel ?? account.plan
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot {
                statusBanner(snapshot)
            }

            if !displayWindows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(displayWindows, id: \.id) { window in
                        StackedLimitBar(window: window)
                    }
                }
            } else if let snapshot, !snapshot.metrics.isEmpty {
                metricsStrip(snapshot.metrics)
            } else if snapshot == nil {
                Text("Waiting for first check")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
        .padding(.horizontal, VigilSpacing.medium)
        .padding(.vertical, VigilSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VigilProviderMark(
                providerId: account.providerId,
                displayName: account.displayName,
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(account.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(1)
                    if ProviderPresentation.isExperimental(providerId: account.providerId) {
                        ExperimentalBadge()
                    }
                    Spacer(minLength: 4)
                    if let planLabel {
                        Text(planLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(VigilPalette.inkMuted)
                            .lineLimit(1)
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
        }
    }

    @ViewBuilder
    private var updatedLine: some View {
        HStack(spacing: 4) {
            if let snapshot, snapshot.fetchedAt > .distantPast {
                Text("Updated")
                Text(snapshot.fetchedAt, style: .relative)
                Text("ago")
            } else {
                Text("No update yet")
            }
            Text("·")
            Text(connectionLabel)
            if let nextAllowed, nextAllowed > .now {
                Text("· next \(nextAllowed.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(
            snapshot.map { Staleness.tint(for: $0.fetchedAt) } ?? VigilPalette.inkFaint
        )
        // Sibling Texts in a stack are separate accessibility elements, so this
        // line was six VoiceOver stops per account — including a bare "middle
        // dot". AccountCardView.footer already combines its equivalent.
        .accessibilityElement(children: .combine)
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
                // Metric-only providers (OpenRouter, DeepSeek, Moonshot,
                // OpenAI, GitHub, xAI, Cursor) never report windows, so testing
                // windows alone claimed "Not reached yet" while the preserved
                // balance was rendered directly below this banner.
                text: snapshot.windows.isEmpty && snapshot.metrics.isEmpty
                    ? "Not reached yet."
                    : "Offline · last known values."
            )
        }
    }

    private func metricsStrip(_ metrics: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metrics.filter { !$0.secondary }.prefix(4), id: \.id) { metric in
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
            // Secondary details like Cursor credits / DeepSeek spend sit quieter.
            ForEach(metrics.filter(\.secondary).prefix(2), id: \.id) { metric in
                HStack {
                    Text(metric.label)
                        .font(.caption2)
                        .foregroundStyle(VigilPalette.inkFaint)
                    Spacer()
                    Text(MetricFormat.value(metric))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
        }
    }
}

/// Full-width Session / Weekly / Fable bar — token-monitor Limits row.
struct StackedLimitBar: View {
    let window: UsageWindow

    private var remaining: Double {
        UsagePresentation.remainingPercent(for: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(barTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VigilPalette.inkMuted)
                Spacer(minLength: 8)
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
        // An explicit label/value replaces the combined children, which drops
        // the CompactResetLabel above. Home is the default screen and this is
        // its only meter, so without the hint the reset countdown — a core
        // honest-freshness value — was unreachable to VoiceOver on the screen
        // users actually open. Matches LimitWindowView / LimitMeterRow.
        .accessibilityHint(accessibilityCountdown(window.resetsAt))
    }

    /// Prefer short labels: Session, Weekly, Fable, Opus — like the screenshot.
    private var barTitle: String {
        let id = window.id.lowercased()
        if id == "session" || id.hasPrefix("session_") {
            if id.contains("video") { return "Video session" }
            if let seconds = window.windowSeconds, seconds == 18_000 {
                return "5-hour"
            }
            return "Session"
        }
        if id == "weekly" { return "Weekly" }
        if id.hasPrefix("weekly_scoped"), let label = window.label {
            return label
        }
        if id == "weekly_opus" { return "Opus" }
        if id == "weekly_sonnet" { return "Sonnet" }
        if id == "weekly_video" { return "Video weekly" }
        if id == "monthly" { return "Monthly" }
        if id == "plan" { return "Total" }
        if id == "billing" { return "Billing" }
        return UsagePresentation.compactTitle(for: window)
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

/// First-run state — shown on Home until the first account is connected.
struct EmptyDashboardView: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.large) {
            HStack(spacing: 14) {
                Image(systemName: "scope")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VigilPalette.signal)
                    .frame(width: 58, height: 58)
                    .background(VigilPalette.signal.opacity(0.11), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text("The watch is quiet.")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                    Text("Sign in with Claude or Codex, or paste a provider key. Vigil keeps credentials on this device.")
                        .font(.subheadline)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: addAccount) {
                Label("Add an account", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("No Vigil account, cloud sync, or analytics.")
            }
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .vigilCard(padding: VigilSpacing.large)
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

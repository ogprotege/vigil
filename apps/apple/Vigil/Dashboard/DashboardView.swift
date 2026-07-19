import SwiftUI
import VigilKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var isRefreshing = false

    private var watchline: LimitCandidate? {
        UsagePresentation.closestLimit(
            accounts: model.accounts,
            snapshots: model.snapshots
        )
    }

    private var watchlineCoverage: WatchlineCoverage {
        UsagePresentation.watchlineCoverage(
            accounts: model.accounts,
            snapshots: model.snapshots
        )
    }

    private var watchlineAccountTitle: String? {
        guard let watchline else { return nil }
        let sameProviderCount = model.accounts.filter {
            $0.providerId == watchline.account.providerId
        }.count
        return sameProviderCount > 1
            ? UsagePresentation.accountTitle(watchline.account)
            : watchline.account.displayName
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    dashboardHeader

                    if model.hasAccounts {
                        WatchlineView(
                            candidate: watchline,
                            coverage: watchlineCoverage,
                            accountTitle: watchlineAccountTitle
                        )

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 350, maximum: 560), spacing: 16)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            ForEach(model.accounts) { account in
                                AccountCardView(
                                    account: account,
                                    snapshot: model.snapshots[account.key],
                                    nextAllowed: model.nextAllowed[account.key],
                                    relink: { showAddAccount = true }
                                )
                            }
                        }
                    } else {
                        EmptyDashboardView(addAccount: { showAddAccount = true })
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, VigilSpacing.medium)
                .padding(.top, VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await refresh()
            }
        }
        .navigationTitle("Limits")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing accounts")
                    } else {
                        Label("Refresh accounts", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || !model.hasAccounts)

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

    private var dashboardHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                VigilEyebrow(text: "The night watch")
                Text("Know what runs out next.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(VigilPalette.ink)
                Text(
                    model.hasAccounts
                        ? "\(model.accounts.count) connected account\(model.accounts.count == 1 ? "" : "s") · provider-safe refresh"
                        : "Link an account to start watching its limits."
                )
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
            }
            Spacer()
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshAll(surface: "pull")
        isRefreshing = false
    }
}

/// The signature "Watchline": one stable, high-signal answer to the dashboard's
/// central question. Account cards stay in linked order; urgency does not make
/// the whole screen jump after a refresh.
struct WatchlineView: View {
    let candidate: LimitCandidate?
    let coverage: WatchlineCoverage
    let accountTitle: String?

    @ScaledMetric(relativeTo: .largeTitle)
    private var percentageSize: CGFloat = 48

    var body: some View {
        Group {
            if let candidate {
                limitWatchline(candidate)
            } else {
                noWindowWatchline
            }
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private func limitWatchline(_ candidate: LimitCandidate) -> some View {
        let remaining = UsagePresentation.remainingPercent(for: candidate.window)
        let degraded = SnapshotFreshness.isDegraded(
            status: candidate.snapshot.status,
            fetchedAt: candidate.snapshot.fetchedAt
        )
        let partial = !coverage.isComplete
        let needsCaution = degraded || partial

        return VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    VigilEyebrow(
                        text: degraded
                            ? "Last known watchline"
                            : partial ? "Partial watchline" : "Watchline"
                    )
                    Text(
                        "\(accountTitle ?? candidate.account.displayName) · "
                            + UsagePresentation.title(for: candidate.window)
                    )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VigilStatusPill(
                    text: degraded
                        ? "May be out of date"
                        : partial ? "Partial coverage" : "Live",
                    color: needsCaution ? VigilPalette.caution : VigilPalette.safe,
                    symbol: degraded
                        ? "clock.badge.exclamationmark"
                        : partial ? "exclamationmark.circle" : nil
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline, spacing: 7) {
                    percentage(remaining, utilization: candidate.window.utilization)
                    Spacer()
                    ResetCountdownView(resetsAt: candidate.window.resetsAt)
                }
                VStack(alignment: .leading, spacing: 8) {
                    percentage(remaining, utilization: candidate.window.utilization)
                    ResetCountdownView(resetsAt: candidate.window.resetsAt)
                }
            }

            LimitReservoirBar(
                remaining: remaining,
                tint: UsageTint.color(for: candidate.window.utilization)
            )

            Text(watchlineDetail(candidateDegraded: degraded))
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func percentage(_ remaining: Double, utilization: Double) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 7) {
            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: percentageSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UsageTint.color(for: utilization))
                .minimumScaleFactor(0.72)
                .lineLimit(1)
            Text("left")
                .font(.headline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private func watchlineDetail(candidateDegraded: Bool) -> String {
        let windowCount = coverage.windowAccountCount
        let metricCount = coverage.metricOnlyAccountCount
        let unreliableCount = coverage.unreliableAccountCount

        if candidateDegraded {
            return "Tightest last-known quota. \(coverageSummary)"
        }
        if unreliableCount > 0 {
            return "Tightest known quota. \(coverageSummary)"
        }
        if metricCount > 0 {
            return "Tightest quota from \(accountPhrase(windowCount, noun: "account")) with reset-based limits. \(accountPhrase(metricCount, noun: "account")) reports scalar values only."
        }
        return "Tightest quota across \(accountPhrase(windowCount, noun: "connected account")) reporting reset-based limits."
    }

    private var coverageSummary: String {
        let linkedCount = coverage.linkedAccountCount
        let linkedNoun = linkedCount == 1 ? "linked account" : "linked accounts"
        let unavailableCount = coverage.unreliableAccountCount
        let unavailableNoun = unavailableCount == 1 ? "linked account" : "linked accounts"
        let windowText = "Based on \(coverage.windowAccountCount) of \(linkedCount) \(linkedNoun) reporting reset-based limits."
        let unavailableText = "Data is stale or unavailable for \(unavailableCount) \(unavailableNoun)."
        if coverage.metricOnlyAccountCount > 0 {
            return "\(windowText) \(accountPhrase(coverage.metricOnlyAccountCount, noun: "account")) reports scalar values only. \(unavailableText)"
        }
        return "\(windowText) \(unavailableText)"
    }

    private func accountPhrase(_ count: Int, noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private var noWindowWatchline: some View {
        HStack(spacing: 14) {
            Image(
                systemName: coverage.metricOnlyAccountCount > 0
                    ? "chart.bar.doc.horizontal"
                    : "scope"
            )
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VigilPalette.signal)
                .frame(width: 52, height: 52)
                .background(VigilPalette.signal.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                VigilEyebrow(text: "Watchline")
                Text(
                    coverage.metricOnlyAccountCount > 0
                        ? "No reset-based limits reported"
                        : "Waiting for quota data"
                )
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text(noWindowDetail)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
    }

    private var noWindowDetail: String {
        if coverage.metricOnlyAccountCount > 0 {
            let metrics = accountPhrase(
                coverage.metricOnlyAccountCount,
                noun: "connected account"
            )
            if coverage.unreliableAccountCount > 0 {
                return "\(metrics) reports balance or spend values below. \(accountPhrase(coverage.unreliableAccountCount, noun: "account")) is still stale or unavailable."
            }
            return "\(metrics) reports balance or spend values below without a provider-supplied reset window."
        }
        return "Your connected accounts will appear below while Vigil waits for the first safe check."
    }
}

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
                    Text("Pair a computer or add a provider key. Vigil keeps credentials on this device.")
                        .font(.subheadline)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: addAccount) {
                Label("Pair or add an account", systemImage: "plus")
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

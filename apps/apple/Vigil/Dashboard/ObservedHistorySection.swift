import SwiftUI
import VigilKit

/// A bounded textual timeline from the protected history store. It keeps
/// device observations and official provider imports visibly distinct and
/// treats a changed reset timestamp as a new segment, never as token history.
struct ObservedHistorySection: View {
    let account: AccountRef
    let samples: [UsageHistorySample]
    let observedSummary: UsageHistorySummary?
    let importedSummary: UsageHistorySummary?
    var supportsOfficialImport = false
    var maximumRecentRows = 8

    private var observed: [UsageHistorySample] {
        samples.filter { $0.source == .observed }.sorted { $0.recordedAt < $1.recordedAt }
    }

    private var imported: [UsageHistorySample] {
        samples.filter { $0.source == .providerBackfill }.sorted { $0.recordedAt < $1.recordedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.large) {
            historyPanel(
                title: "Observed by Vigil",
                symbol: "iphone.and.arrow.forward",
                tint: VigilPalette.safe,
                sourceSamples: observed,
                summary: observedSummary,
                emptyText: "History begins after the next successful check.",
                source: .observed
            )

            if supportsOfficialImport
                || (importedSummary?.sampleCount ?? imported.count) > 0 {
                historyPanel(
                    title: "Imported from provider",
                    symbol: "arrow.down.doc",
                    tint: VigilPalette.signal,
                    sourceSamples: imported,
                    summary: importedSummary,
                    emptyText: "No official provider history has been imported.",
                    source: .providerBackfill
                )
            }
        }
    }

    private func historyPanel(
        title: String,
        symbol: String,
        tint: Color,
        sourceSamples: [UsageHistorySample],
        summary: UsageHistorySummary?,
        emptyText: String,
        source: UsageHistorySource
    ) -> some View {
        let count = summary?.sampleCount ?? sourceSamples.count
        let isImported = source == .providerBackfill
        return VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)

            if count == 0 {
                Label(emptyText, systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vigilInsetSurface()
            } else {
                sourceSummary(
                    summary,
                    fallbackSamples: sourceSamples,
                    isImported: isImported
                )
                recentRows(sourceSamples, isImported: isImported)
                if count > min(max(maximumRecentRows, 1), 12) {
                    NavigationLink {
                        RetainedHistoryView(
                            title: title,
                            account: account,
                            source: source,
                            isImported: isImported
                        )
                    } label: {
                        Label(
                            "View all \(count) record\(count == 1 ? "" : "s")",
                            systemImage: "list.bullet.rectangle"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                }
            }

            Text(
                isImported
                    ? "Imports use an official administrative API and retain their provider bucket dates."
                    : "iOS schedules background checks opportunistically, so observed history can contain gaps."
            )
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VigilSpacing.medium)
        .background(
            VigilPalette.surface.opacity(0.97),
            in: RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
    }

    private func sourceSummary(
        _ summary: UsageHistorySummary?,
        fallbackSamples: [UsageHistorySample],
        isImported: Bool
    ) -> some View {
        let count = summary?.sampleCount ?? fallbackSamples.count
        let first = summary?.oldestRecordedAt ?? fallbackSamples.first?.recordedAt
        let last = summary?.newestRecordedAt ?? fallbackSamples.last?.recordedAt
        return VStack(alignment: .leading, spacing: 3) {
            if let first, let last {
                Text(
                    isImported
                        ? "\(count) imported record\(count == 1 ? "" : "s")"
                        : "\(count) retained reading\(count == 1 ? "" : "s")"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
                Text(
                    "\(first.formatted(date: .abbreviated, time: .shortened)) to "
                        + last.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func recentRows(
        _ sourceSamples: [UsageHistorySample],
        isImported: Bool
    ) -> some View {
        let rowCount = min(max(maximumRecentRows, 1), 12)
        let recent = Array(sourceSamples.suffix(rowCount).reversed())
        return VStack(spacing: 0) {
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, sample in
                if index > 0 {
                    Divider().overlay(VigilPalette.border.opacity(0.7))
                }
                HistorySampleRow(
                    sample: sample,
                    segmentNote: isImported ? nil : segmentNote(for: sample, in: sourceSamples)
                )
            }
        }
        .padding(.horizontal, 14)
        .vigilInsetSurface()
    }

    private func segmentNote(
        for sample: UsageHistorySample,
        in orderedSamples: [UsageHistorySample]
    ) -> String? {
        guard let window = tightestWindow(in: sample) else { return nil }
        let earlier = orderedSamples.filter { $0.recordedAt < sample.recordedAt }
        guard let previous = earlier.reversed().compactMap({ candidate in
            candidate.windows.first { $0.id == window.id }
        }).first else {
            return "First observed reset segment"
        }
        return previous.segmentId == window.segmentId
            ? "Same reset segment"
            : "New provider reset segment"
    }
}

/// A lazy, account-scoped archive. The summary panel stays concise, while the
/// complete retained set remains inspectable without forcing thousands of
/// rows into the account detail's main scroll hierarchy.
private struct RetainedHistoryView: View {
    @Environment(AppModel.self) private var model

    let title: String
    let account: AccountRef
    let source: UsageHistorySource
    let isImported: Bool

    @State private var samples: [UsageHistorySample] = []
    @State private var nextCursor: UsageHistoryCursor?
    @State private var didLoad = false
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                ForEach(samples, id: \.id) { sample in
                    HistorySampleRow(sample: sample, segmentNote: nil)
                }

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading history")
                        Spacer()
                    }
                    .frame(minHeight: 52)
                } else if let nextCursor {
                    Button {
                        Task { await loadPage(cursor: nextCursor) }
                    } label: {
                        Label("Load more", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.caution)
                }
            } footer: {
                Text(
                    isImported
                        ? "Provider bucket time and retrieval time remain separate."
                        : "Every row is a successful reading observed by Vigil. Gaps mean iOS did not grant a background check or the provider was unavailable."
                )
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard !didLoad else { return }
            didLoad = true
            await loadPage(cursor: nil)
        }
    }

    private func loadPage(cursor: UsageHistoryCursor?) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let page = try await model.historyPage(
                for: account,
                source: source,
                cursor: cursor
            )
            let existing = Set(samples.map(\.id))
            samples.append(contentsOf: page.samples.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            loadError = "Vigil couldn't read the next history page. Try again."
        }
    }
}

private struct HistorySampleRow: View {
    let sample: UsageHistorySample
    let segmentNote: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) { dateLabels }
                } else {
                    HStack(alignment: .firstTextBaseline) { dateLabels }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: VigilSpacing.small) {
                    Text(primaryValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: VigilSpacing.small)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VigilPalette.signal)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History reading details")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this reading" : "Shows every value in this reading")

            if let segmentNote {
                Label(segmentNote, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(VigilPalette.inkMuted)
            }

            if isExpanded {
                HistorySampleDetails(sample: sample)
                    .padding(.top, VigilSpacing.xSmall)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var dateLabels: some View {
        Text(sample.recordedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption.weight(.semibold))
            .foregroundStyle(VigilPalette.ink)
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
        if let periodEnd = sample.periodEnd {
            Text("to \(periodEnd.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var primaryValue: String {
        if let window = tightestWindow(in: sample) {
            let left = Int((100 - window.utilization).rounded())
            if let remaining = window.remaining, let limit = window.limit {
                if let used = window.used,
                   abs((used / limit * 100) - window.utilization) > 1 {
                    return "\(left)% left · Provider amounts: \(historyNumber(used)) used, \(historyNumber(limit)) limit, \(historyNumber(remaining)) remaining · \(historyWindowTitle(window))"
                }
                return "\(left)% left · \(historyNumber(remaining)) / \(historyNumber(limit)) remaining · \(historyWindowTitle(window))"
            }
            return "\(left)% left · \(historyWindowTitle(window))"
        }
        if let quantity = primaryQuantity(in: sample) {
            return "\(historyNumber(quantity.value)) \(quantity.unit) · \(quantity.label)"
        }
        if let metric = sample.metrics.first(where: { !$0.secondary }) ?? sample.metrics.first {
            return "\(historyMetricValue(metric)) · \(metric.label)"
        }
        return UsagePresentation.statusTitle(sample.status)
    }
}

/// The compact row above identifies the value that needed attention at that
/// moment. This disclosure is the lossless inspection surface: no normalized
/// window, balance, cost, or counted quantity is hidden behind that summary.
private struct HistorySampleDetails: View {
    let sample: UsageHistorySample

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Divider().overlay(VigilPalette.border.opacity(0.7))

            detailSection("Provenance", symbol: "checkmark.shield") {
                HistoryDetailValueRow(label: "Source", value: sample.source.displayLabel)
                HistoryDetailValueRow(
                    label: sample.source == .providerBackfill
                        ? "Provider period starts"
                        : "Observed at",
                    value: historyDate(sample.recordedAt)
                )
                if let periodEnd = sample.periodEnd {
                    HistoryDetailValueRow(
                        label: "Provider period ends",
                        value: historyDate(periodEnd)
                    )
                }
                HistoryDetailValueRow(
                    label: "Retrieved by Vigil",
                    value: historyDate(sample.retrievedAt)
                )
                HistoryDetailValueRow(
                    label: "Reading status",
                    value: UsagePresentation.statusTitle(sample.status)
                )
            }

            ForEach(Array(sample.windows.enumerated()), id: \.offset) { index, window in
                detailSection(
                    historyWindowTitle(window),
                    symbol: "gauge.with.dots.needle.33percent"
                ) {
                    HistoryDetailValueRow(
                        label: "Used percentage",
                        value: historyPercent(window.utilization)
                    )
                    if let used = window.used {
                        HistoryDetailValueRow(
                            label: "Exact used",
                            value: historyNumber(used)
                        )
                    }
                    if let limit = window.limit {
                        HistoryDetailValueRow(
                            label: "Exact limit",
                            value: historyNumber(limit)
                        )
                    }
                    if let remaining = window.remaining {
                        HistoryDetailValueRow(
                            label: "Exact remaining",
                            value: historyNumber(remaining)
                        )
                    }
                    if let resetAt = window.resetAt {
                        HistoryDetailValueRow(
                            label: "Resets",
                            value: historyDate(resetAt)
                        )
                    }
                    if let windowSeconds = window.windowSeconds {
                        HistoryDetailValueRow(
                            label: "Window duration",
                            value: historyDuration(windowSeconds)
                        )
                    }
                    if window.secondary {
                        HistoryDetailValueRow(label: "Scope", value: "Secondary limit")
                    }
                }
                .accessibilityIdentifier("vigil.history.window.\(index)")
            }

            ForEach(Array(sample.quantities.enumerated()), id: \.offset) { index, quantity in
                detailSection(quantity.label, symbol: "number") {
                    HistoryDetailValueRow(
                        label: historyQuantityKindTitle(quantity.kind),
                        value: "\(historyNumber(quantity.value)) \(quantity.unit)"
                    )
                }
                .accessibilityIdentifier("vigil.history.quantity.\(index)")
            }

            ForEach(Array(sample.metrics.enumerated()), id: \.offset) { index, metric in
                detailSection(metric.label, symbol: historyMetricSymbol(metric.kind)) {
                    HistoryDetailValueRow(
                        label: historyMetricKindTitle(metric.kind),
                        value: historyMetricValue(metric)
                    )
                    if metric.secondary {
                        HistoryDetailValueRow(label: "Scope", value: "Secondary metric")
                    }
                }
                .accessibilityIdentifier("vigil.history.metric.\(index)")
            }

            if sample.windows.isEmpty,
               sample.quantities.isEmpty,
               sample.metrics.isEmpty {
                Text("The provider returned no quota, balance, cost, or quantity values in this accepted reading.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("vigil.history.sampleDetails")
    }

    private func detailSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.xSmall) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(VigilSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                VigilPalette.surfaceRaised.opacity(0.48),
                in: RoundedRectangle(cornerRadius: VigilRadius.small, style: .continuous)
            )
        }
    }
}

private struct HistoryDetailValueRow: View {
    let label: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { content }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: VigilSpacing.small) { content }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        Text(label)
            .foregroundStyle(VigilPalette.inkMuted)
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: VigilSpacing.small) }
        Text(value)
            .foregroundStyle(VigilPalette.ink)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func tightestWindow(in sample: UsageHistorySample) -> UsageHistoryWindow? {
    sample.windows.min {
        if $0.utilization != $1.utilization { return $0.utilization > $1.utilization }
        return historyWindowTitle($0) < historyWindowTitle($1)
    }
}

private func historyWindowTitle(_ window: UsageHistoryWindow) -> String {
    if let label = window.label, !label.isEmpty { return label }
    switch window.id.lowercased() {
    case "session":
        if window.windowSeconds == 18_000 { return "5-hour limit" }
        return "Session limit"
    case "weekly": return "Weekly limit"
    case "monthly": return "Monthly limit"
    case "plan": return "Plan limit"
    case "billing": return "Billing limit"
    case "weekly_sonnet": return "Sonnet weekly"
    case "weekly_opus": return "Opus weekly"
    default:
        return window.id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func historyMetricValue(_ metric: UsageHistoryMetric) -> String {
    if let unit = metric.unit, unit.count == 3 {
        return metric.value.formatted(.currency(code: unit).precision(.fractionLength(0...4)))
    }
    return "\(historyNumber(metric.value))\(metric.unit.map { " \($0)" } ?? "")"
}

private func historyDate(_ value: Date) -> String {
    value.formatted(date: .abbreviated, time: .shortened)
}

private func historyPercent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2))) + "%"
}

private func historyDuration(_ seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.days, .hours, .minutes], width: .abbreviated)
    )
}

private func historyMetricKindTitle(_ kind: UsageMetricKind) -> String {
    switch kind {
    case .balance: return "Balance"
    case .spend: return "Spend"
    case .limit: return "Limit"
    case .remaining: return "Remaining"
    }
}

private func historyMetricSymbol(_ kind: UsageMetricKind) -> String {
    switch kind {
    case .balance: return "creditcard"
    case .spend: return "banknote"
    case .limit: return "gauge.high"
    case .remaining: return "hourglass"
    }
}

private func historyQuantityKindTitle(_ kind: UsageHistoryQuantityKind) -> String {
    switch kind {
    case .inputTokens: return "Input tokens"
    case .outputTokens: return "Output tokens"
    case .cachedInputTokens: return "Cached input tokens"
    case .cacheReadTokens: return "Cache read tokens"
    case .cacheWriteTokens: return "Cache write tokens"
    case .requests: return "Requests"
    case .other: return "Provider quantity"
    }
}

private func primaryQuantity(in sample: UsageHistorySample) -> UsageHistoryQuantity? {
    sample.quantities.min {
        quantityRank($0.kind) < quantityRank($1.kind)
    }
}

private func quantityRank(_ kind: UsageHistoryQuantityKind) -> Int {
    switch kind {
    case .inputTokens: return 0
    case .outputTokens: return 1
    case .cachedInputTokens: return 2
    case .cacheReadTokens: return 3
    case .cacheWriteTokens: return 4
    case .requests: return 5
    case .other: return 6
    }
}

private func historyNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

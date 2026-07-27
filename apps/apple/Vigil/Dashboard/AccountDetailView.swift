import SwiftUI
import UniformTypeIdentifiers
import VigilKit

/// The complete provider truth surface. Home stays decisive; this screen owns
/// every accepted window, provider metric, freshness state, and local history.
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model

    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?

    @State private var showRelink = false
    @State private var diagnosticDocument: DiagnosticExportDocument?
    @State private var showDiagnosticExporter = false
    @State private var diagnosticExportError: String?

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    AccountCardView(
                        account: account,
                        snapshot: snapshot,
                        nextAllowed: nextAllowed,
                        relink: { showRelink = true }
                    )

                    limitSourceNote

                    if account.providerId == "openai" {
                        OfficialHistoryImportView(
                            state: model.officialHistoryImportState(for: account),
                            hasImportedRecords: model.historySummary(
                                for: account,
                                source: .providerBackfill
                            )?.sampleCount ?? 0 > 0,
                            importAction: {
                                Task { await model.importOfficialHistory(for: account) }
                            }
                        )
                    }

                    ObservedHistorySection(
                        account: account,
                        samples: model.history(for: account),
                        observedSummary: model.historySummary(
                            for: account,
                            source: .observed
                        ),
                        importedSummary: model.historySummary(
                            for: account,
                            source: .providerBackfill
                        ),
                        supportsOfficialImport: account.providerId == "openai"
                    )

                    accountDiagnostics
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(account.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showRelink) {
            AddAccountView(relinkTarget: account)
        }
        .fileExporter(
            isPresented: $showDiagnosticExporter,
            document: diagnosticDocument,
            contentType: .json,
            defaultFilename: diagnosticFilename
        ) { result in
            if case .failure = result {
                diagnosticExportError = "The account diagnostic report could not be exported. No credentials were exposed."
            }
            diagnosticDocument = nil
        }
        .alert(
            "Diagnostic export needs attention",
            isPresented: Binding(
                get: { diagnosticExportError != nil },
                set: { if !$0 { diagnosticExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { diagnosticExportError = nil }
        } message: {
            Text(diagnosticExportError ?? "")
        }
    }

    private var accountDiagnostics: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Label("Account diagnostics", systemImage: "doc.badge.gearshape")
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)

            Text("Export credential-free JSON for this account. It includes the current accepted reading and a bounded recent subset of local history, not the complete retained archive or raw provider responses.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: prepareAccountDiagnosticExport) {
                Label("Export account diagnostic report", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(VigilPalette.signal)
            .accessibilityIdentifier("vigil.accountDetail.exportDiagnostics")
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private var diagnosticFilename: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        return String(
            format: "Vigil-Account-Diagnostics-%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private func prepareAccountDiagnosticExport() {
        do {
            diagnosticDocument = DiagnosticExportDocument(
                data: try model.makeDiagnosticExportData(for: account)
            )
            showDiagnosticExporter = true
        } catch {
            diagnosticExportError = "Vigil could not build a credential-free account diagnostic report. Existing data was not changed."
        }
    }

    private var limitSourceNote: some View {
        let exactCount = snapshot?.windows.filter {
            $0.used != nil && $0.limit != nil
        }.count ?? 0
        let differingAmountBaseCount = snapshot?.windows.filter {
            $0.used != nil
                && $0.limit != nil
                && !UsagePresentation.exactAmountsMatchUtilization($0)
        }.count ?? 0
        let windowCount = snapshot?.windows.count ?? 0
        let metricCount = snapshot?.metrics.count ?? 0
        let plan = snapshot?.planLabel ?? account.plan
        let planContext = plan.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            return "The displayed \(UsagePresentation.planTitle(value)) plan identifies the allowance tier, and the live percentage already reflects that tier."
        }
        let text: String
        if let snapshot,
           SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
            text = "One or more provider resets have passed. Vigil hides those old values until a provider update confirms the new usage. Other unexpired limits and metrics remain visible."
        } else if snapshot == nil {
            text = "Vigil has no accepted provider reading for this account yet."
        } else if snapshot?.status != .ok {
            if windowCount > 0 {
                let retainedSource = exactCount > 0
                    ? "It included exact amounts for at least one quota."
                    : "It included percentages and reset times, but no absolute token or message ceiling."
                let tier = exactCount == 0
                    ? planContext.map { " \($0)" } ?? ""
                    : ""
                text = "These values are retained from the last accepted provider reading. \(retainedSource)\(tier)"
            } else if metricCount > 0 {
                text = "These balances or account metrics are retained from the last accepted provider reading."
            } else {
                text = "Vigil has no accepted quota or metric reading for this account. The latest provider check was not accepted."
            }
        } else if windowCount == 0, metricCount > 0 {
            text = "This provider currently reports balances or account metrics rather than a reset quota."
        } else if windowCount == 0 {
            text = "The provider accepted this account but did not report a finite quota or balance."
        } else if differingAmountBaseCount > 0 {
            text = "This provider reports both a quota percentage and exact amount fields, but at least one amount ratio uses a different allowance base. Vigil preserves and labels both instead of forcing them into one calculation."
        } else if exactCount == windowCount {
            text = "This provider supplied both used and limit values for every current quota."
        } else if exactCount > 0 {
            text = "This provider supplied exact amounts for some quotas and percentages for the others."
        } else {
            let source = "This provider supplied quota percentages and reset times, but no absolute token or message ceiling."
            let tier = planContext.map { " \($0) Vigil does not invent a fixed denominator from the plan name alone." } ?? ""
            text = source + tier
        }
        return Label(text, systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vigilInsetSurface()
            .accessibilityElement(children: .combine)
    }
}

private struct OfficialHistoryImportView: View {
    let state: OfficialHistoryImportState
    let hasImportedRecords: Bool
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "OpenAI API completion usage and organization costs",
                systemImage: "building.2"
            )
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)

            Text("Imports up to 365 days of completion token usage and organization costs. \(ProviderPresentation.openAIAdminCredentialDisclosure) The import does not include ChatGPT or Codex subscription activity.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            status

            Button(action: importAction) {
                Label(
                    hasImportedRecords ? "Refresh official records" : "Import official records",
                    systemImage: "arrow.down.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .disabled(state == .importing)
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Importing provider records…")
            }
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
        case .imported(let sampleCount, let date):
            Label(
                "Imported \(sampleCount) record\(sampleCount == 1 ? "" : "s") · \(date.formatted(date: .abbreviated, time: .shortened))",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(VigilPalette.safe)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(VigilPalette.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

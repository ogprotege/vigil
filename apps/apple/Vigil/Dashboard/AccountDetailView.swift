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
        let text = UsagePresentation.limitSourceNote(
            snapshot: snapshot,
            accountPlan: account.plan
        )
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

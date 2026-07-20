import SwiftUI
import VigilKit

/// Every per-model / special limit each provider surfaces, gathered across all
/// accounts into one scannable list — the model-specific caps (Claude Opus and
/// Sonnet weekly, model-scoped limits, Codex per-model lanes, MiniMax video)
/// pulled out of the account cards and shown on their own, tightest first.
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    private var candidates: [LimitCandidate] {
        UsagePresentation.modelLimits(accounts: model.accounts, snapshots: model.snapshots)
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header

                    if candidates.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                                if index > 0 {
                                    Divider().overlay(VigilPalette.ink.opacity(0.08))
                                }
                                LimitMeterRow(
                                    window: candidate.window,
                                    accountName: accountName(for: candidate)
                                )
                            }
                        }
                        .vigilCard(padding: VigilSpacing.medium)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, VigilSpacing.medium)
                .padding(.top, VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            VigilEyebrow(text: "Per-model caps")
            Text("The special model limits.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text(
                candidates.isEmpty
                    ? "Model-specific limits appear here once a connected provider reports them."
                    : "\(candidates.count) model limit\(candidates.count == 1 ? "" : "s") across your accounts, tightest first."
            )
            .font(.subheadline)
            .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VigilPalette.signal)
                .frame(width: 52, height: 52)
                .background(VigilPalette.signal.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("No model-specific limits yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text("Claude surfaces Opus and Sonnet weekly caps, Codex its per-model lanes, and MiniMax its video quota. They'll show here as your accounts report them.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilCard(padding: VigilSpacing.large)
    }

    /// Disambiguate the model row's owner. When more than one account of the
    /// same provider is linked, include the account label.
    private func accountName(for candidate: LimitCandidate) -> String {
        let sameProvider = model.accounts.filter {
            $0.providerId == candidate.account.providerId
        }.count
        return sameProvider > 1
            ? UsagePresentation.accountTitle(candidate.account)
            : candidate.account.displayName
    }
}

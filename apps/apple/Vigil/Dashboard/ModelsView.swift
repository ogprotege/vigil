import SwiftUI
import VigilKit

enum ModelsEmptyState: Equatable {
    case noAccounts
    case noPerModelCaps
    case waitingForData

    static func resolve(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot]
    ) -> ModelsEmptyState {
        guard !accounts.isEmpty else { return .noAccounts }

        let everyAccountIsHealthyWithoutModelCaps = accounts.allSatisfy { account in
            guard let snapshot = snapshots[account.key],
                  snapshot.status == .ok,
                  !snapshot.windows.contains(where: UsagePresentation.isModelWindow)
            else {
                return false
            }
            // A successful empty snapshot is valid only when the provider
            // contract explicitly recognizes an unmetered/unlimited response.
            // It still means there are no model caps to list here.
            return true
        }

        return everyAccountIsHealthyWithoutModelCaps ? .noPerModelCaps : .waitingForData
    }

    var title: String {
        switch self {
        case .noAccounts:
            return "No model-specific limits yet"
        case .noPerModelCaps:
            return "No per-model caps from these providers"
        case .waitingForData:
            return "Waiting for limit data"
        }
    }

    var detail: String {
        switch self {
        case .noAccounts:
            return "Sign in with Claude or Codex. Providers without model-specific caps keep their plan limits on Home."
        case .noPerModelCaps:
            return "Your connected providers report plan-wide limits, balances, spend, or no finite quota, but no model-specific caps. Open Home for those details."
        case .waitingForData:
            return "Pull to refresh on Home after adding an account. If verification failed, open Connections → add the account again."
        }
    }
}

/// Every genuine per-model limit each provider surfaces, gathered across all
/// accounts into one scannable list — Claude Opus and Sonnet weekly caps,
/// model-scoped limits, Codex per-model lanes, and MiniMax video
/// pulled out of the account cards and shown on their own, tightest first.
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    private var candidates: [LimitCandidate] {
        UsagePresentation.modelLimits(accounts: model.accounts, snapshots: model.snapshots)
    }

    private var emptyStateContent: ModelsEmptyState {
        ModelsEmptyState.resolve(accounts: model.accounts, snapshots: model.snapshots)
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
                                    accountName: accountName(for: candidate),
                                    status: candidate.snapshot.status,
                                    fetchedAt: candidate.snapshot.fetchedAt
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
                Text(emptyTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text(emptyDetail)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilCard(padding: VigilSpacing.large)
    }

    private var emptyTitle: String {
        emptyStateContent.title
    }

    private var emptyDetail: String {
        emptyStateContent.detail
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

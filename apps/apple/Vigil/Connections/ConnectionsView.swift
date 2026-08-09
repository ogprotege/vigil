import SwiftUI
import VigilKit

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var accountPendingRemoval: AccountRef?
    @State private var accountPendingHistoryRecovery: AccountRef?
    @State private var removalError: String?

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Accounts on this device")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(VigilPalette.ink)
                        Text("Add, inspect, or remove the accounts Vigil watches.")
                            .font(.subheadline)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }

                    Button { showAddAccount = true } label: {
                        SetupChoiceRow(
                            symbol: "person.badge.plus",
                            title: "Add an account",
                            detail: "Use guided sign-in or choose another provider.",
                            tone: .primary
                        )
                    }
                    .buttonStyle(.plain)

                    accountList
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddAccount = true } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddAccount) { AddAccountView() }
        // Both dialogs hand the pending account to their action closures via
        // `presenting:`. Tapping any dialog button synchronously dismisses the
        // dialog, and dismissal clears the pending state — so an action that
        // read the @State optional from its later Task always found nil and
        // silently removed nothing.
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.displayName ?? "account")?",
            isPresented: .init(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove account", role: .destructive) {
                Task { await remove(account) }
            }
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: { _ in
            Text("This deletes the credential and saved usage from this device.")
        }
        .confirmationDialog(
            "Delete all local Vigil history?",
            isPresented: .init(
                get: { accountPendingHistoryRecovery != nil },
                set: { if !$0 { accountPendingHistoryRecovery = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountPendingHistoryRecovery
        ) { account in
            Button("Delete all history and finish removal", role: .destructive) {
                Task { await finishRemovalWithHistoryRecovery(account) }
            }
            Button("Keep history and account entry", role: .cancel) {
                accountPendingHistoryRecovery = nil
            }
        } message: { _ in
            Text(
                "The account credential is already gone, but damaged local history blocked cleanup. "
                    + "This permanently deletes observed and imported history for every Vigil account, then finishes removing this account."
            )
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

    private var accountList: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack {
                Text("Linked accounts")
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                Spacer()
                Text("\(model.accounts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VigilPalette.inkMuted)
            }

            if model.accounts.isEmpty {
                Label("No accounts are linked yet.", systemImage: "link.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vigilInsetSurface()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.accounts) { account in
                        ConnectionAccountRow(
                            account: account,
                            snapshot: model.snapshots[account.key],
                            nextAllowed: model.nextAllowed[account.key],
                            isRemoving: model.isRemovingAccount(account.key),
                            remove: { accountPendingRemoval = account }
                        )
                    }
                }
            }
        }
    }

    private func remove(_ account: AccountRef) async {
        do {
            try await model.removeAccount(account)
        } catch AppModel.LinkError.historyRecoveryRequired(_) {
            accountPendingHistoryRecovery = account
        } catch {
            removalError = error.localizedDescription
        }
    }

    private func finishRemovalWithHistoryRecovery(_ account: AccountRef) async {
        do {
            try await model.finishRemovalByDeletingAllHistory(account)
        } catch {
            removalError = error.localizedDescription
        }
    }
}

private struct ConnectionAccountRow: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let isRemoving: Bool
    let remove: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                AccountDetailView(
                    account: account,
                    snapshot: snapshot,
                    nextAllowed: nextAllowed
                )
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            identity
                            status
                            openCue
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            identity
                            Spacer(minLength: 6)
                            status
                            openCue
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens all provider limits and account details")

            Button(isRemoving ? "Removing account..." : "Remove account", role: .destructive, action: remove)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .disabled(isRemoving)
                .accessibilityIdentifier("vigil.accounts.remove.\(account.providerId)")
        }
        .padding(14)
        .vigilInsetSurface()
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            VigilProviderMark(providerId: account.providerId, displayName: account.displayName)
            VStack(alignment: .leading, spacing: 4) {
                Text(UsagePresentation.accountTitle(account))
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(limitSummary)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
    }

    private var limitSummary: String {
        guard let snapshot else { return "Waiting for first check" }
        let count = SnapshotFreshness.confirmedWindows(in: snapshot).count
        if snapshot.status == .ok,
           SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
            return count == 0
                ? "Reset passed · awaiting update"
                : "\(count) current limit\(count == 1 ? "" : "s") · reset awaiting update"
        }
        if snapshot.status == .ok {
            return "\(count) reported limit\(count == 1 ? "" : "s")"
        }
        guard count > 0 else { return "No accepted limits yet" }
        return "\(count) last accepted limit\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var status: some View {
        if let snapshot {
            if snapshot.status == .ok,
               SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
                VigilStatusPill(
                    text: "Awaiting update",
                    color: VigilPalette.caution,
                    symbol: "arrow.clockwise.circle"
                )
            } else if snapshot.status == .ok, SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt) {
                VigilStatusPill(text: "Stale", color: VigilPalette.caution, symbol: "clock.badge.exclamationmark")
            } else {
                VigilStatusPill(
                    text: UsagePresentation.statusTitle(snapshot.status),
                    color: VigilPalette.statusColor(snapshot.status),
                    symbol: UsagePresentation.statusSymbol(snapshot.status)
                )
            }
        } else {
            VigilStatusPill(text: "Waiting", color: VigilPalette.inkMuted, symbol: "clock")
        }
    }

    private var openCue: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(VigilPalette.inkFaint)
            .accessibilityHidden(true)
    }
}

import SwiftUI
import VigilKit

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false
    @State private var accountPendingRemoval: AccountRef?
    @State private var removalError: String?

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header
                    pairingCard
                    linkedAccounts
                    coverageCard
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Connections")
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
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.displayName ?? "account")?",
            isPresented: .init(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) {
                removePendingAccount()
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: {
            Text("This deletes the credential and saved usage from this device.")
        }
        .alert(
            "Account removal needs attention",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                removalError = nil
            }
        } message: {
            Text(removalError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "Accounts and providers")
            Text("Choose what Vigil watches.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Paste a provider key, import Claude/Codex from this Mac when available, or mint an optional renewing sign-in.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var pairingCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(VigilPalette.signal)
                .frame(width: 52, height: 52)
                .background(
                    VigilPalette.signal.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an account")
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                Text("Local keys and Mac file import first. Browser OAuth only if you want a renewing Vigil-owned token.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Add") {
                showAddAccount = true
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)
            .frame(minHeight: 44)
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private var linkedAccounts: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(
                "Linked accounts",
                eyebrow: "This device",
                detail: "\(model.accounts.count)"
            )

            if model.accounts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(VigilPalette.inkMuted)
                    Text("No accounts are linked yet.")
                        .font(.callout)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vigilInsetSurface()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.accounts) { account in
                        ConnectionAccountRow(
                            account: account,
                            snapshot: model.snapshots[account.key],
                            remove: { accountPendingRemoval = account }
                        )
                    }
                }
            }
        }
    }

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(
                "Provider coverage",
                eyebrow: "Available today",
                detail: "\(ProviderRegistry.all.count)"
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ProviderRegistry.all, id: \.id) { spec in
                    let linked = model.accounts.contains { $0.providerId == spec.id }
                    HStack(spacing: 10) {
                        VigilProviderMark(
                            providerId: spec.id,
                            displayName: spec.displayName,
                            size: 34
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VigilPalette.ink)
                                .lineLimit(1)
                            Text(linked ? "Linked" : ProviderPresentation.setupLabel(for: spec))
                                .font(.caption2)
                                .foregroundStyle(
                                    linked ? VigilPalette.safe : VigilPalette.inkMuted
                                )
                        }
                        Spacer()
                        if linked {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VigilPalette.safe)
                                .accessibilityLabel("Linked")
                        }
                    }
                    .padding(10)
                    .vigilInsetSurface(cornerRadius: VigilRadius.small)
                }
            }
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private func removePendingAccount() {
        guard let account = accountPendingRemoval else { return }
        do {
            try model.removeAccount(account)
        } catch {
            removalError = error.localizedDescription
        }
        accountPendingRemoval = nil
    }
}

private struct ConnectionAccountRow: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VigilProviderMark(
                    providerId: account.providerId,
                    displayName: account.displayName
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.headline)
                        .foregroundStyle(VigilPalette.ink)
                    if let label = account.label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }
                }
                Spacer()
                if let snapshot {
                    if SnapshotFreshness.isDegraded(
                        status: snapshot.status,
                        fetchedAt: snapshot.fetchedAt
                    ) {
                        VigilStatusPill(
                            text: "Stale",
                            color: VigilPalette.caution,
                            symbol: "clock.badge.exclamationmark"
                        )
                    } else {
                        VigilStatusPill(
                            text: UsagePresentation.statusTitle(snapshot.status),
                            color: VigilPalette.statusColor(snapshot.status),
                            symbol: UsagePresentation.statusSymbol(snapshot.status)
                        )
                    }
                } else {
                    VigilStatusPill(
                        text: "Waiting",
                        color: VigilPalette.inkMuted,
                        symbol: "clock"
                    )
                }
            }

            HStack {
                Label(
                    "\(snapshot?.windows.count ?? 0) limit\(snapshot?.windows.count == 1 ? "" : "s")",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                if let plan = snapshot?.planLabel ?? account.plan, !plan.isEmpty {
                    Text("· \(plan.capitalized)")
                }
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            .font(.caption)
            .foregroundStyle(VigilPalette.inkMuted)
        }
        .padding(14)
        .vigilInsetSurface()
    }
}

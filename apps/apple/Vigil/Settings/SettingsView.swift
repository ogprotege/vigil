import SwiftUI
import VigilKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header

                    settingsSection(
                        title: "Security",
                        eyebrow: "Device protection"
                    ) {
                        HStack(spacing: 12) {
                            settingsIcon("faceid", tint: VigilPalette.signal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Require Face ID or Touch ID")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(VigilPalette.ink)
                                Text("Lock Vigil whenever it returns to the foreground.")
                                    .font(.caption)
                                    .foregroundStyle(VigilPalette.inkMuted)
                            }
                            Spacer()
                            Toggle(
                                "Require Face ID or Touch ID",
                                isOn: Binding(
                                    get: { model.lockEnabled },
                                    set: { model.lockEnabled = $0 }
                                )
                            )
                            .labelsHidden()
                            .tint(VigilPalette.signal)
                        }
                        .padding(14)
                        .vigilInsetSurface()
                    }

                    settingsSection(
                        title: "Privacy",
                        eyebrow: "On-device by design"
                    ) {
                        NavigationLink {
                            PrivacyView()
                        } label: {
                            SettingsNavigationRow(
                                symbol: "lock.shield",
                                title: "How Vigil handles your data",
                                detail: "Credentials, snapshots, and provider requests"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(
                        title: "Refresh policy",
                        eyebrow: "Provider safety"
                    ) {
                        VStack(spacing: 0) {
                            SettingsValueRow(
                                label: "Polling floor",
                                value: "5 min + jitter"
                            )
                            Divider()
                                .overlay(VigilPalette.border.opacity(0.55))
                            SettingsValueRow(
                                label: "Countdowns",
                                value: "Live on device"
                            )
                        }
                        .vigilInsetSurface()

                        Text("Foreground refreshes, background tasks, and widgets use the same safety ledger. Manual refresh never bypasses a provider cooldown.")
                            .font(.caption)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }

                    #if DEBUG
                    settingsSection(
                        title: "Diagnostics",
                        eyebrow: "Debug build"
                    ) {
                        Button {
                            Task { await simulateThresholdCrossing() }
                        } label: {
                            SettingsNavigationRow(
                                symbol: "bell.badge",
                                title: "Simulate the 80% alert",
                                detail: "Exercises the notification path end to end",
                                showsChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.accounts.isEmpty)
                    }
                    #endif

                    settingsSection(
                        title: "About Vigil",
                        eyebrow: "Build information"
                    ) {
                        VStack(spacing: 0) {
                            SettingsValueRow(label: "Version", value: appVersion)
                            Divider()
                                .overlay(VigilPalette.border.opacity(0.55))
                            SettingsValueRow(label: "Storage", value: "This device only")
                        }
                        .vigilInsetSurface()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "Vigil preferences")
            Text("Quiet controls. Clear promises.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Security, privacy, and provider-safe refresh behavior.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(title, eyebrow: eyebrow)
            content()
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private func settingsIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private func simulateThresholdCrossing() async {
        guard let account = model.accounts.first else { return }
        let before = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: Date().addingTimeInterval(-60),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: 79,
                    resetsAt: Date().addingTimeInterval(3600),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
        let after = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: Date(),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: 81,
                    resetsAt: Date().addingTimeInterval(3600),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
        let events = ThresholdEngine.crossings(previous: before, current: after)
        await model.notifications.requestAuthorizationIfNeeded()
        _ = await model.notifications.deliver(events: events, account: account)
    }
    #endif
}

private struct SettingsNavigationRow: View {
    let symbol: String
    let title: String
    let detail: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(VigilPalette.signal)
                .frame(width: 36, height: 36)
                .background(
                    VigilPalette.signal.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(VigilPalette.inkFaint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .vigilInsetSurface()
        .contentShape(Rectangle())
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(VigilPalette.inkMuted)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(VigilPalette.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(14)
    }
}

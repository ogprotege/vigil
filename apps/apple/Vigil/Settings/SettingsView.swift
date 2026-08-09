import SwiftUI
import VigilKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var exportDocument: DiagnosticExportDocument?
    @State private var showDiagnosticExporter = false
    @State private var exportError: String?
    @State private var showRepairBackupDeletion = false
    @State private var repairBackupError: String?
    @State private var showFullRecoveryReset = false
    @State private var fullRecoveryError: String?
    @State private var fullRecoveryCompleted = false

    var body: some View {
        recoveryPresentation
    }

    private var settingsContent: some View {
        let preferences = model.preferences

        return ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    appearanceSettingsSection
                    alertsSettingsSection
                    securitySettingsSection
                    privacySettingsSection
                    refreshSettingsSection
                    #if DEBUG
                    diagnosticsSettingsSection
                    #endif
                    aboutSettingsSection
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: preferences.appearance) { _, _ in
            model.presentationPreferencesDidChange()
        }
        .onChange(of: preferences.usageAlertsEnabled) { _, _ in
            Task { await model.usageAlertsPreferenceDidChange() }
        }
        .onChange(of: preferences.automaticChecksPaused) { _, _ in
            model.automaticChecksPreferenceDidChange()
        }
        .onChange(of: preferences.widgetValuesHidden) { _, _ in
            model.presentationPreferencesDidChange()
        }
    }

    private var diagnosticPresentation: some View {
        settingsContent
        .fileExporter(
            isPresented: $showDiagnosticExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: diagnosticFilename
        ) { result in
            if case .failure = result {
                exportError = "The diagnostic report could not be exported. No credentials were exposed."
            }
            exportDocument = nil
        }
        .alert(
            "Diagnostic export needs attention",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var repairPresentation: some View {
        diagnosticPresentation
        .confirmationDialog(
            "Delete account repair backup?",
            isPresented: $showRepairBackupDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Repair Backup", role: .destructive) {
                do {
                    try model.deleteAccountRepairBackups()
                } catch {
                    repairBackupError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the damaged account-index copy kept during recovery. It does not remove linked accounts, credentials, or usage history.")
        }
        .alert(
            "Repair backup needs attention",
            isPresented: Binding(
                get: { repairBackupError != nil },
                set: { if !$0 { repairBackupError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { repairBackupError = nil }
        } message: {
            Text(repairBackupError ?? "")
        }
    }

    private var recoveryPresentation: some View {
        repairPresentation
        .confirmationDialog(
            "Erase all local Vigil data?",
            isPresented: $showFullRecoveryReset,
            titleVisibility: .visible
        ) {
            Button("Erase Everything and Start Over", role: .destructive) {
                Task { await performFullRecoveryReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes Vigil's Keychain credentials, linked accounts, current snapshots, observed and imported history, polling metadata, and Vigil notifications from this device. It does not delete your provider accounts. This cannot be undone."
            )
        }
        .alert(
            "Recovery reset needs attention",
            isPresented: Binding(
                get: { fullRecoveryError != nil },
                set: { if !$0 { fullRecoveryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fullRecoveryError = nil }
        } message: {
            Text(fullRecoveryError ?? "")
        }
        .alert("Vigil is ready to set up again", isPresented: $fullRecoveryCompleted) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All recoverable local Vigil data and Keychain credentials were deleted. You can now link accounts again.")
        }
    }

    private var appearanceSettingsSection: some View {
        @Bindable var preferences = model.preferences
        return settingsSection("Appearance") {
            appearanceControl(selection: $preferences.appearance)
        }
    }

    private var alertsSettingsSection: some View {
        @Bindable var preferences = model.preferences
        return settingsSection("Alerts") {
            VStack(spacing: 10) {
                adaptiveToggle(
                    title: "Usage alerts",
                    detail: "Notify at the fixed 80% and 95% usage thresholds.",
                    isOn: $preferences.usageAlertsEnabled
                )
                .accessibilityIdentifier("vigil.settings.usageAlerts")

                adaptiveToggle(
                    title: "Hide notification details",
                    detail: "Use generic alert text without provider names, windows, or percentages.",
                    isOn: $preferences.notificationDetailsHidden
                )
                .disabled(!preferences.usageAlertsEnabled)
                .opacity(preferences.usageAlertsEnabled ? 1 : 0.62)
                .accessibilityIdentifier("vigil.settings.notificationPrivacy")
            }
        }
    }

    private var securitySettingsSection: some View {
        @Bindable var model = model
        return settingsSection("Security") {
            adaptiveToggle(
                title: "Require Face ID or Touch ID",
                detail: "Lock Vigil whenever it returns to the foreground.",
                isOn: Binding(
                    get: { model.lockEnabled },
                    set: { model.lockEnabled = $0 }
                )
            )
        }
    }

    private var privacySettingsSection: some View {
        @Bindable var preferences = model.preferences
        return settingsSection("Privacy") {
            VStack(spacing: 10) {
                adaptiveToggle(
                    title: "Hide usage values in widgets",
                    detail: "Show the linked provider and freshness without percentages, limits, spend, or balances.",
                    isOn: $preferences.widgetValuesHidden
                )
                .accessibilityIdentifier("vigil.settings.widgetPrivacy")

                NavigationLink {
                    PrivacyView()
                } label: {
                    SettingsNavigationRow(
                        symbol: "lock.shield",
                        title: "How Vigil handles your data",
                        detail: "Credentials, snapshots, and direct provider requests"
                    )
                }
                .buttonStyle(.plain)

                Button(action: prepareDiagnosticExport) {
                    SettingsNavigationRow(
                        symbol: "square.and.arrow.up",
                        title: "Export diagnostic report",
                        detail: "Bounded recent support data without credentials or raw responses",
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vigil.settings.exportDiagnostics")

                if model.hasAccountRepairBackups {
                    Button(role: .destructive) {
                        showRepairBackupDeletion = true
                    } label: {
                        SettingsNavigationRow(
                            symbol: "trash",
                            title: "Delete account repair backup",
                            detail: "Remove the damaged account list preserved during recovery",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vigil.settings.deleteRepairBackup")
                }

                if model.requiresFullLocalDataRecovery {
                    Button(role: .destructive) {
                        showFullRecoveryReset = true
                    } label: {
                        SettingsNavigationRow(
                            symbol: "exclamationmark.arrow.triangle.2.circlepath",
                            title: model.isResettingAllLocalData
                                ? "Erasing local Vigil data..."
                                : "Erase Vigil data and start over",
                            detail: "Deletes every linked credential, snapshot, history record, and Vigil notification from this device",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isResettingAllLocalData)
                    .accessibilityIdentifier("vigil.settings.fullRecoveryReset")
                }
            }
        }
    }

    private var refreshSettingsSection: some View {
        @Bindable var preferences = model.preferences
        return settingsSection("Refresh") {
            VStack(spacing: 10) {
                adaptiveToggle(
                    title: "Pause automatic checks",
                    detail: "Stop foreground timer, background, and widget fetches. Pull to refresh still works.",
                    isOn: $preferences.automaticChecksPaused
                )
                .accessibilityIdentifier("vigil.settings.pauseAutomaticChecks")

                VStack(spacing: 0) {
                    SettingsValueRow(label: "Provider floor", value: "1–2 min")
                    Divider().overlay(VigilPalette.border.opacity(0.7))
                    SettingsValueRow(label: "Background checks", value: "Scheduled by iOS")
                }
                .vigilInsetSurface()
            }

            Text("Manual refresh, background work, and widgets share one provider cooldown and honor provider backoff. Observed history can contain gaps.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    #if DEBUG
    private var diagnosticsSettingsSection: some View {
        settingsSection("Diagnostics") {
            Button { Task { await simulateThresholdCrossing() } } label: {
                SettingsNavigationRow(
                    symbol: "bell.badge",
                    title: "Simulate the 80% alert",
                    detail: "Exercises the local notification path",
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .disabled(model.accounts.isEmpty)
        }
    }
    #endif

    private var aboutSettingsSection: some View {
        settingsSection("About") {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    SettingsValueRow(label: "Version", value: appVersion)
                    Divider().overlay(VigilPalette.border.opacity(0.7))
                    SettingsValueRow(label: "Storage", value: "This device only")
                }
                .vigilInsetSurface()

                Link(
                    destination: VigilLinks.supportURL
                ) {
                    SettingsNavigationRow(
                        symbol: "questionmark.circle",
                        title: "Help and support",
                        detail: "Read guidance or report a problem",
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
            content()
        }
    }

    private func adaptiveToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    settingCopy(title: title, detail: detail)
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                }
            } else {
                HStack(spacing: 12) {
                    settingCopy(title: title, detail: detail)
                    Spacer(minLength: 12)
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                }
            }
        }
        .padding(14)
        .vigilInsetSurface()
        .accessibilityElement(children: .contain)
    }

    private func appearanceControl(
        selection: Binding<VigilPreferences.Appearance>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            settingCopy(
                title: "Color scheme",
                detail: "System follows your device. Dark preserves Vigil's original low-light appearance."
            )
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Color scheme", selection: selection) {
                    appearanceOptions
                }
                .pickerStyle(.menu)
            } else {
                Picker("Color scheme", selection: selection) {
                    appearanceOptions
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .vigilInsetSurface()
        .accessibilityIdentifier("vigil.settings.appearance")
    }

    @ViewBuilder
    private var appearanceOptions: some View {
        ForEach(VigilPreferences.Appearance.allCases) { appearance in
            Text(appearance.title).tag(appearance)
        }
    }

    private func settingCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var diagnosticFilename: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        return String(
            format: "Vigil-Diagnostics-%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private func prepareDiagnosticExport() {
        do {
            exportDocument = DiagnosticExportDocument(
                data: try model.makeDiagnosticExportData()
            )
            showDiagnosticExporter = true
        } catch {
            exportError = "Vigil could not build a credential-free diagnostic report. Existing data was not changed."
        }
    }

    private func performFullRecoveryReset() async {
        do {
            try await model.resetAllLocalDataForRecovery()
            fullRecoveryCompleted = true
        } catch {
            fullRecoveryError = error.localizedDescription
        }
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
        _ = await model.notifications.deliver(
            events: events,
            account: account,
            deliveryScope: "settings-test-\(UUID().uuidString.lowercased())",
            hidesDetails: model.preferences.notificationDetailsHidden
        )
    }
    #endif
}

private struct SettingsNavigationRow: View {
    let symbol: String
    let title: String
    let detail: String
    var showsChevron = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    icon
                    copy
                    if showsChevron { chevron }
                }
            } else {
                HStack(spacing: 12) {
                    icon
                    copy
                    Spacer(minLength: 8)
                    if showsChevron { chevron }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .vigilInsetSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(VigilPalette.signal)
            .frame(width: 36, height: 36)
            .background(VigilPalette.signal.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(VigilPalette.ink)
            Text(detail).font(.caption).foregroundStyle(VigilPalette.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(VigilPalette.inkFaint)
            .accessibilityHidden(true)
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) { labels }
            } else {
                HStack { labels }
            }
        }
        .font(.subheadline)
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var labels: some View {
        Text(label).foregroundStyle(VigilPalette.inkMuted)
        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        Text(value)
            .fontWeight(.semibold)
            .foregroundStyle(VigilPalette.ink)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
}

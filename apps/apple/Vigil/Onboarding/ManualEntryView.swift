import SwiftUI
import VigilKit

/// Direct provider setup. The provider arrives preselected from the catalog,
/// so the form shows only the credential fields that are actually relevant.
struct ManualEntryView: View {
    let onSubmit: (Credentials) -> Void
    let submitTitle: String
    let locksProvider: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var providerId: String
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var accountId = ""
    @State private var label = ""
    @State private var revealAccessToken = false

    init(
        providerId: String = "claude",
        submitTitle: String = "Verify and add account",
        locksProvider: Bool = false,
        onSubmit: @escaping (Credentials) -> Void
    ) {
        self.onSubmit = onSubmit
        self.submitTitle = submitTitle
        self.locksProvider = locksProvider
        _providerId = State(initialValue: providerId)
    }

    private var selectedSpec: ProviderSpec? {
        ProviderRegistry.spec(for: providerId)
    }

    private var requiresAccountId: Bool {
        selectedSpec.map(ProviderPresentation.needsAccountId) == true
    }

    private var credentialLabel: String {
        selectedSpec.map(ProviderPresentation.setupLabel) ?? "Credential"
    }

    private var canSubmit: Bool {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        if requiresAccountId {
            return !accountId.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    providerHeader
                    guidance
                    credentialForm
                    submitButton
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Direct setup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var providerHeader: some View {
        HStack(spacing: 14) {
            if let selectedSpec {
                VigilProviderMark(
                    providerId: selectedSpec.id,
                    displayName: selectedSpec.displayName,
                    size: 52
                )
            }
            VStack(alignment: .leading, spacing: 5) {
                VigilEyebrow(text: "Provider")
                if locksProvider {
                    Text(selectedSpec?.displayName ?? providerId)
                        .font(.headline)
                        .foregroundStyle(VigilPalette.ink)
                } else {
                    Picker("Provider", selection: $providerId) {
                        ForEach(ProviderRegistry.all, id: \.id) { spec in
                            Text(ProviderPresentation.pickerTitle(for: spec))
                                .tag(spec.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(VigilPalette.ink)
                }
                if let selectedSpec {
                    HStack(spacing: 7) {
                        Text(ProviderPresentation.setupLabel(for: selectedSpec))
                            .font(.caption)
                            .foregroundStyle(VigilPalette.inkMuted)
                        if selectedSpec.experimental {
                            ExperimentalBadge()
                        }
                    }
                }
            }
            Spacer()
        }
        .vigilCard(padding: VigilSpacing.medium)
        .onChange(of: providerId) {
            accessToken = ""
            refreshToken = ""
            accountId = ""
        }
    }

    @ViewBuilder
    private var guidance: some View {
        if let selectedSpec {
            VStack(alignment: .leading, spacing: 10) {
                VigilSectionHeading("What you need", eyebrow: "Setup guide")
                Text(
                    selectedSpec.manualEntryHint
                        ?? "Enter a credential accepted by this provider."
                )
                .font(.callout)
                .foregroundStyle(VigilPalette.inkMuted)
                .textSelection(.enabled)

                if let warning = ProviderPresentation.credentialWarning(for: selectedSpec) {
                    StatusBannerView(
                        icon: "exclamationmark.shield",
                        tint: VigilPalette.critical,
                        text: warning
                    )
                }

                if selectedSpec.experimental {
                    StatusBannerView(
                        icon: "testtube.2",
                        tint: VigilPalette.caution,
                        text: "This integration uses a community-documented endpoint. It may change without notice."
                    )
                }
            }
            .vigilCard(padding: VigilSpacing.medium)
        }
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading("Credentials", eyebrow: "Stored in Keychain")

            VStack(alignment: .leading, spacing: 7) {
                requiredLabel(credentialLabel)
                HStack(spacing: 4) {
                    Group {
                        if revealAccessToken {
                            TextField(credentialLabel, text: $accessToken)
                        } else {
                            SecureField(credentialLabel, text: $accessToken)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif

                    Button {
                        revealAccessToken.toggle()
                    } label: {
                        Image(
                            systemName: revealAccessToken
                                ? "eye.slash"
                                : "eye"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .accessibilityLabel(
                        revealAccessToken ? "Hide \(credentialLabel)" : "Show \(credentialLabel)"
                    )
                }
                .padding(.leading, 12)
                .padding(.trailing, 2)
                .vigilInsetSurface(cornerRadius: VigilRadius.small)
            }

            if selectedSpec?.oauth != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Refresh token")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VigilPalette.inkMuted)
                    SecureField("Optional refresh token", text: $refreshToken)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .padding(13)
                        .vigilInsetSurface(cornerRadius: VigilRadius.small)
                    Text("Optional. Vigil refreshes only token pairs it owns.")
                        .font(.caption2)
                        .foregroundStyle(VigilPalette.inkFaint)
                }
            }

            if let spec = selectedSpec, ProviderPresentation.needsAccountId(spec) {
                VStack(alignment: .leading, spacing: 7) {
                    requiredLabel(ProviderPresentation.accountIdLabel(for: spec))
                    TextField(
                        ProviderPresentation.accountIdLabel(for: spec),
                        text: $accountId
                    )
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .padding(13)
                    .vigilInsetSurface(cornerRadius: VigilRadius.small)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Account label")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VigilPalette.inkMuted)
                TextField("Optional, such as Personal or Work", text: $label)
                    .textFieldStyle(.plain)
                    .padding(13)
                    .vigilInsetSurface(cornerRadius: VigilRadius.small)
            }
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private var submitButton: some View {
        Button(submitTitle) {
            let trimmedRefresh = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAccount = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            onSubmit(
                Credentials(
                    providerId: providerId,
                    accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    refreshToken: selectedSpec?.oauth != nil && !trimmedRefresh.isEmpty
                        ? trimmedRefresh
                        : nil,
                    accountId: requiresAccountId && !trimmedAccount.isEmpty
                        ? trimmedAccount
                        : nil,
                    label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                    // Hand-entered keys are never auto-refreshed (only Vigil-minted
                    // tokens are — ADR-0005); marking them keeps that explicit.
                    source: "manual"
                )
            )
            dismiss()
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 50)
        .buttonStyle(.borderedProminent)
        .tint(VigilPalette.signal)
        .foregroundStyle(VigilPalette.canvas)
        .disabled(!canSubmit)
        .accessibilityHint("Verifies the credential before saving it to Keychain")
    }

    private func requiredLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Text("Required")
                .foregroundStyle(VigilPalette.caution)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(VigilPalette.inkMuted)
    }
}

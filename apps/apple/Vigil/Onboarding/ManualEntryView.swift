import SwiftUI
import VigilKit

/// The escape hatch: type tokens by hand (docs/local-next-steps.md Phase 3,
/// path c). Verification still runs before anything is stored.
struct ManualEntryView: View {
    let onSubmit: (Credentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var providerId = "claude"
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var accountId = ""
    @State private var label = ""

    private var selectedSpec: ProviderSpec? {
        ProviderRegistry.spec(for: providerId)
    }

    private var requiresAccountId: Bool {
        selectedSpec.map(ProviderPresentation.needsAccountId) == true
    }

    private var credentialLabel: String {
        selectedSpec?.auth == "api_key_bearer" ? "API key" : "Access token"
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
        Form {
            Picker("Provider", selection: $providerId) {
                ForEach(ProviderRegistry.all, id: \.id) { spec in
                    Text(ProviderPresentation.pickerTitle(for: spec)).tag(spec.id)
                }
            }
            if selectedSpec?.experimental == true {
                StatusBannerView(
                    icon: "testtube.2",
                    tint: .orange,
                    text: "Experimental — a community-documented endpoint, not a vendor-supported integration. It may break without notice."
                )
            }

            Section {
                SecureField(credentialLabel, text: $accessToken)
                if selectedSpec?.oauth != nil {
                    SecureField("Refresh token (optional)", text: $refreshToken)
                }
                if let spec = selectedSpec, ProviderPresentation.needsAccountId(spec) {
                    TextField(ProviderPresentation.accountIdLabel(for: spec), text: $accountId)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                }
                TextField("Label (optional)", text: $label)
            } header: {
                Text("Credentials")
            } footer: {
                Text(selectedSpec?.manualEntryHint ?? "Enter a credential accepted by this provider.")
            }

            Button("Verify & add") {
                let trimmedRefresh = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAccount = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                onSubmit(Credentials(
                    providerId: providerId,
                    accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    refreshToken: selectedSpec?.oauth != nil && !trimmedRefresh.isEmpty
                        ? trimmedRefresh
                        : nil,
                    accountId: requiresAccountId && !trimmedAccount.isEmpty
                        ? trimmedAccount
                        : nil,
                    label: trimmedLabel.isEmpty ? nil : trimmedLabel
                ))
                dismiss()
            }
            .disabled(!canSubmit)
        }
        .navigationTitle("Manual entry")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

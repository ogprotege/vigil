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

    private var canSubmit: Bool {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        if providerId == "codex" {
            return !accountId.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        Form {
            Picker("Provider", selection: $providerId) {
                ForEach(ProviderRegistry.all, id: \.id) { spec in
                    Text(spec.displayName).tag(spec.id)
                }
            }

            Section {
                SecureField("Access token", text: $accessToken)
                SecureField("Refresh token (optional)", text: $refreshToken)
                if providerId == "codex" {
                    TextField("Account ID", text: $accountId)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                }
                TextField("Label (optional)", text: $label)
            } header: {
                Text("Credentials")
            } footer: {
                Text(providerId == "codex"
                     ? "From ~/.codex/auth.json: tokens.access_token and tokens.account_id."
                     : "From `npx vigil-link --json`, or ~/.claude/.credentials.json (claudeAiOauth.accessToken).")
            }

            Button("Verify & add") {
                let trimmedRefresh = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAccount = accountId.trimmingCharacters(in: .whitespaces)
                let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
                onSubmit(Credentials(
                    providerId: providerId,
                    accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    refreshToken: trimmedRefresh.isEmpty ? nil : trimmedRefresh,
                    accountId: trimmedAccount.isEmpty ? nil : trimmedAccount,
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

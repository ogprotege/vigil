import SwiftUI
import VigilKit

/// Spec-derived UI decisions shared by manual entry, the add-account flow,
/// and the account surfaces. Policy is data (providers.json mirrored into
/// ProviderRegistry): these helpers read the spec's templates and flags so no
/// surface carries its own hardcoded provider list to drift.
enum ProviderPresentation {
    /// True when building a usage request for this provider needs an account
    /// id — the spec references "{account_id}" in the URL template (GitHub
    /// username, xAI team id) or in any header template (Codex).
    /// RequestBuilder refuses to build the request without it, so linking
    /// without one can only ever produce a dead account.
    static func needsAccountId(_ spec: ProviderSpec) -> Bool {
        spec.usageURLTemplate.contains("{account_id}")
            || spec.headers.values.contains { $0.contains("{account_id}") }
    }

    /// Field label for the account-id input, matching what the provider
    /// itself calls the value so users recognize what to paste.
    static func accountIdLabel(for spec: ProviderSpec) -> String {
        switch spec.id {
        case "github": return "GitHub username"
        case "xai": return "Team ID"
        default: return "Account ID"
        }
    }

    /// Picker/menu title: the display name plus an honest experimental
    /// marker so nobody mistakes a community-documented endpoint for a
    /// vendor-supported integration.
    static func pickerTitle(for spec: ProviderSpec) -> String {
        spec.experimental ? "\(spec.displayName) (Experimental)" : spec.displayName
    }

    static func isExperimental(providerId: String) -> Bool {
        ProviderRegistry.spec(for: providerId)?.experimental == true
    }
}

/// The one "Experimental" chip every surface reuses — styled after the
/// account card's plan capsule, tinted orange so it reads as a caution, not
/// a feature.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityLabel(Text("Experimental integration"))
    }
}

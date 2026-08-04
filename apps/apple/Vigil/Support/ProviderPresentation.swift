import SwiftUI
import VigilKit

/// Spec-derived UI decisions shared by manual entry, the add-account flow,
/// and the account surfaces. Policy is data (providers.json mirrored into
/// ProviderRegistry): these helpers read the spec's templates and flags so no
/// surface carries its own hardcoded provider list to drift.
enum ProviderPresentation {
    static let openAIAdminCredentialDisclosure =
        "An API-platform organization Admin API key is a broad organization-owner credential, not a read-only key. Vigil sends only documented GET requests to OpenAI's organization Usage and Costs APIs. Regular project keys cannot access those endpoints."

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

    static func symbol(for providerId: String) -> String {
        switch providerId {
        case "claude": return "sparkles"
        case "codex": return "terminal"
        case "openrouter": return "point.3.connected.trianglepath.dotted"
        case "deepseek": return "wave.3.right"
        case "moonshot", "moonshot_cn": return "moon.stars"
        case "minimax", "minimax_cn": return "bolt.horizontal"
        case "openai": return "chart.xyaxis.line"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "xai": return "xmark"
        case "grok": return "hammer"
        case "zai": return "cpu"
        case "cursor": return "cursorarrow.rays"
        case "kimi_code": return "moon.stars.circle"
        default: return "gauge.with.dots.needle.33percent"
        }
    }

    static func tint(for providerId: String) -> Color {
        switch providerId {
        case "claude": return Color(red: 0.91, green: 0.54, blue: 0.41)
        case "codex", "openai": return Color(red: 0.40, green: 0.76, blue: 0.69)
        case "openrouter": return Color(red: 0.60, green: 0.58, blue: 0.88)
        case "deepseek": return Color(red: 0.38, green: 0.66, blue: 0.92)
        case "moonshot", "moonshot_cn": return Color(red: 0.72, green: 0.66, blue: 0.91)
        case "minimax", "minimax_cn": return VigilPalette.caution
        case "github": return Color(red: 0.74, green: 0.79, blue: 0.83)
        case "xai": return Color(red: 0.82, green: 0.84, blue: 0.86)
        case "grok": return Color(red: 0.92, green: 0.92, blue: 0.94)
        case "zai": return Color(red: 0.49, green: 0.69, blue: 0.88)
        case "cursor": return Color(red: 0.73, green: 0.62, blue: 0.90)
        case "kimi_code": return Color(red: 0.55, green: 0.60, blue: 0.95)
        default: return VigilPalette.signal
        }
    }

    static func setupLabel(for spec: ProviderSpec) -> String {
        switch spec.id {
        case "github": return "Personal access token"
        case "openai": return "Admin API key"
        case "xai": return "Management key"
        case "grok": return "Grok Build session token"
        case "cursor": return "Session cookie"
        default: break
        }
        switch spec.auth {
        case "api_key_bearer": return "API key"
        case "web_session_cookie": return "Session cookie"
        default: return "Access token"
        }
    }

    static func credentialWarning(for spec: ProviderSpec) -> String? {
        guard spec.id == "openai" else { return nil }
        return "\(openAIAdminCredentialDisclosure) Use a dedicated key and revoke it when you disconnect permanently."
    }
}

/// The one "Experimental" chip every surface reuses — styled after the
/// account card's plan capsule, tinted orange so it reads as a caution, not
/// a feature.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(VigilPalette.caution.opacity(0.13), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(VigilPalette.caution.opacity(0.3), lineWidth: 1)
            }
            .foregroundStyle(VigilPalette.caution)
            .accessibilityLabel(Text("Experimental integration"))
    }
}

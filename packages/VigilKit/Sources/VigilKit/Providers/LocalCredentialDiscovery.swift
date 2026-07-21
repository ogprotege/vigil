import Foundation

/// Local credential discovery for Claude Code / Codex CLI files — the
/// token-monitor-style path that reads what is already on disk, with no browser
/// OAuth and no `npx vigil-link`. Mirrors `cli/src/discovery/claude.ts` and
/// `cli/src/discovery/codex.ts` so Mac import and the CLI stay lockstep.
///
/// Resulting credentials use `source: "file"` (never auto-refreshed — ADR-0005).
/// When the CLI session expires, the user re-imports.
public enum LocalCredentialDiscovery {
    public static let fileSource = "file"

    public struct ClaudeResult: Equatable, Sendable {
        public let credentials: Credentials
        public let location: Location

        public enum Location: String, Equatable, Sendable {
            case file
            case keychain
        }
    }

    public struct CodexResult: Equatable, Sendable {
        public let credentials: Credentials
        public let filePath: String
    }

    // The default-path helpers below are macOS-only: `homeDirectoryForCurrentUser`
    // is unavailable on iOS, and there are no Claude Code / Codex CLI files inside
    // an iOS sandbox. The `parse*` functions stay cross-platform — they are pure.
#if os(macOS)
    /// Default Claude Code credentials file (`~/.claude/.credentials.json`).
    public static func defaultClaudeCredentialsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    /// Default Codex auth file (`~/.codex/auth.json`), honoring `CODEX_HOME`.
    public static func defaultCodexAuthURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }
#endif

    /// Parses Claude Code's credentials JSON (file or Keychain blob).
    public static func parseClaudeCredentials(json: String) -> Credentials? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let blob = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let accessToken = string(blob["accessToken"]), !accessToken.isEmpty else {
            return nil
        }

        var credentials = Credentials(
            providerId: "claude",
            accessToken: accessToken,
            source: fileSource
        )
        credentials.refreshToken = string(blob["refreshToken"])
        if let expiresAt = number(blob["expiresAt"]) {
            // Claude Code stores expiresAt in epoch milliseconds.
            let seconds = expiresAt > 1e12 ? floor(expiresAt / 1000) : expiresAt
            credentials.expiresAt = Date(timeIntervalSince1970: seconds)
        }
        if let plan = string(blob["subscriptionType"]), !plan.isEmpty {
            credentials.plan = plan
            credentials.label = "Claude (\(plan))"
        } else {
            credentials.label = "Claude"
        }
        return credentials
    }

    /// Parses Codex CLI's `auth.json`.
    public static func parseCodexCredentials(json: String, filePath: String = "") -> Credentials? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tokens = (root["tokens"] as? [String: Any]) ?? root
        guard let accessToken = string(tokens["access_token"]), !accessToken.isEmpty else {
            return nil
        }

        let idToken = string(tokens["id_token"])
        let identity = CodexAuth.identity(fromIdToken: idToken)
        let accountId = string(tokens["account_id"]) ?? identity.accountId
        guard let accountId, !accountId.isEmpty else { return nil }

        var credentials = Credentials(
            providerId: "codex",
            accessToken: accessToken,
            source: fileSource
        )
        credentials.refreshToken = string(tokens["refresh_token"])
        credentials.accountId = accountId
        credentials.plan = identity.plan
        credentials.label = [
            identity.plan.map { "ChatGPT (\($0))" } ?? "ChatGPT",
            identity.email,
        ].compactMap { $0 }.joined(separator: " — ")

        if let payload = CodexAuth.decodeJWTPayload(accessToken),
           let exp = payload["exp"] as? Double {
            credentials.expiresAt = Date(timeIntervalSince1970: exp)
        } else if let payload = CodexAuth.decodeJWTPayload(accessToken),
                  let exp = payload["exp"] as? Int {
            credentials.expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
        }

        // filePath is unused in Credentials but kept for caller diagnostics.
        _ = filePath
        return credentials
    }

#if os(macOS)
    /// Reads Claude credentials from the default file path when present.
    public static func loadClaudeFromDefaultFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeResult? {
        let url = defaultClaudeCredentialsURL(home: home)
        guard let json = try? String(contentsOf: url, encoding: .utf8),
              let credentials = parseClaudeCredentials(json: json)
        else { return nil }
        return ClaudeResult(credentials: credentials, location: .file)
    }

    /// Reads Codex credentials from the default auth path when present.
    public static func loadCodexFromDefaultFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexResult? {
        let url = defaultCodexAuthURL(home: home, environment: environment)
        guard let json = try? String(contentsOf: url, encoding: .utf8),
              let credentials = parseCodexCredentials(json: json, filePath: url.path)
        else { return nil }
        return CodexResult(credentials: credentials, filePath: url.path)
    }
#endif

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }
}

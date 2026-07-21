import SwiftUI
import VigilKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

#if os(macOS)
/// Mac-only local import — reads Claude Code / Codex files already on this Mac
/// (token-monitor style). No browser OAuth, no `npx vigil-link`.
struct LocalImportView: View {
    let onImported: (Credentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header
                    claudeCard
                    codexCard
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? VigilPalette.caution : VigilPalette.safe)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    footnote
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Import from this Mac")
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ProgressView("Importing…")
                        .padding(24)
                        .vigilCard(padding: VigilSpacing.large)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "Local files")
            Text("Use what's already signed in.")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Vigil reads Claude Code and Codex credentials from this Mac — no browser, no terminal, no npm package.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(spacing: 12) {
                VigilProviderMark(providerId: "claude", displayName: "Claude", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                    Text("~/.claude/.credentials.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
            Button {
                Task { await importClaude() }
            } label: {
                Label("Import Claude from this Mac", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)

            Button("Choose credentials file…") {
                pickClaudeFile()
            }
            .buttonStyle(.bordered)
            .tint(VigilPalette.inkMuted)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var codexCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(spacing: 12) {
                VigilProviderMark(providerId: "codex", displayName: "ChatGPT / Codex", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex / ChatGPT")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                    Text("~/.codex/auth.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
            Button {
                importCodex()
            } label: {
                Label("Import Codex from this Mac", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)

            Button("Choose auth.json…") {
                pickCodexFile()
            }
            .buttonStyle(.bordered)
            .tint(VigilPalette.inkMuted)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var footnote: some View {
        Text("Imported sessions are not auto-renewed by Vigil (they belong to Claude Code / Codex). Re-import when they expire, or use Sign in with Claude / Codex to mint a Vigil-owned renewing token.")
            .font(.caption2)
            .foregroundStyle(VigilPalette.inkFaint)
    }

    /// Runs the lookup off the main actor. The Keychain half reads an item
    /// owned by Claude Code, so `SecItemCopyMatching` can block on a securityd
    /// access prompt — on the main actor that freezes the window with no
    /// spinner and no way out, on exactly the configuration this path exists to
    /// serve.
    private func importClaude() async {
        isImporting = true
        defer { isImporting = false }
        let discovered = await Task.detached(priority: .userInitiated) {
            LocalCredentialDiscovery.loadClaudeFromDefaultFile()
        }.value
        if let result = discovered {
            let origin = result.location == .keychain
                ? "the login Keychain"
                : "~/.claude/.credentials.json"
            finish(result.credentials, note: "Imported Claude from \(origin)")
            return
        }
        statusIsError = true
        // Both sources failed. On macOS Claude Code often keeps its session in
        // the login Keychain and writes no file, and Vigil's sandbox may be
        // refused access to another app's item — so naming only the file would
        // send a signed-in user to a path that does not exist.
        statusMessage = "Couldn't read Claude credentials from ~/.claude/.credentials.json or the login Keychain. If Claude Code keeps your session in the Keychain, macOS may have denied Vigil access — paste an access token instead, or choose the file manually if you have one."
    }

    private func importCodex() {
        isImporting = true
        defer { isImporting = false }
        if let result = LocalCredentialDiscovery.loadCodexFromDefaultFile() {
            finish(result.credentials, note: "Imported Codex from \(result.filePath)")
            return
        }
        statusIsError = true
        statusMessage = "Couldn't find ~/.codex/auth.json. Run `codex login` first, or choose the file manually."
    }

    private func pickClaudeFile() {
        guard let url = chooseJSONFile(
            title: "Choose Claude credentials.json",
            startingAt: LocalCredentialDiscovery.realHomeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
        ) else { return }
        guard url.startAccessingSecurityScopedResource() else {
            statusIsError = true
            statusMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            guard let credentials = LocalCredentialDiscovery.parseClaudeCredentials(json: json) else {
                statusIsError = true
                statusMessage = "That file doesn't look like Claude Code credentials."
                return
            }
            finish(credentials, note: "Imported Claude from \(url.lastPathComponent)")
        } catch {
            statusIsError = true
            statusMessage = "Couldn't read that file."
        }
    }

    private func pickCodexFile() {
        guard let url = chooseJSONFile(
            title: "Choose Codex auth.json",
            startingAt: LocalCredentialDiscovery.defaultCodexAuthURL()
                .deletingLastPathComponent()
        ) else { return }
        guard url.startAccessingSecurityScopedResource() else {
            statusIsError = true
            statusMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            guard let credentials = LocalCredentialDiscovery.parseCodexCredentials(
                json: json,
                filePath: url.path
            ) else {
                statusIsError = true
                statusMessage = "That file doesn't look like Codex auth.json (needs access_token + account_id)."
                return
            }
            finish(credentials, note: "Imported Codex from \(url.lastPathComponent)")
        } catch {
            statusIsError = true
            statusMessage = "Couldn't read that file."
        }
    }

    /// Both targets are hidden — `.credentials.json` is a dot-file inside the
    /// dot-directory `.claude`, and `.codex` is a dot-directory. NSOpenPanel
    /// hides both by default, so a user told to "choose the file manually"
    /// would open the panel onto an apparently empty home folder unless they
    /// happened to know Cmd+Shift+period. Show hidden entries and start in the
    /// directory the copy actually names.
    private func chooseJSONFile(title: String, startingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .data]
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if let directory {
            panel.directoryURL = directory
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func finish(_ credentials: Credentials, note: String) {
        statusIsError = false
        statusMessage = note
        onImported(credentials)
        dismiss()
    }
}
#endif

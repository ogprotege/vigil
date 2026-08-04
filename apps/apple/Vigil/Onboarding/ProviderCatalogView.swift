import SwiftUI
import VigilKit

/// Direct-credential providers remain available without competing with guided
/// sign-in. Claude and ChatGPT/Codex use their first-class guided routes for
/// both initial setup and re-linking.
struct ProviderCatalogView: View {
    let onSubmit: (Credentials) -> Void

    @State private var query = ""
    @State private var showExperimental = false

    static var availableProviders: [ProviderSpec] {
        ProviderRegistry.all.filter { spec in
            spec.id != "claude" && spec.id != "codex" && spec.id != "grok"
        }
    }

    private var matchingProviders: [ProviderSpec] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Self.availableProviders }
        return Self.availableProviders.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    private var established: [ProviderSpec] {
        matchingProviders.filter { !$0.experimental }
    }

    private var experimental: [ProviderSpec] {
        matchingProviders.filter(\.experimental)
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VigilSpacing.medium) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Other providers")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(VigilPalette.ink)
                        Text("Choose a provider, then enter the credential it issues.")
                            .font(.subheadline)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }

                    providerSection(established)

                    if !experimental.isEmpty {
                        DisclosureGroup(isExpanded: $showExperimental) {
                            providerSection(experimental)
                                .padding(.top, 10)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Experimental providers")
                                    .font(.headline)
                                    .foregroundStyle(VigilPalette.ink)
                                Text("Community-documented endpoints can change without notice.")
                                    .font(.caption)
                                    .foregroundStyle(VigilPalette.inkMuted)
                            }
                        }
                        .tint(VigilPalette.caution)
                        .padding(14)
                        .vigilInsetSurface()
                    }

                    if matchingProviders.isEmpty {
                        ContentUnavailableView(
                            "No provider found",
                            systemImage: "magnifyingglass",
                            description: Text("Try a provider name or clear the search.")
                        )
                        .foregroundStyle(VigilPalette.inkMuted)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Other provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, prompt: "Search providers")
    }

    @ViewBuilder
    private func providerSection(_ providers: [ProviderSpec]) -> some View {
        VStack(spacing: 10) {
            ForEach(providers, id: \.id) { spec in
                NavigationLink {
                    ManualEntryView(
                        providerId: spec.id,
                        locksProvider: true,
                        onSubmit: onSubmit
                    )
                } label: {
                    ProviderSetupRow(spec: spec)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProviderSetupRow: View {
    let spec: ProviderSpec

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    providerIdentity
                    setupLabel
                }
            } else {
                HStack(spacing: 12) {
                    providerIdentity
                    Spacer(minLength: 8)
                    setupLabel
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .vigilInsetSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens direct setup")
    }

    private var providerIdentity: some View {
        HStack(spacing: 12) {
            VigilProviderMark(
                providerId: spec.id,
                displayName: spec.displayName,
                size: 40
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if spec.experimental {
                    ExperimentalBadge()
                }
            }
        }
    }

    private var setupLabel: some View {
        HStack(spacing: 6) {
            Text(ProviderPresentation.setupLabel(for: spec))
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(VigilPalette.inkFaint)
                .accessibilityHidden(true)
        }
    }
}

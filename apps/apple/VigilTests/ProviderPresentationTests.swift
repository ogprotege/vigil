import Foundation
import XCTest
import VigilKit
@testable import Vigil

/// Spec-derived UI decisions: which providers need an account id, what the
/// input field is called, and which integrations carry the Experimental
/// label. Policy is data — these assertions read ProviderRegistry rather
/// than a provider list a surface could drift from. Style follows
/// AppModelReliabilityTests.
final class ProviderPresentationTests: XCTestCase {
    // MARK: - Manual entry provider coverage

    func testRegistryExposesAllFifteenProvidersWithDistinctIds() {
        XCTAssertEqual(
            ProviderRegistry.all.count, 15,
            "The registry must retain every supported guided and direct-entry provider"
        )
        XCTAssertEqual(
            Set(ProviderRegistry.all.map(\.id)).count,
            ProviderRegistry.all.count,
            "Duplicate ids would collapse picker rows and account keys"
        )
    }

    func testOtherProviderCatalogExcludesGuidedSetupWithoutRemovingRecoverySpecs() {
        let catalogIDs = Set(ProviderCatalogView.availableProviders.map(\.id))

        XCTAssertEqual(
            catalogIDs.count,
            ProviderRegistry.all.count - SetupRoute.guidedProviderIds.count
        )
        XCTAssertFalse(catalogIDs.contains("claude"))
        XCTAssertFalse(catalogIDs.contains("codex"))
        XCTAssertFalse(catalogIDs.contains("openrouter"))
        XCTAssertFalse(catalogIDs.contains("grok"))
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "claude"),
            "Claude direct entry must remain available to targeted recovery flows"
        )
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "codex"),
            "Codex direct entry must remain available to targeted recovery flows"
        )
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "openrouter"),
            "OpenRouter direct entry must remain available from its guided fallback"
        )
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "grok"),
            "Grok Build direct entry must remain available to targeted recovery flows"
        )
    }

    func testGuidedRoutesAndDirectCatalogCoverEveryRegistryProviderExactlyOnce() {
        let registryIDs = Set(ProviderRegistry.all.map(\.id))
        let guidedIDs = SetupRoute.guidedProviderIds
        let directIDs = Set(ProviderCatalogView.availableProviders.map(\.id))

        XCTAssertTrue(
            guidedIDs.isDisjoint(with: directIDs),
            "A provider must not compete in both guided setup and the direct catalog"
        )
        XCTAssertEqual(
            guidedIDs.union(directIDs),
            registryIDs,
            "Every registered provider must be reachable through guided or direct setup"
        )
    }

    func testSetupRoutePresentationIsCompleteAndStable() {
        XCTAssertEqual(
            SetupRoute.allCases.map(\.rawValue),
            ["claude", "codex", "openrouter", "grok", "other"]
        )
        XCTAssertEqual(
            SetupRoute.openrouter.accessibilityIdentifier,
            "vigil.setup.openrouter"
        )
        XCTAssertEqual(SetupRoute.grok.accessibilityIdentifier, "vigil.setup.grok")
        XCTAssertEqual(
            Set(SetupRoute.allCases.map(\.accessibilityIdentifier)).count,
            SetupRoute.allCases.count
        )
        for route in SetupRoute.allCases {
            XCTAssertFalse(route.symbol.isEmpty)
            XCTAssertFalse(route.title.isEmpty)
            XCTAssertFalse(route.detail.isEmpty)
        }
    }

    func testManualGrokRecoveryAcceptsOnlyTheSessionAccessToken() throws {
        let grok = try XCTUnwrap(ProviderRegistry.spec(for: "grok"))
        let claude = try XCTUnwrap(ProviderRegistry.spec(for: "claude"))

        XCTAssertFalse(ProviderPresentation.acceptsManualRefreshToken(grok))
        XCTAssertTrue(
            ProviderPresentation.acceptsManualRefreshToken(claude),
            "This test isolates Grok's one-token CLI recovery policy"
        )
    }

    func testEveryProviderShipsManualEntryGuidance() {
        for spec in ProviderRegistry.all {
            XCTAssertFalse(
                (spec.manualEntryHint ?? "").isEmpty,
                "\(spec.id) has no manualEntryHint — manual entry would show only the generic fallback copy"
            )
        }
    }

    // MARK: - Account-id requirement (spec templates → needsAccountId)

    func testAccountIdNeedIsDerivedFromSpecTemplates() {
        let required = Set(
            ProviderRegistry.all
                .filter { ProviderPresentation.needsAccountId($0) }
                .map(\.id)
        )
        XCTAssertEqual(
            required,
            ["codex", "github", "xai"],
            "Account-id need must come from {account_id} placeholders in the spec, not a hardcoded provider list"
        )
    }

    func testURLTemplateAloneTriggersAccountIdRequirement() throws {
        // GitHub and xAI keep {account_id} only in the URL template — this
        // guards the non-header path a header-only check would miss.
        for id in ["github", "xai"] {
            let spec = try XCTUnwrap(ProviderRegistry.spec(for: id))
            XCTAssertFalse(
                spec.headers.values.contains { $0.contains("{account_id}") },
                "\(id) moved {account_id} into a header — update this test's premise"
            )
            XCTAssertTrue(ProviderPresentation.needsAccountId(spec))
        }
    }

    func testAccountIdFieldLabelsMatchProviderVocabulary() throws {
        let github = try XCTUnwrap(ProviderRegistry.spec(for: "github"))
        let xai = try XCTUnwrap(ProviderRegistry.spec(for: "xai"))
        let codex = try XCTUnwrap(ProviderRegistry.spec(for: "codex"))

        XCTAssertEqual(ProviderPresentation.accountIdLabel(for: github), "GitHub username")
        XCTAssertEqual(ProviderPresentation.accountIdLabel(for: xai), "Team ID")
        XCTAssertEqual(
            ProviderPresentation.accountIdLabel(for: codex), "Account ID",
            "Codex keeps the pre-expansion wording"
        )
    }

    // MARK: - Experimental labeling

    func testExperimentalFlagCoversExactlyTheUnverifiedIntegrations() {
        XCTAssertEqual(
            Set(ProviderRegistry.all.filter(\.experimental).map(\.id)),
            ["minimax", "minimax_cn", "zai", "cursor", "kimi_code", "grok"],
            "Experimental marks undocumented or community-researched endpoints; vendor-documented providers must not carry it"
        )
    }

    func testIsExperimentalResolvesFromProviderId() {
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "cursor"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "zai"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "minimax"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "minimax_cn"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "grok"))
        XCTAssertFalse(ProviderPresentation.isExperimental(providerId: "moonshot"))
        XCTAssertFalse(ProviderPresentation.isExperimental(providerId: "moonshot_cn"))
        XCTAssertFalse(ProviderPresentation.isExperimental(providerId: "xai"))
        XCTAssertFalse(ProviderPresentation.isExperimental(providerId: "claude"))
        XCTAssertFalse(
            ProviderPresentation.isExperimental(providerId: "no-such-provider"),
            "An unknown provider must not be labeled — absence of a spec proves nothing"
        )
    }

    func testPickerTitleAppendsExperimentalSuffixOnlyWhenFlagged() throws {
        let cursor = try XCTUnwrap(ProviderRegistry.spec(for: "cursor"))
        let claude = try XCTUnwrap(ProviderRegistry.spec(for: "claude"))

        XCTAssertEqual(ProviderPresentation.pickerTitle(for: cursor), "Cursor (Experimental)")
        XCTAssertEqual(ProviderPresentation.pickerTitle(for: claude), "Claude")
    }

    func testOpenAIAdminCredentialDisclosureStatesAuthorityAndActualUse() throws {
        let openAI = try XCTUnwrap(ProviderRegistry.spec(for: "openai"))
        let hint = try XCTUnwrap(openAI.manualEntryHint)
        let warning = try XCTUnwrap(
            ProviderPresentation.credentialWarning(for: openAI)
        )

        for copy in [
            hint,
            ProviderPresentation.openAIAdminCredentialDisclosure,
            warning,
        ] {
            let normalized = copy.lowercased()
            XCTAssertTrue(normalized.contains("broad organization-owner"))
            XCTAssertTrue(
                normalized.contains("not read-only")
                    || normalized.contains("not a read-only")
            )
            XCTAssertTrue(normalized.contains("vigil sends only documented get requests"))
            XCTAssertTrue(normalized.contains("usage and costs"))
            XCTAssertTrue(normalized.contains("regular project keys"))
            XCTAssertTrue(normalized.contains("cannot access"))
            XCTAssertFalse(normalized.contains("create a read-only"))
            XCTAssertFalse(normalized.contains("paste a read-only"))
        }
        XCTAssertEqual(openAI.usageMethod, "GET")
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("dedicated"))
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("revoke"))
        XCTAssertNil(
            ProviderPresentation.credentialWarning(
                for: try XCTUnwrap(ProviderRegistry.spec(for: "github"))
            )
        )
    }

    func testCredentialWarningsCoverBroadAndRestrictedCredentials() throws {
        for id in ["openrouter", "deepseek", "moonshot", "moonshot_cn"] {
            let warning = try XCTUnwrap(
                ProviderPresentation.credentialWarning(
                    for: try XCTUnwrap(ProviderRegistry.spec(for: id))
                ),
                "\(id) must disclose that its key can authorize spending"
            ).lowercased()
            XCTAssertTrue(warning.contains("spending"))
            XCTAssertTrue(warning.contains("dedicated key"))
            XCTAssertTrue(warning.contains("revoke"))
        }

        let cursorWarning = try XCTUnwrap(
            ProviderPresentation.credentialWarning(
                for: try XCTUnwrap(ProviderRegistry.spec(for: "cursor"))
            )
        ).lowercased()
        XCTAssertTrue(cursorWarning.contains("full browser session cookie"))
        XCTAssertTrue(cursorWarning.contains("not a usage-only credential"))
        XCTAssertTrue(cursorWarning.contains("revoke"))

        for id in ["zai", "kimi_code"] {
            let warning = try XCTUnwrap(
                ProviderPresentation.credentialWarning(
                    for: try XCTUnwrap(ProviderRegistry.spec(for: id))
                )
            ).lowercased()
            XCTAssertTrue(warning.contains("not currently listed"))
            XCTAssertTrue(warning.contains("authorized"))
        }
    }
}

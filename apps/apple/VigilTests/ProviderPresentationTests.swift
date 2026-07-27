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

    func testRegistryExposesAllFourteenProvidersWithDistinctIds() {
        XCTAssertEqual(
            ProviderRegistry.all.count, 14,
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

        XCTAssertEqual(catalogIDs.count, ProviderRegistry.all.count - 2)
        XCTAssertFalse(catalogIDs.contains("claude"))
        XCTAssertFalse(catalogIDs.contains("codex"))
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "claude"),
            "Claude direct entry must remain available to targeted recovery flows"
        )
        XCTAssertNotNil(
            ProviderRegistry.spec(for: "codex"),
            "Codex direct entry must remain available to targeted recovery flows"
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
            ["minimax", "minimax_cn", "zai", "cursor", "kimi_code"],
            "Experimental marks undocumented or community-researched endpoints; vendor-documented providers must not carry it"
        )
    }

    func testIsExperimentalResolvesFromProviderId() {
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "cursor"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "zai"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "minimax"))
        XCTAssertTrue(ProviderPresentation.isExperimental(providerId: "minimax_cn"))
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
                for: try XCTUnwrap(ProviderRegistry.spec(for: "openrouter"))
            )
        )
    }
}

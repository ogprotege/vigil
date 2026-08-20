import XCTest
import VigilKit
@testable import Vigil

final class UsagePresentationTests: XCTestCase {
    func testPlanTitlesNormalizeKnownIdentifiersWithoutCorruptingProductCase() {
        XCTAssertEqual(UsagePresentation.planTitle("pro"), "Pro")
        XCTAssertEqual(UsagePresentation.planTitle("plus"), "Plus")
        XCTAssertEqual(UsagePresentation.planTitle("ChatGPT API Team"), "ChatGPT API Team")
    }

    func testSessionUsesProviderWindowDuration() {
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "session", used: 40, seconds: 18_000)
            ),
            "5-hour limit"
        )
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "session", used: 40, seconds: 3_600)
            ),
            "Hourly limit"
        )
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "session", used: 40, seconds: nil)
            ),
            "Session limit"
        )
    }

    func testKnownPeriodAndModelLabelsRemainSpecific() {
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "weekly", used: 20, seconds: 604_800)
            ),
            "Weekly limit"
        )
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "weekly_sonnet", used: 20, secondary: true)
            ),
            "Sonnet weekly"
        )
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(id: "weekly_opus", used: 20, secondary: true)
            ),
            "Opus weekly"
        )
        XCTAssertEqual(
            UsagePresentation.title(for: window(id: "plan", used: 20)),
            "Plan limit"
        )
        XCTAssertEqual(
            UsagePresentation.category(
                for: window(id: "monthly", used: 20, secondary: true)
            ),
            "MONTHLY WINDOW"
        )
        XCTAssertTrue(
            UsagePresentation.isModelWindow(
                window(id: "weekly_opus", used: 20, secondary: true)
            )
        )
    }

    func testModelScopedWindowUsesLabelAndReadsAsModelLimit() {
        let scoped = window(
            id: "weekly_scoped_fable",
            used: 55,
            seconds: 604_800,
            secondary: true,
            label: "Fable"
        )
        XCTAssertEqual(UsagePresentation.title(for: scoped), "Fable weekly")
        XCTAssertEqual(UsagePresentation.category(for: scoped), "MODEL LIMIT")
        XCTAssertTrue(UsagePresentation.isModelWindow(scoped))
    }

    func testCurrentCodexModelLaneContractIsGroupedAsModelLimits() {
        for id in ["codex_bengalfox_session", "codex_bengalfox_weekly"] {
            let codexModelLane = window(
                id: id,
                used: 20,
                secondary: true,
                label: "GPT-5.3-Codex-Spark"
            )

            XCTAssertTrue(
                UsagePresentation.isModelWindow(
                    codexModelLane,
                    providerId: "codex"
                )
            )
            XCTAssertEqual(
                UsagePresentation.category(
                    for: codexModelLane,
                    providerId: "codex"
                ),
                "MODEL LIMIT"
            )
        }
    }

    func testCurrentCursorModelLaneContractIsGroupedAsModelLimits() {
        let auto = window(
            id: "plan_auto",
            used: 40,
            secondary: true,
            label: "Auto-selected models"
        )
        let api = window(
            id: "plan_api",
            used: 50,
            secondary: true,
            label: "API models"
        )

        XCTAssertTrue(
            UsagePresentation.isModelWindow(auto, providerId: "cursor")
        )
        XCTAssertTrue(
            UsagePresentation.isModelWindow(api, providerId: "cursor")
        )
        XCTAssertEqual(
            UsagePresentation.category(for: auto, providerId: "cursor"),
            "MODEL LIMIT"
        )
        XCTAssertEqual(
            UsagePresentation.category(for: api, providerId: "cursor"),
            "MODEL LIMIT"
        )
    }

    func testUnknownCodexAndCursorShapedLanesRemainSpecialLimits() {
        for candidate in [
            window(
                id: "nested_lane_session",
                used: 7,
                secondary: true,
                label: "Generic metered feature"
            ),
            window(
                id: "plan_custom",
                used: 12,
                secondary: true,
                label: "Custom plan lane"
            ),
        ] {
            XCTAssertFalse(
                UsagePresentation.isModelWindow(
                    candidate,
                    providerId: candidate.id.hasPrefix("plan_")
                        ? "cursor"
                        : "codex"
                )
            )
            XCTAssertEqual(
                UsagePresentation.category(
                    for: candidate,
                    providerId: candidate.id.hasPrefix("plan_")
                        ? "cursor"
                        : "codex"
                ),
                "SPECIAL LIMIT"
            )
        }
    }

    func testProviderScopedModelIdsDoNotLeakAcrossProviders() {
        let cursorLane = window(
            id: "plan_api",
            used: 20,
            secondary: true,
            label: "API models"
        )
        let codexLane = window(
            id: "codex_bengalfox_weekly",
            used: 20,
            secondary: true,
            label: "GPT-5.3-Codex-Spark"
        )

        XCTAssertFalse(
            UsagePresentation.isModelWindow(cursorLane, providerId: "openai")
        )
        XCTAssertFalse(
            UsagePresentation.isModelWindow(codexLane, providerId: "cursor")
        )
    }

    func testVideoCategoryWindowsHaveSpecificTitlesAndSpecialCategory() {
        let session = window(id: "session_video", used: 0, secondary: true)
        let weekly = window(id: "weekly_video", used: 0, secondary: true)
        XCTAssertEqual(UsagePresentation.title(for: session), "Video session")
        XCTAssertEqual(UsagePresentation.title(for: weekly), "Video weekly")
        XCTAssertEqual(UsagePresentation.category(for: session), "SPECIAL LIMIT")
        XCTAssertEqual(UsagePresentation.category(for: weekly), "SPECIAL LIMIT")
        XCTAssertFalse(UsagePresentation.isModelWindow(session))
        XCTAssertFalse(UsagePresentation.isModelWindow(weekly))
    }

    func testProviderSuppliedSpecialModelNameIsHumanizedWithoutLosingIdentity() {
        XCTAssertEqual(
            UsagePresentation.title(
                for: window(
                    id: "gpt-5-codex-spark",
                    used: 12,
                    seconds: 604_800,
                    secondary: true
                )
            ),
            "GPT-5-Codex-Spark"
        )
    }

    func testRemainingPercentIsClampedAndUnambiguous() {
        XCTAssertEqual(
            UsagePresentation.remainingPercent(
                for: window(id: "session", used: 71.5)
            ),
            28.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            UsagePresentation.remainingPercent(
                for: window(id: "session", used: 120)
            ),
            0
        )
        XCTAssertEqual(
            UsagePresentation.remainingPercent(
                for: window(id: "session", used: -20)
            ),
            100
        )
    }

    func testAllWindowKindsStayVisibleInStablePresentationOrder() {
        let windows = [
            window(id: "weekly_opus", used: 20, secondary: true),
            window(id: "plan", used: 20),
            window(id: "weekly", used: 20),
            window(id: "session", used: 20),
            window(id: "monthly", used: 20, secondary: true),
        ]

        XCTAssertEqual(
            UsagePresentation.sortedWindows(windows).map(\.id),
            ["session", "weekly", "monthly", "plan", "weekly_opus"]
        )
    }

    func testRetainedReadingsDoNotCallThePercentageLive() {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_000)
        let window = window(id: "session", used: 40, seconds: 18_000)
        let offline = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: "pro",
            fetchedAt: fetchedAt,
            status: .network,
            windows: [window]
        )
        let note = UsagePresentation.limitSourceNote(
            snapshot: offline,
            accountPlan: "pro",
            at: fetchedAt
        )
        XCTAssertTrue(note.contains("retained from the last accepted provider reading"))
        XCTAssertTrue(note.contains("last accepted reading"))
        XCTAssertFalse(
            note.localizedCaseInsensitiveContains("live percentage"),
            "Retained percentages must not be described as live: \(note)"
        )

        let live = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: "pro",
            fetchedAt: fetchedAt,
            status: .ok,
            windows: [window]
        )
        let liveNote = UsagePresentation.limitSourceNote(
            snapshot: live,
            accountPlan: "pro",
            at: fetchedAt
        )
        XCTAssertTrue(liveNote.contains("live percentage already reflects that tier"))

        let stale = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: "pro",
            fetchedAt: fetchedAt.addingTimeInterval(-(SnapshotFreshness.staleAfter + 1)),
            status: .ok,
            windows: [window]
        )
        let staleNote = UsagePresentation.limitSourceNote(
            snapshot: stale,
            accountPlan: "pro",
            at: fetchedAt
        )
        XCTAssertTrue(staleNote.contains("last accepted reading"))
        XCTAssertFalse(
            staleNote.localizedCaseInsensitiveContains("live percentage"),
            "Stale accepted percentages must not be described as live: \(staleNote)"
        )
    }

    func testAcceptedFreshnessPrefixNamesStaleData() {
        XCTAssertEqual(
            UsagePresentation.acceptedFreshnessPrefix(resetPending: false, stale: false),
            "Checked "
        )
        XCTAssertTrue(
            UsagePresentation.acceptedFreshnessPrefix(resetPending: false, stale: true)
                .hasPrefix("Stale.")
        )
        XCTAssertFalse(
            UsagePresentation.acceptedFreshnessPrefix(resetPending: false, stale: true)
                .hasPrefix("Checked ")
        )
    }

    func testHiddenWidgetCopyShowsProviderAndOmitsAccountLabel() {
        let account = AccountRef(
            key: "claude:secret",
            providerId: "claude",
            label: "Personal",
            plan: "pro"
        )
        XCTAssertEqual(
            UsagePresentation.hiddenWidgetProviderTitle(account: account, providerId: "claude"),
            "Claude"
        )
        XCTAssertFalse(
            UsagePresentation.hiddenWidgetProviderTitle(account: account, providerId: "claude")
                .localizedCaseInsensitiveContains("personal")
        )
        XCTAssertEqual(
            UsagePresentation.hiddenWidgetProviderTitle(account: nil, providerId: "claude"),
            "Claude"
        )
        let spoken = UsagePresentation.hiddenUsageAccessibilityLabel(providerDisplayName: "Claude")
        XCTAssertTrue(spoken.hasPrefix("Claude."))
        XCTAssertTrue(spoken.contains("Usage values hidden"))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("personal"))
    }

    func testSurfaceStatusTitleDistinguishesStaleOfflineAndLive() {
        let now = Date()
        let live = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now,
            status: .ok,
            windows: [window(id: "session", used: 10)]
        )
        XCTAssertEqual(UsagePresentation.surfaceStatusTitle(snapshot: live, at: now), "Live")

        let stale = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now.addingTimeInterval(-(SnapshotFreshness.staleAfter + 1)),
            status: .ok,
            windows: [window(id: "session", used: 10)]
        )
        XCTAssertEqual(UsagePresentation.surfaceStatusTitle(snapshot: stale, at: now), "Stale")

        let offline = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now,
            status: .network,
            windows: [window(id: "session", used: 10)]
        )
        XCTAssertEqual(UsagePresentation.surfaceStatusTitle(snapshot: offline, at: now), "Offline")
        XCTAssertEqual(
            UsagePresentation.circularDegradedAccessibilitySuffix(snapshot: offline, at: now),
            ", offline"
        )
    }

    func testDegradedFreshnessDescribesDataAgeNotACheckTime() {
        // fetchedAt on a degraded snapshot is the moment the data was last
        // accepted, not the last poll attempt — polls may still run every
        // minute. The freshness line must age the data, never the "check".
        for status in [SnapshotStatus.schemaChanged, .authExpired, .network, .rateLimited] {
            let prefix = UsagePresentation.retainedFreshnessPrefix(status)
            XCTAssertTrue(
                prefix.hasPrefix(UsagePresentation.statusTitle(status)),
                "Prefix must lead with the status title: \(prefix)"
            )
            XCTAssertTrue(
                prefix.hasSuffix("data from "),
                "Prefix must age the retained data: \(prefix)"
            )
            XCTAssertFalse(
                prefix.localizedCaseInsensitiveContains("checked"),
                "Degraded freshness must not claim a check time: \(prefix)"
            )
        }
    }

    func testAccessibilityFreshnessNeverClaimsACheckTimeForRetainedData() {
        // The Home card replaces its combined children with one spoken
        // summary, so the honest-freshness rule must hold for that string
        // too: an ok snapshot's fetchedAt is a real check time, a degraded
        // snapshot's fetchedAt is when the shown data was last accepted.
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_000)
        for status in [SnapshotStatus.schemaChanged, .authExpired, .network, .rateLimited] {
            let clause = UsagePresentation.accessibilityFreshness(status: status, fetchedAt: fetchedAt)
            XCTAssertTrue(
                clause.hasPrefix("Data from "),
                "\(status) retains data, so the spoken freshness must age it: \(clause)"
            )
            XCTAssertFalse(
                clause.localizedCaseInsensitiveContains("checked"),
                "\(status)'s fetchedAt is not a check time, so nothing spoken may claim one: \(clause)"
            )
            XCTAssertGreaterThan(
                clause.count, "Data from ".count,
                "The spoken clause must carry a timestamp: \(clause)"
            )
        }

        let live = UsagePresentation.accessibilityFreshness(status: .ok, fetchedAt: fetchedAt)
        XCTAssertTrue(
            live.hasPrefix("Last checked "),
            "An ok snapshot's fetchedAt is a real check time and may say so: \(live)"
        )
        XCTAssertGreaterThan(
            live.count, "Last checked ".count,
            "The spoken clause must carry a timestamp: \(live)"
        )
    }

    private func window(
        id: String,
        used: Double,
        seconds: Int? = nil,
        secondary: Bool = false,
        label: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            utilization: used,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
            windowSeconds: seconds,
            secondary: secondary,
            label: label
        )
    }
}

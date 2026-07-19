import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class UsagePresentationTests: XCTestCase {
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
            UsagePresentation.title(
                for: window(id: "plan", used: 20)
            ),
            "Plan limit"
        )
        let monthly = window(id: "monthly", used: 20, secondary: true)
        XCTAssertEqual(UsagePresentation.category(for: monthly), "MONTHLY WINDOW")
        XCTAssertFalse(UsagePresentation.isSpecialWindow(monthly))
        XCTAssertTrue(
            UsagePresentation.isSpecialWindow(
                window(id: "weekly_opus", used: 20, secondary: true)
            )
        )
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

    func testWatchlineChoosesTightestWindowAcrossAccounts() throws {
        let claude = AccountRef(
            key: "claude:one",
            providerId: "claude",
            label: "Personal",
            plan: "max"
        )
        let codex = AccountRef(
            key: "codex:two",
            providerId: "codex",
            label: "Work",
            plan: "plus"
        )
        let claudeSnapshot = snapshot(
            account: claude,
            windows: [
                window(id: "session", used: 30),
                window(id: "weekly_sonnet", used: 92, secondary: true),
            ]
        )
        let codexSnapshot = snapshot(
            account: codex,
            windows: [
                window(id: "weekly", used: 78),
            ]
        )

        let result = try XCTUnwrap(
            UsagePresentation.closestLimit(
                accounts: [claude, codex],
                snapshots: [
                    claude.key: claudeSnapshot,
                    codex.key: codexSnapshot,
                ]
            )
        )

        XCTAssertEqual(result.account, claude)
        XCTAssertEqual(result.window.id, "weekly_sonnet")
        XCTAssertEqual(
            UsagePresentation.remainingPercent(for: result.window),
            8
        )
    }

    func testWatchlineCoverageReportsMissingAccountsInsteadOfClaimingLive() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let claude = AccountRef(
            key: "claude:one",
            providerId: "claude",
            label: "Personal",
            plan: "max"
        )
        let codex = AccountRef(
            key: "codex:two",
            providerId: "codex",
            label: "Work",
            plan: "plus"
        )
        let coverage = UsagePresentation.watchlineCoverage(
            accounts: [claude, codex],
            snapshots: [
                claude.key: snapshot(
                    account: claude,
                    windows: [window(id: "weekly", used: 40)],
                    fetchedAt: now
                ),
            ],
            at: now
        )

        XCTAssertEqual(coverage.linkedAccountCount, 2)
        XCTAssertEqual(coverage.windowAccountCount, 1)
        XCTAssertEqual(coverage.metricOnlyAccountCount, 0)
        XCTAssertEqual(coverage.unreliableAccountCount, 1)
        XCTAssertFalse(coverage.isComplete)
    }

    func testWatchlineCoverageRecognizesFreshMetricOnlyProviders() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let openAI = AccountRef(
            key: "openai:one",
            providerId: "openai",
            label: "Work",
            plan: nil
        )
        let metric = UsageMetric(
            id: "spend_month",
            label: "Spend",
            kind: .spend,
            value: 12,
            unit: "USD",
            secondary: false
        )
        let coverage = UsagePresentation.watchlineCoverage(
            accounts: [openAI],
            snapshots: [
                openAI.key: snapshot(
                    account: openAI,
                    windows: [],
                    metrics: [metric],
                    fetchedAt: now
                ),
            ],
            at: now
        )

        XCTAssertEqual(coverage.metricOnlyAccountCount, 1)
        XCTAssertEqual(coverage.unreliableAccountCount, 0)
        XCTAssertTrue(coverage.isComplete)
    }

    private func window(
        id: String,
        used: Double,
        seconds: Int? = nil,
        secondary: Bool = false
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            utilization: used,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
            windowSeconds: seconds,
            secondary: secondary
        )
    }

    private func snapshot(
        account: AccountRef,
        windows: [UsageWindow],
        metrics: [UsageMetric] = [],
        fetchedAt: Date = Date(),
        status: SnapshotStatus = .ok
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: fetchedAt,
            status: status,
            windows: windows,
            metrics: metrics
        )
    }
}

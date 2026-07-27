import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class AccountLimitSummaryTests: XCTestCase {
    func testResetWindowIsExcludedAndAccountCannotRemainLive() throws {
        let fetchedAt = Date(timeIntervalSince1970: 10_000)
        let evaluatedAt = fetchedAt.addingTimeInterval(301)
        let expired = UsageWindow(
            id: "session",
            utilization: 92,
            resetsAt: fetchedAt.addingTimeInterval(300),
            windowSeconds: 18_000,
            secondary: false
        )
        let current = UsageWindow(
            id: "weekly",
            utilization: 35,
            resetsAt: fetchedAt.addingTimeInterval(604_800),
            windowSeconds: 604_800,
            secondary: false
        )
        let account = AccountRef(
            key: "claude:test",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let snapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: account.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: fetchedAt,
            status: .ok,
            windows: [expired, current]
        )
        let summary = AccountLimitSummary(
            account: account,
            snapshot: snapshot,
            nextAllowed: nil,
            evaluatedAt: evaluatedAt
        )

        XCTAssertTrue(summary.resetPending)
        XCTAssertEqual(try XCTUnwrap(summary.decisiveWindow).id, "weekly")
        XCTAssertEqual(summary.displayStatusTitle, "Awaiting update")
        XCTAssertEqual(summary.displayStatusSymbol, "arrow.clockwise.circle")
        XCTAssertEqual(summary.actionRank, 1)
    }

    func testAllExpiredWindowsProduceNoPercentageCandidate() {
        let fetchedAt = Date(timeIntervalSince1970: 20_000)
        let account = AccountRef(
            key: "codex:test",
            providerId: "codex",
            label: nil,
            plan: "pro"
        )
        let snapshot = ProviderSnapshot(
            providerId: "codex",
            accountKey: account.key,
            accountLabel: nil,
            planLabel: "pro",
            fetchedAt: fetchedAt,
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: 74,
                    resetsAt: fetchedAt.addingTimeInterval(60),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
        let summary = AccountLimitSummary(
            account: account,
            snapshot: snapshot,
            nextAllowed: nil,
            evaluatedAt: fetchedAt.addingTimeInterval(61)
        )

        XCTAssertNil(summary.decisiveWindow)
        XCTAssertEqual(summary.remainingRank, 101)
        XCTAssertEqual(summary.displayStatusTitle, "Awaiting update")
    }

    func testUrgencyRankingAcrossProviderStates() {
        let evaluatedAt = Date(timeIntervalSince1970: 50_000)
        let scenarios: [(key: String, snapshot: ProviderSnapshot?)] = [
            scenario(
                "auth",
                status: .authExpired,
                fetchedAt: evaluatedAt.addingTimeInterval(-60)
            ),
            scenario(
                "schema",
                status: .schemaChanged,
                fetchedAt: evaluatedAt.addingTimeInterval(-60)
            ),
            scenario(
                "fresh-five-left",
                fetchedAt: evaluatedAt.addingTimeInterval(-60),
                utilization: 95,
                resetsAt: evaluatedAt.addingTimeInterval(3_600)
            ),
            scenario(
                "fresh-twenty-left",
                fetchedAt: evaluatedAt.addingTimeInterval(-60),
                utilization: 80,
                resetsAt: evaluatedAt.addingTimeInterval(3_600)
            ),
            scenario(
                "reset-awaiting",
                fetchedAt: evaluatedAt.addingTimeInterval(-600),
                utilization: 60,
                resetsAt: evaluatedAt.addingTimeInterval(-1)
            ),
            scenario(
                "stale",
                fetchedAt: evaluatedAt.addingTimeInterval(-1_801),
                utilization: 10,
                resetsAt: evaluatedAt.addingTimeInterval(3_600)
            ),
            (key: "unknown", snapshot: nil),
            scenario(
                "healthy-balance",
                fetchedAt: evaluatedAt.addingTimeInterval(-60),
                metric: UsageMetric(
                    id: "balance",
                    label: "Balance",
                    kind: .balance,
                    value: 100,
                    unit: "USD",
                    secondary: false
                )
            ),
        ]
        let accounts = scenarios.map {
            AccountRef(key: "claude:\($0.key)", providerId: "claude", label: nil, plan: nil)
        }
        let snapshots = Dictionary(uniqueKeysWithValues: scenarios.compactMap { scenario in
            scenario.snapshot.map { ("claude:\(scenario.key)", $0) }
        })

        let ranked = AccountLimitSummary.ranked(
            accounts: Array(accounts.reversed()),
            snapshots: snapshots,
            nextAllowed: [:],
            evaluatedAt: evaluatedAt
        )

        XCTAssertEqual(
            ranked.map(\.account.key),
            scenarios.map { "claude:\($0.key)" },
            "blocking auth/schema must lead, fresh finite quotas follow by least remaining, degraded or unknown accounts come next, and a healthy balance-only account stays last"
        )
    }

    private func scenario(
        _ key: String,
        status: SnapshotStatus = .ok,
        fetchedAt: Date,
        utilization: Double? = nil,
        resetsAt: Date? = nil,
        metric: UsageMetric? = nil
    ) -> (key: String, snapshot: ProviderSnapshot?) {
        let accountKey = "claude:\(key)"
        let windows = utilization.map {
            [UsageWindow(
                id: "session",
                utilization: $0,
                resetsAt: resetsAt,
                windowSeconds: 18_000,
                secondary: false
            )]
        } ?? []
        return (
            key,
            ProviderSnapshot(
                providerId: "claude",
                accountKey: accountKey,
                accountLabel: nil,
                planLabel: nil,
                fetchedAt: fetchedAt,
                status: status,
                windows: windows,
                metrics: metric.map { [$0] } ?? []
            )
        )
    }
}

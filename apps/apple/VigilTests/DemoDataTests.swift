import Foundation
import XCTest
import VigilKit
@testable import Vigil

/// The demo seed exists only to render honest, representative screenshots for
/// the README/App Store from a fresh simulator with no real credentials. These
/// tests lock the gate (demo data must never appear in a real launch) and the
/// shape (the seed has to populate the same surfaces a real account would,
/// including current limits, explicit model caps, and a metric-only provider).
final class DemoDataTests: XCTestCase {
    // MARK: - Gate: opt-in only, never on by accident

    func testRequestedOnlyWhenEnvFlagIsExactlyOne() {
        XCTAssertTrue(DemoData.requested(in: ["VIGIL_DEMO": "1"]))
        XCTAssertFalse(DemoData.requested(in: [:]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": "0"]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": "true"]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": ""]))
        #if !DEBUG
        XCTAssertFalse(
            DemoData.requested(in: ["VIGIL_DEMO": "1"]),
            "Release builds must ignore screenshot and UI-test launch hooks"
        )
        #endif
    }

    func testExpiredClaudeStateIsSeparatelyOptIn() throws {
        XCTAssertTrue(DemoData.claudeAuthExpiredRequested(in: [
            "VIGIL_DEMO_CLAUDE_AUTH_EXPIRED": "1",
        ]))
        XCTAssertFalse(DemoData.claudeAuthExpiredRequested(in: [:]))
        XCTAssertFalse(DemoData.claudeAuthExpiredRequested(in: [
            "VIGIL_DEMO_CLAUDE_AUTH_EXPIRED": "true",
        ]))

        let seed = DemoData.seed(
            now: Date(timeIntervalSince1970: 1_784_500_000),
            claudeStatus: .authExpired
        )
        let claude = try XCTUnwrap(seed.accounts.first { $0.providerId == "claude" })
        XCTAssertEqual(seed.snapshots[claude.key]?.status, .authExpired)
        XCTAssertTrue(seed.snapshots.values.allSatisfy {
            $0.accountKey == claude.key || $0.status == .ok
        })
    }

    // MARK: - Shape: every surface a real account would fill

    func testSeedKeysEverySnapshotToAnAccountAndStaysOk() {
        let seed = DemoData.seed(now: Date(timeIntervalSince1970: 1_784_500_000))
        XCTAssertFalse(seed.accounts.isEmpty, "an empty seed would screenshot as the empty state")
        for account in seed.accounts {
            let snapshot = seed.snapshots[account.key]
            XCTAssertNotNil(snapshot, "\(account.key) has no snapshot — its card would render as never-fetched")
            XCTAssertEqual(snapshot?.providerId, account.providerId)
            XCTAssertEqual(snapshot?.status, .ok, "a degraded status would show an error chip in the shot")
        }
        XCTAssertEqual(
            Set(seed.snapshots.keys),
            Set(seed.accounts.map(\.key)),
            "orphan snapshots key to no account and would be dropped from every surface"
        )
    }

    func testSeedUsesOnlyProviderGroundedPlanAndModelLabels() throws {
        let seed = DemoData.seed(now: Date(timeIntervalSince1970: 1_784_500_000))
        let claude = try XCTUnwrap(seed.accounts.first { $0.providerId == "claude" })
        XCTAssertNil(claude.plan)
        XCTAssertNil(seed.snapshots[claude.key]?.planLabel)
        let codex = try XCTUnwrap(seed.accounts.first { $0.providerId == "codex" })
        XCTAssertEqual(codex.plan, "pro")
        XCTAssertEqual(seed.snapshots[codex.key]?.planLabel, "pro")
        XCTAssertTrue(seed.snapshots[codex.key]?.windows.contains {
            $0.label == "GPT-5.3-Codex-Spark · Weekly"
        } == true)
        XCTAssertFalse(seed.snapshots.values.flatMap(\.windows).contains {
            $0.label == "Fable" || $0.label == "GPT-5.6 Sol"
        })
    }

    func testSeedIncludesAMetricOnlyProviderSoTheMetricsSectionShows() {
        let seed = DemoData.seed(now: Date(timeIntervalSince1970: 1_784_500_000))
        let metricOnly = seed.snapshots.values.first {
            $0.windows.isEmpty && !$0.metrics.isEmpty
        }
        XCTAssertNotNil(
            metricOnly,
            "a spend/balance provider proves the account-metrics row renders in the shot"
        )
    }

    func testSeedIncludesAProviderWithWindowsAndMetrics() {
        let seed = DemoData.seed(now: Date(timeIntervalSince1970: 1_784_500_000))
        let mixed = seed.snapshots.values.first {
            !$0.windows.isEmpty && !$0.metrics.isEmpty
        }
        XCTAssertNotNil(
            mixed,
            "a mixed Claude-style snapshot proves Home must render metrics below quota bars"
        )
    }
}

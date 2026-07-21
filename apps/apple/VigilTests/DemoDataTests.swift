import Foundation
import XCTest
import VigilKit
@testable import Vigil

/// The demo seed exists only to render honest, representative screenshots for
/// the README/App Store from a fresh simulator with no real credentials. These
/// tests lock the gate (demo data must never appear in a real launch) and the
/// shape (the seed has to populate the same surfaces a real account would — a
/// tightest-window Watchline, per-model caps for the Models view, and a
/// metric-only provider — or the screenshots would misrepresent the app).
final class DemoDataTests: XCTestCase {
    // MARK: - Gate: opt-in only, never on by accident

    func testRequestedOnlyWhenEnvFlagIsExactlyOne() {
        XCTAssertTrue(DemoData.requested(in: ["VIGIL_DEMO": "1"]))
        XCTAssertFalse(DemoData.requested(in: [:]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": "0"]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": "true"]))
        XCTAssertFalse(DemoData.requested(in: ["VIGIL_DEMO": ""]))
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

    func testSeedPopulatesTheModelsViewWithLabeledPerModelCaps() {
        let seed = DemoData.seed(now: Date(timeIntervalSince1970: 1_784_500_000))
        let candidates = UsagePresentation.modelLimits(
            accounts: seed.accounts,
            snapshots: seed.snapshots
        )
        XCTAssertGreaterThanOrEqual(
            candidates.count, 2,
            "the Models tab is the headline of this release — its screenshot must not be empty"
        )
        let labels = candidates.compactMap { $0.window.label }
        XCTAssertTrue(
            labels.contains("Fable"),
            "the flagship model caps (e.g. Fable) are the reason the Models view exists"
        )
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
}

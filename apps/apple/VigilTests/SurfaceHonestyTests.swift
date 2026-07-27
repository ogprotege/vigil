import Foundation
import SwiftUI
import XCTest
import VigilKit
@testable import Vigil

/// Honest-freshness and degraded-surface rules shared by the lock-screen and
/// home-screen widgets, plus the SharedContainer fallback exposure. Style
/// follows AppModelReliabilityTests.
final class SurfaceHonestyTests: XCTestCase {
    // MARK: - SnapshotFreshness (widget degradation rule)

    func testFreshOkSnapshotIsNotDegraded() {
        let now = Date()
        XCTAssertFalse(SnapshotFreshness.isStale(fetchedAt: now, at: now))
        XCTAssertFalse(
            SnapshotFreshness.isDegraded(status: .ok, fetchedAt: now, at: now)
        )
    }

    func testSnapshotOlderThanSharedThresholdIsStale() {
        let now = Date()
        XCTAssertEqual(
            SnapshotFreshness.staleAfter, 1800,
            "The 30-minute threshold is shared across widget and app surfaces; do not fork it"
        )
        let atThreshold = now.addingTimeInterval(-SnapshotFreshness.staleAfter)
        let pastThreshold = now.addingTimeInterval(-SnapshotFreshness.staleAfter - 1)
        XCTAssertFalse(
            SnapshotFreshness.isStale(fetchedAt: atThreshold, at: now),
            "Staleness begins strictly after the threshold, matching the pre-existing > comparison"
        )
        XCTAssertTrue(SnapshotFreshness.isStale(fetchedAt: pastThreshold, at: now))
        XCTAssertTrue(
            SnapshotFreshness.isDegraded(status: .ok, fetchedAt: pastThreshold, at: now)
        )
    }

    func testFailedStatusIsDegradedEvenWhenFresh() {
        let now = Date()
        let failedStatuses: [SnapshotStatus] = [
            .authExpired, .rateLimited, .schemaChanged, .network,
        ]
        for status in failedStatuses {
            XCTAssertTrue(
                SnapshotFreshness.isDegraded(status: status, fetchedAt: now, at: now),
                "A preserved last-good snapshot with status \(status) must not render as fresh"
            )
        }
    }

    func testPassedProviderResetHidesOldWindowWithoutInventingZeroUsage() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let oldWindow = UsageWindow(
            id: "session",
            utilization: 87,
            resetsAt: fetchedAt.addingTimeInterval(300),
            windowSeconds: 18_000,
            secondary: false,
            used: 87,
            limit: 100
        )
        let currentWindow = UsageWindow(
            id: "weekly",
            utilization: 42,
            resetsAt: fetchedAt.addingTimeInterval(86_400),
            windowSeconds: 604_800,
            secondary: false
        )
        let snapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: fetchedAt,
            status: .ok,
            windows: [oldWindow, currentWindow]
        )
        let afterReset = fetchedAt.addingTimeInterval(301)

        XCTAssertTrue(SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: afterReset))
        XCTAssertEqual(
            SnapshotFreshness.confirmedWindows(in: snapshot, at: afterReset),
            [currentWindow]
        )
        XCTAssertEqual(
            snapshot.windows.first?.utilization,
            87,
            "The reset boundary must never rewrite an observed value to zero."
        )
        XCTAssertEqual(snapshot.windows.first?.used, 87)
        XCTAssertEqual(snapshot.windows.first?.limit, 100)
    }

    func testResetAtOrBeforeFetchDoesNotInvalidateFreshProviderReading() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000)
        let window = UsageWindow(
            id: "session",
            utilization: 35,
            resetsAt: fetchedAt,
            windowSeconds: 18_000,
            secondary: false
        )
        let snapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:test",
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: fetchedAt,
            status: .ok,
            windows: [window]
        )

        XCTAssertFalse(
            SnapshotFreshness.hasUnconfirmedReset(
                in: snapshot,
                at: fetchedAt.addingTimeInterval(60)
            )
        )
        XCTAssertEqual(
            SnapshotFreshness.confirmedWindows(
                in: snapshot,
                at: fetchedAt.addingTimeInterval(60)
            ),
            [window]
        )
    }

    // MARK: - MetricFormat (all dashboard rows share one formatter)

    func testThreeLetterUnitFormatsAsCurrency() {
        let metric = UsageMetric(
            id: "balance",
            label: "Balance",
            kind: .balance,
            value: 12.34,
            unit: "USD",
            secondary: false
        )
        XCTAssertEqual(
            MetricFormat.value(metric, locale: Locale(identifier: "en_US")),
            "$12.34"
        )
    }

    func testCurrencyPrecisionCapsAtFourFractionDigits() {
        let metric = UsageMetric(
            id: "spend",
            label: "Spend",
            kind: .spend,
            value: 0.123456,
            unit: "USD",
            secondary: false
        )
        XCTAssertEqual(
            MetricFormat.value(metric, locale: Locale(identifier: "en_US")),
            "$0.1235"
        )
    }

    func testNonCurrencyUnitIsAppendedVerbatim() {
        let metric = UsageMetric(
            id: "remaining",
            label: "Remaining",
            kind: .remaining,
            value: 250,
            unit: "credits",
            secondary: false
        )
        XCTAssertEqual(
            MetricFormat.value(metric, locale: Locale(identifier: "en_US")),
            "250 credits"
        )
    }

    func testUnitlessMetricFormatsBareNumber() {
        let metric = UsageMetric(
            id: "limit",
            label: "Limit",
            kind: .limit,
            value: 100,
            unit: nil,
            secondary: false
        )
        XCTAssertEqual(
            MetricFormat.value(metric, locale: Locale(identifier: "en_US")),
            "100"
        )
    }

    func testSymbolsAndTintsMatchDashboardConventions() {
        XCTAssertEqual(MetricFormat.symbol(for: .balance), "wallet.pass")
        XCTAssertEqual(MetricFormat.symbol(for: .spend), "creditcard")
        XCTAssertEqual(MetricFormat.symbol(for: .limit), "gauge.with.needle")
        XCTAssertEqual(MetricFormat.symbol(for: .remaining), "banknote")
        XCTAssertEqual(MetricFormat.tint(for: .balance), .green)
        XCTAssertEqual(MetricFormat.tint(for: .remaining), .green)
        XCTAssertEqual(MetricFormat.tint(for: .spend), .orange)
        XCTAssertEqual(MetricFormat.tint(for: .limit), .secondary)
    }

    // MARK: - SharedContainer fallback exposure (no-double-poll degradation)

    func testResolveDirectoryPrefersGroupContainer() {
        let group = URL(fileURLWithPath: "/tmp/vigil-tests/group", isDirectory: true)
        let support = URL(fileURLWithPath: "/tmp/vigil-tests/support", isDirectory: true)

        let resolved = SharedContainer.resolveDirectory(
            groupContainer: group,
            applicationSupport: support
        )

        XCTAssertFalse(resolved.usedFallback)
        XCTAssertEqual(
            resolved.url,
            group.appendingPathComponent("VigilShared", isDirectory: true)
        )
    }

    func testResolveDirectoryReportsFallbackWhenGroupContainerMissing() {
        let support = URL(fileURLWithPath: "/tmp/vigil-tests/support", isDirectory: true)

        let resolved = SharedContainer.resolveDirectory(
            groupContainer: nil,
            applicationSupport: support
        )

        XCTAssertTrue(resolved.usedFallback, "A missing App Group container must be queryable, never silent")
        XCTAssertEqual(
            resolved.url,
            support.appendingPathComponent("VigilShared", isDirectory: true)
        )
    }

    func testDirectoryAccessRecordsWhetherFallbackIsActive() {
        _ = SharedContainer.directory
        let groupAvailable = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainer.appGroupID
        ) != nil

        XCTAssertEqual(SharedContainer.isUsingFallbackStorage, !groupAvailable)
    }
}

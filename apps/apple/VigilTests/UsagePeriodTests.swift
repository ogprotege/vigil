import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class UsagePeriodTests: XCTestCase {
    func testDayMatchesSessionWindows() {
        let session = window(id: "session", seconds: 18_000)
        let weekly = window(id: "weekly", seconds: 604_800)
        XCTAssertTrue(UsagePeriod.day.matches(session))
        XCTAssertFalse(UsagePeriod.day.matches(weekly))
        XCTAssertEqual(UsagePeriod.day.filteredWindows([weekly, session]).map(\.id), ["session"])
    }

    func testWeekMatchesWeeklyAndScoped() {
        let weekly = window(id: "weekly", seconds: 604_800)
        let opus = window(id: "weekly_opus", seconds: 604_800, secondary: true)
        XCTAssertTrue(UsagePeriod.week.matches(weekly))
        XCTAssertTrue(UsagePeriod.week.matches(opus))
    }

    func testLifetimeKeepsEverything() {
        let windows = [
            window(id: "session", seconds: 18_000),
            window(id: "weekly", seconds: 604_800),
            window(id: "weekly_opus", seconds: 604_800, secondary: true),
        ]
        XCTAssertEqual(
            UsagePeriod.lifetime.filteredWindows(windows).map(\.id),
            ["session", "weekly", "weekly_opus"]
        )
    }

    func testPeriodFallsBackToPrimaryWhenNoExactMatch() {
        let weeklyOnly = [window(id: "weekly", seconds: 604_800)]
        // Day filter with only weekly data still surfaces the weekly bar.
        XCTAssertEqual(UsagePeriod.day.filteredWindows(weeklyOnly).map(\.id), ["weekly"])
    }

    func testHeroUsesTightestRemainingForPeriod() {
        let claude = AccountRef(key: "claude:1", providerId: "claude", label: nil, plan: "max")
        let snapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: claude.key,
            accountLabel: nil,
            planLabel: "max",
            fetchedAt: Date(),
            status: .ok,
            windows: [
                window(id: "session", used: 10, seconds: 18_000),
                window(id: "weekly", used: 90, seconds: 604_800),
            ]
        )
        let day = PeriodHero.summary(
            period: .day,
            accounts: [claude],
            snapshots: [claude.key: snapshot]
        )
        // Day filter prefers session (10% used → 90% left).
        XCTAssertEqual(day.primaryValue, "90%")

        let week = PeriodHero.summary(
            period: .week,
            accounts: [claude],
            snapshots: [claude.key: snapshot]
        )
        XCTAssertEqual(week.primaryValue, "10%")
    }

    func testSpendDeltaAcrossDay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilObs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageObservationStore(directory: directory)
        let now = Date()
        try store.append(UsageObservation(
            recordedAt: now.addingTimeInterval(-3_600),
            accountKey: "openrouter:1",
            providerId: "openrouter",
            spendUSD: 10
        ), now: now)
        try store.append(UsageObservation(
            recordedAt: now,
            accountKey: "openrouter:1",
            providerId: "openrouter",
            spendUSD: 12.5
        ), now: now)

        let loaded = try store.load()
        let delta = try XCTUnwrap(
            UsageObservationStore.spendDelta(observations: loaded, period: .day, now: now)
        )
        XCTAssertTrue(delta.hasValue)
        XCTAssertEqual(delta.amount, 2.5, accuracy: 0.001)
    }

    private func window(
        id: String,
        used: Double = 0,
        seconds: Int?,
        secondary: Bool = false
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            utilization: used,
            resetsAt: Date().addingTimeInterval(3_600),
            windowSeconds: seconds,
            secondary: secondary,
            label: nil
        )
    }
}

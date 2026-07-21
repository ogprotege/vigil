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
        // Pinned to local noon. `periodStart(.day)` is startOfDay, so a wall
        // clock `Date()` put the -3600s sample before the period start whenever
        // the suite ran in the first hour after midnight — the delta collapsed
        // to 0 and this test failed on an unchanged tree (~4% of CI runs).
        let now = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())
        )
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

    /// SnapshotStore and PendingEventStore both fail closed on corrupt data
    /// and both have tests pinning that the bytes survive. This store used to
    /// swallow the read error and overwrite the file with a single row,
    /// destroying up to 400 days of history on the first poll after corruption.
    func testCorruptHistoryFailsClosedAndIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilObs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let corrupt = Data("{not-json".utf8)
        let fileURL = directory.appendingPathComponent("usage-observations.json")
        try corrupt.write(to: fileURL)

        let store = UsageObservationStore(directory: directory)
        XCTAssertThrowsError(
            try store.append(UsageObservation(
                accountKey: "openrouter:1",
                providerId: "openrouter",
                spendUSD: 5
            )),
            "append must fail closed on unreadable history"
        )
        XCTAssertThrowsError(
            try store.removeAll(accountKey: "openrouter:1"),
            "removeAll must fail closed rather than report a deletion it did not do"
        )
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            corrupt,
            "the corrupt bytes must be preserved, not overwritten"
        )
    }

    /// Removing an account must take its money history with it — otherwise the
    /// deleted account keeps driving the Home hero and its dollar amounts sit
    /// in the App Group container for up to 400 days.
    func testRemoveAllDropsOnlyThatAccountsHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilObs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageObservationStore(directory: directory)
        let now = Date()
        try store.append(UsageObservation(
            recordedAt: now,
            accountKey: "openrouter:1",
            providerId: "openrouter",
            spendUSD: 10
        ), now: now)
        try store.append(UsageObservation(
            recordedAt: now,
            accountKey: "deepseek:1",
            providerId: "deepseek",
            spendUSD: 4
        ), now: now)

        let remaining = try store.removeAll(accountKey: "openrouter:1")
        XCTAssertEqual(remaining.map(\.accountKey), ["deepseek:1"])
        XCTAssertEqual(try store.load().map(\.accountKey), ["deepseek:1"])
    }

    /// Polling is on a timer, so an idle account would append an identical row
    /// every interval and eventually evict its own baseline.
    func testAppendSkipsRowsThatRepeatTheSameValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilObs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageObservationStore(directory: directory)
        let now = Date()
        for offset in 0..<5 {
            try store.append(UsageObservation(
                recordedAt: now.addingTimeInterval(Double(offset) * 300),
                accountKey: "openrouter:1",
                providerId: "openrouter",
                spendUSD: 10
            ), now: now)
        }
        XCTAssertEqual(try store.load().count, 1, "Unchanged values must not accumulate rows")

        try store.append(UsageObservation(
            recordedAt: now.addingTimeInterval(1_800),
            accountKey: "openrouter:1",
            providerId: "openrouter",
            spendUSD: 11
        ), now: now)
        XCTAssertEqual(try store.load().count, 2, "A changed value must still be recorded")
    }

    /// The oldest sample is the baseline every delta measures from; capping the
    /// log must not silently shorten Lifetime by evicting it.
    func testPruneKeepsEachAccountsOldestSample() {
        let now = Date()
        let oldest = UsageObservation(
            recordedAt: now.addingTimeInterval(-86_400 * 30),
            accountKey: "openrouter:1",
            providerId: "openrouter",
            spendUSD: 1
        )
        var all = [oldest]
        for index in 0..<6_000 {
            all.append(UsageObservation(
                recordedAt: now.addingTimeInterval(-Double(6_000 - index)),
                accountKey: "openrouter:1",
                providerId: "openrouter",
                spendUSD: Double(index) + 2
            ))
        }
        let pruned = UsageObservationStore.pruned(all, now: now)
        XCTAssertTrue(
            pruned.contains(where: { $0.id == oldest.id }),
            "The baseline sample must survive the entry cap"
        )
    }

    /// openai/spend_month, github/spend_month and claude/extra_used all reset
    /// monthly, and .week/.month/.year are rolling ranges that always straddle
    /// a reset. `last - first` reported 0 (or a meaningless difference) there.
    func testSpendDeltaSurvivesAMonthlyCounterReset() {
        let now = Date()
        let observations = [
            observation(at: now.addingTimeInterval(-86_400 * 3), spend: 40),
            observation(at: now.addingTimeInterval(-86_400 * 2), spend: 52),
            // Counter resets: the provider's month rolled over.
            observation(at: now.addingTimeInterval(-86_400), spend: 3),
            observation(at: now, spend: 15),
        ]
        let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: .week,
            now: now
        )
        let summary = delta!
        XCTAssertTrue(summary.hasValue)
        // 12 before the reset + 3 at the reset + 12 after it.
        XCTAssertEqual(summary.amount, 27, accuracy: 0.001)
    }

    /// A single reading is not a delta — `last - first` over one element is
    /// identically 0, which rendered a confident "$0.00" as the 42pt hero.
    func testSingleObservationReportsNoSpendValue() {
        let now = Date()
        let delta = UsageObservationStore.spendDelta(
            observations: [observation(at: now, spend: 47)],
            period: .day,
            now: now
        )
        XCTAssertFalse(delta!.hasValue, "One sample must not be reported as $0.00 spend")
    }

    /// A balance that rises was topped up; that tells us nothing about spend.
    func testBalanceTopUpDoesNotCountAsNegativeSpend() throws {
        // Pinned to noon for the same reason as testSpendDeltaAcrossDay: a
        // wall-clock `now` puts the -7200s sample before startOfDay when the
        // suite runs shortly after local midnight.
        let now = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())
        )
        let observations = [
            observation(at: now.addingTimeInterval(-7_200), remaining: 20),
            observation(at: now.addingTimeInterval(-3_600), remaining: 12),
            observation(at: now, remaining: 50),
        ]
        let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: .day,
            now: now
        )
        XCTAssertEqual(delta!.amount, 8, accuracy: 0.001)
    }

    /// A small drop is a refund or a restated usage item, not a counter reset.
    /// Booking the full new reading there would report ~$12.48 of spend for a
    /// two-cent refund, and re-add it on every downward tick.
    func testSmallDropIsTreatedAsACorrectionNotAReset() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())
        )
        let observations = [
            observation(at: now.addingTimeInterval(-7_200), spend: 12.50),
            observation(at: now.addingTimeInterval(-3_600), spend: 12.48),
            observation(at: now, spend: 12.60),
        ]
        let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: .day,
            now: now
        )
        // The refund contributes 0; only the 12.48 -> 12.60 rise counts.
        XCTAssertEqual(delta!.amount, 0.12, accuracy: 0.001)
    }

    /// Spend for a range is (value at the end) − (value at the start), so the
    /// last reading before the range opens is the baseline. Without it, a day
    /// whose first in-range reading is its only one reports nothing — which is
    /// most days, because an idle counter's repeat readings are deduplicated.
    func testDeltaSeedsFromTheLastReadingBeforeThePeriod() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())
        )
        let startOfDay = Calendar.current.startOfDay(for: now)
        let observations = [
            observation(at: startOfDay.addingTimeInterval(-3_600), spend: 20),
            observation(at: now, spend: 26),
        ]
        let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: .day,
            now: now
        )
        XCTAssertTrue(delta!.hasValue, "The pre-period reading is the baseline")
        XCTAssertEqual(delta!.amount, 6, accuracy: 0.001)
    }

    /// Home exists to surface the quota about to run out; a linked balance-only
    /// account must not displace it.
    func testTightestLimitOutranksABalanceHero() {
        let claude = AccountRef(key: "claude:1", providerId: "claude", label: nil, plan: nil)
        let openRouter = AccountRef(
            key: "openrouter:1",
            providerId: "openrouter",
            label: nil,
            plan: nil
        )
        let claudeSnapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: claude.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: Date(),
            status: .ok,
            windows: [window(id: "session", used: 96, seconds: 18_000)],
            metrics: []
        )
        let balanceSnapshot = ProviderSnapshot(
            providerId: "openrouter",
            accountKey: openRouter.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: Date(),
            status: .ok,
            windows: [],
            metrics: [
                UsageMetric(
                    id: "usage",
                    label: "Credits remaining",
                    kind: .remaining,
                    value: 18.42,
                    unit: "USD",
                    secondary: false
                )
            ]
        )
        let hero = PeriodHero.summary(
            period: .day,
            accounts: [claude, openRouter],
            snapshots: [claude.key: claudeSnapshot, openRouter.key: balanceSnapshot]
        )
        XCTAssertEqual(hero.primaryValue, "4%")
        XCTAssertTrue(hero.title.lowercased().contains("tightest"))
    }

    /// With no windows anywhere, the balance hero is still the right answer.
    func testBalanceHeroStillShowsWhenNoAccountReportsWindows() {
        let openRouter = AccountRef(
            key: "openrouter:1",
            providerId: "openrouter",
            label: nil,
            plan: nil
        )
        let snapshot = ProviderSnapshot(
            providerId: "openrouter",
            accountKey: openRouter.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: Date(),
            status: .ok,
            windows: [],
            metrics: [
                UsageMetric(
                    id: "usage",
                    label: "Credits remaining",
                    kind: .remaining,
                    value: 18.42,
                    unit: "USD",
                    secondary: false
                )
            ]
        )
        let hero = PeriodHero.summary(
            period: .day,
            accounts: [openRouter],
            snapshots: [openRouter.key: snapshot]
        )
        XCTAssertEqual(hero.title, "Credits remaining")
    }

    private func observation(
        at date: Date,
        spend: Double? = nil,
        remaining: Double? = nil
    ) -> UsageObservation {
        UsageObservation(
            recordedAt: date,
            accountKey: "acct:1",
            providerId: "openrouter",
            spendUSD: spend,
            remainingUSD: remaining
        )
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

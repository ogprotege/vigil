import Foundation
import VigilKit

/// Screenshot-only sample data, gated behind the `VIGIL_DEMO=1` launch
/// environment so a real launch never sees it. A fresh install has no
/// credentials in the Keychain, so it can only ever render the empty state —
/// which cannot show the Watchline, the stacked limit meters, or the Models
/// view. This seeds one representative account per surface so the README / App
/// Store screenshots reflect the shipping UI. The numbers are internally
/// consistent (percentages and resets a real account could report), never
/// inflated to look busier than the product is.
enum DemoData {
    /// True only for an exact `VIGIL_DEMO=1`. Anything else — absent, empty,
    /// "true", "0" — is off, so the flag can never be tripped by accident.
    static func requested(in environment: [String: String]) -> Bool {
        environment["VIGIL_DEMO"] == "1"
    }

    static func seed(
        now: Date = Date()
    ) -> (accounts: [AccountRef], snapshots: [String: ProviderSnapshot]) {
        var accounts: [AccountRef] = []
        var snapshots: [String: ProviderSnapshot] = [:]

        func add(_ account: AccountRef, _ snapshot: ProviderSnapshot) {
            accounts.append(account)
            snapshots[account.key] = snapshot
        }

        func window(
            _ id: String,
            _ utilization: Double,
            resetsIn seconds: TimeInterval,
            windowSeconds: Int,
            secondary: Bool = false,
            label: String? = nil
        ) -> UsageWindow {
            UsageWindow(
                id: id,
                utilization: utilization,
                resetsAt: now.addingTimeInterval(seconds),
                windowSeconds: windowSeconds,
                secondary: secondary,
                label: label
            )
        }

        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400
        let session = 18_000
        let weekly = 604_800

        // Claude, Max plan — session + weekly plus model-scoped weeklies and an
        // overage-credits metric. Drives the Watchline and the Models view.
        let claude = AccountRef(key: "claude:demo", providerId: "claude", label: nil, plan: "Max")
        add(claude, ProviderSnapshot(
            providerId: "claude",
            accountKey: claude.key,
            accountLabel: nil,
            planLabel: "Max",
            fetchedAt: now.addingTimeInterval(-90),
            status: .ok,
            windows: [
                window("session", 42, resetsIn: 2.3 * hour, windowSeconds: session),
                window("weekly", 68, resetsIn: 4.2 * day, windowSeconds: weekly),
                window("weekly_scoped_fable", 55, resetsIn: 5 * day, windowSeconds: weekly, secondary: true, label: "Fable"),
                window("weekly_scoped_opus", 33, resetsIn: 5 * day, windowSeconds: weekly, secondary: true, label: "Opus"),
            ],
            metrics: [
                UsageMetric(id: "extra_used", label: "Overage credits", kind: .spend, value: 4.20, unit: "USD", secondary: true),
            ]
        ))

        // ChatGPT / Codex, Plus plan — session + weekly plus a per-model lane.
        let codex = AccountRef(key: "codex:demo", providerId: "codex", label: nil, plan: "Plus")
        add(codex, ProviderSnapshot(
            providerId: "codex",
            accountKey: codex.key,
            accountLabel: nil,
            planLabel: "Plus",
            fetchedAt: now.addingTimeInterval(-120),
            status: .ok,
            windows: [
                window("session", 77, resetsIn: 3.1 * hour, windowSeconds: session),
                window("weekly", 44, resetsIn: 5 * day, windowSeconds: weekly),
                window("gpt-5-codex-spark", 21, resetsIn: 5 * day, windowSeconds: weekly, secondary: true, label: "GPT-5.6 Sol"),
            ]
        ))

        // MiniMax Coding Plan — general session/weekly plus the video lanes.
        let minimax = AccountRef(key: "minimax:demo", providerId: "minimax", label: nil, plan: "Coding Plan")
        add(minimax, ProviderSnapshot(
            providerId: "minimax",
            accountKey: minimax.key,
            accountLabel: nil,
            planLabel: "Coding Plan",
            fetchedAt: now.addingTimeInterval(-200),
            status: .ok,
            windows: [
                window("session", 18, resetsIn: 2 * hour, windowSeconds: session),
                window("weekly", 61, resetsIn: 6 * day, windowSeconds: weekly),
                window("session_video", 12, resetsIn: 2 * hour, windowSeconds: session, secondary: true),
                window("weekly_video", 39, resetsIn: 6 * day, windowSeconds: weekly, secondary: true),
            ]
        ))

        // Kimi K3 coding plan — the new session + weekly windows.
        let kimi = AccountRef(key: "kimi_code:demo", providerId: "kimi_code", label: nil, plan: nil)
        add(kimi, ProviderSnapshot(
            providerId: "kimi_code",
            accountKey: kimi.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now.addingTimeInterval(-60),
            status: .ok,
            windows: [
                window("session", 48, resetsIn: 3.5 * hour, windowSeconds: session),
                window("weekly", 29, resetsIn: 4 * day, windowSeconds: weekly),
            ]
        ))

        // OpenRouter — a metric-only gateway: proves the account-metrics row.
        let openrouter = AccountRef(key: "openrouter:demo", providerId: "openrouter", label: nil, plan: nil)
        add(openrouter, ProviderSnapshot(
            providerId: "openrouter",
            accountKey: openrouter.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now.addingTimeInterval(-140),
            status: .ok,
            windows: [],
            metrics: [
                UsageMetric(id: "spend", label: "Spent", kind: .spend, value: 12.47, unit: "USD", secondary: false),
                UsageMetric(id: "limit", label: "Credit limit", kind: .limit, value: 50, unit: "USD", secondary: true),
                UsageMetric(id: "remaining", label: "Remaining", kind: .remaining, value: 37.53, unit: "USD", secondary: false),
            ]
        ))

        return (accounts, snapshots)
    }
}

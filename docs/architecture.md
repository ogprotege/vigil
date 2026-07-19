# Vigil architecture

## System overview

```
┌─────────────── computer ───────────────┐        ┌──────────── iPhone / Mac ────────────┐
│  ~/.claude/.credentials.json           │        │  Vigil app (SwiftUI)                 │
│  ~/.codex/auth.json                    │        │   ├─ VigilKit                        │
│  macOS Keychain                        │  QR /  │   │   ├─ ProviderRegistry ──────────┼──▶ provider usage endpoints
│        │                               │ paste  │   │   ├─ FetchScheduler (ledger)    │
│        ▼                               │ ─────▶ │   │   ├─ Vault (Keychain)           │
│  npx vigil-link                        │        │   │   ├─ SnapshotStore (App Group)  │
│   ├─ discover / mint credentials       │        │   │   └─ ThresholdEngine → notifs   │
│   ├─ live-verify against provider      │        │   └─ Widgets (read snapshots,       │
│   └─ render vigil1 QR chunks           │        │       tick countdowns client-side)  │
└────────────────────────────────────────┘        └──────────────────────────────────────┘
```

There is no Vigil server. The phone talks directly to provider endpoints with credentials handed off from the computer or entered manually.

## The three reliability mechanisms

1. **Locked polling leases.** Every Apple fetch first reserves an account-specific lease in the App Group ledger. `FileLedgerStore` wraps the read, decision, and lease write in an OS `flock`, so app and widget processes cannot both pass the gate from the same ledger state. The lease expires after five minutes if a process crashes. `recordResult` clears only the caller's lease and records the next allowed time plus any 429 backoff. A ledger read or write failure fails closed and is surfaced to the app.

2. **Client-computed countdowns.** `resets_at` timestamps let every window surface render a live countdown with zero network. Timelines schedule entries at reset boundaries so a window can display 0% after its known reset even before the next provider fetch confirms it.

3. **Honest failure and persistence states.** Every provider snapshot carries `ok`, `rateLimited`, `authExpired`, `schemaChanged`, or `network`. Staleness stays visible. Malformed provider data degrades to `schemaChanged`. Credential-rotation, snapshot, account-index, Keychain-deletion, and ledger failures follow a separate visible storage-error path.

The CLI does not share the Apple App Group. It uses its own provider-level, cross-process poll gate. The gate stores only `lastAttemptAt`, `nextAllowedAt`, and a consecutive-429 counter under the user cache directory. Reservation happens before network I/O under a directory lock. If the safety state is unavailable, the CLI defers the request. Apple and CLI network attempts have a 15-second timeout by default. One provider's CLI failure does not abort the remaining report.

## Cross-language lockstep

`protocol/providers.json` is the machine-readable source of truth for endpoints, headers, poll policy, discovery metadata, window mappings, and scalar metric mappings. TypeScript loads it at runtime. Swift hand-mirrors the runtime constants. Tests assert:

- `mapper(fixture) == expected` for every fixture pair in `protocol/fixtures/`
- Swift's compiled-in registry constants match `providers.json` (Swift hand-mirrors values for runtime independence; the test keeps them honest)
- QR vectors in `protocol/qr-vectors/` reassemble/decode identically (both sides assert byte-exact decode of the committed chunks; the CLI also asserts a fresh encode round-trips — encode bytes themselves are zlib-version-dependent and deliberately unpinned)

Adding a provider is not a data-only change. Credential discovery, OAuth, response shapes, UI behavior, fixtures, Swift parity constants, and user documentation may all require code. See [provider-contribution.md](provider-contribution.md).

## Normalized model (all languages)

```
UsageWindow      { id, utilization: 0–100, resetsAt?: Date, windowSeconds?: Int, secondary: Bool }
UsageMetric      { id, label, kind: balance | spend | limit | remaining,
                   value: Double, unit?: String, secondary: Bool }
ProviderSnapshot { providerId, accountKey, accountLabel?, planLabel?, fetchedAt,
                   status: ok | authExpired | rateLimited | schemaChanged | network,
                   windows: [UsageWindow], metrics: [UsageMetric] }
```

Windows represent reset-based percentage quotas. Metrics represent values for which the provider supplies no honest percentage, such as dollars spent or a currency balance. The model never invents a denominator.

Error taxonomy: HTTP 401 or 403 becomes `authExpired`; Vigil-owned Claude credentials may refresh once and retry. HTTP 429 becomes `rateLimited` plus ledger backoff. A successful response with no valid window or metric becomes `schemaChanged`. Other HTTP and transport failures become `network`.

## Fetch triggers (Apple platforms)

- App foreground: immediate (ledger-gated) + timer while frontmost.
- Pull-to-refresh: ledger-gated (a refresh that would burn the budget shows "checked Xs ago" instead).
- iOS background: `BGAppRefreshTask` (opportunistic — iOS decides; we are honest about this in-product).
- Widget timeline provider: fetches only if snapshot age exceeds 30 minutes and the ledger allows it. Each widget can select a linked account with an App Intent. An unconfigured widget uses the first account. A widget configured for a removed account stays empty rather than switching accounts.
- macOS menu bar app: timer-driven while running.

## Security posture

- Keychain: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, shared access group with the widget extension. `ThisDeviceOnly` prevents iCloud Keychain sync, so each device needs its own link.
- Face ID/Touch ID app lock; credential reveal/management gated on user presence.
- QR handoff: see `docs/qr-protocol.md` for the payload format and the plaintext-with-guardrails decision (ADR-0003).
- The CLI never writes credentials or usage values to disk. Its non-secret poll safety state is documented in ADR-0004.
- The full security boundary and accepted limitations are in [threat-model.md](threat-model.md).

## Known architectural limits

- Claude and Codex consumer usage endpoints are undocumented. Fixture parity catches code regressions but cannot detect vendor drift before a release.
- iOS background refresh and WidgetKit timelines are scheduled by the operating system. Vigil cannot promise a fetch at an exact time.
- Unsigned local builds may fall back from the App Group container to Application Support. App and widget processes then do not share one ledger.
- Scalar metrics and percentage windows are different concepts. A gateway balance does not imply a reset time or utilization percentage.
- CI compiles the iOS Simulator app and runs app reliability tests on macOS. Device-only Keychain, background-task, camera, notification, and WidgetKit scheduling behavior still requires the on-device release walk.

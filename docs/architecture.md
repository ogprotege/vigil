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

There is no Vigil server. The phone talks directly to provider endpoints with credentials handed off from the computer (or entered manually).

## The three reliability mechanisms

1. **Shared polling ledger.** Claude's usage endpoint 429-jails aggressive pollers (no `Retry-After`). Every fetch in the app and the widget process goes through one `FetchScheduler` whose ledger (next-allowed-fetch time, consecutive 429 count, per account) is persisted in the App Group container. App + widget can never double-spend the polling budget. Minimum intervals, jitter, and backoff come from `protocol/providers.json` — policy is data, not code.

2. **Client-computed countdowns.** `resets_at` timestamps let every surface render a live countdown (`Text(timerInterval:)` in SwiftUI ticks natively) with zero network. A widget refreshed 30 minutes ago still shows a to-the-second reset timer. Timelines schedule entries at reset boundaries so a window visually resets to ~0% on time even before the next real fetch confirms it.

3. **Honest failure states.** Every snapshot carries a status: `ok`, `rateLimited` (shows "next check at HH:MM"), `authExpired` (re-link CTA), `schemaChanged` (provider changed their response — "check for updates"), `network`. Staleness is tinted, never hidden. An unparseable response can never crash a mapper — it degrades to `schemaChanged`.

## Cross-language lockstep

`protocol/providers.json` is the single source of truth for endpoints, headers, poll policy, and window mappings. The TypeScript CLI and Swift VigilKit each implement a thin mapper; CI on both sides asserts:

- `mapper(fixture) == expected` for every fixture pair in `protocol/fixtures/`
- Swift's compiled-in registry constants match `providers.json` (Swift hand-mirrors values for runtime independence; the test keeps them honest)
- QR vectors in `protocol/qr-vectors/` reassemble/decode identically (CLI asserts the encode side, VigilKit the decode side)

Adding a provider = one registry entry + fixtures + a thin mapper on each side (plus the Swift spec-parity constants). See `docs/provider-spec.md`.

## Normalized model (all languages)

```
UsageWindow      { id, utilization: 0–100, resetsAt?: Date, windowSeconds?: Int, secondary: Bool }
ProviderSnapshot { providerId, accountId, planLabel?, fetchedAt,
                   status: ok | authExpired | rateLimited | schemaChanged | network,
                   windows: [UsageWindow] }
```

Error taxonomy: HTTP 401 → refresh once → retry → else `authExpired`. HTTP 429 → `rateLimited` + ledger backoff. 2xx but unparseable → `schemaChanged`. Anything else → `network`.

## Fetch triggers (Apple platforms)

- App foreground: immediate (ledger-gated) + timer while frontmost.
- Pull-to-refresh: ledger-gated (a refresh that would burn the budget shows "checked Xs ago" instead).
- iOS background: `BGAppRefreshTask` (opportunistic — iOS decides; we are honest about this in-product).
- Widget timeline provider: fetches only if snapshot age > 30 min AND the ledger allows.
- macOS menu bar app (M7): effectively always-running → timer-driven, the most reliable surface.

## Security posture

- Keychain: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, shared access group with the widget extension. ThisDeviceOnly ⇒ no iCloud Keychain sync ⇒ each device links via its own scan.
- Face ID/Touch ID app lock; credential reveal/management gated on user presence.
- QR handoff: see `docs/qr-protocol.md` for the payload format and the plaintext-with-guardrails decision (ADR-0003).
- The CLI is stateless: it never writes credentials to disk (ADR-0004).

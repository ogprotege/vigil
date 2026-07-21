# Vigil architecture

## System overview

```
┌───────────────────────── iPhone / Mac (primary) ─────────────────────────┐
│  Vigil app (SwiftUI)                                                      │
│   ├─ Onboarding / "Add account"                                           │
│   │   ├─ Sign in with Claude (ClaudeAuth, on-device OAuth)                ┼─▶ provider OAuth /
│   │   ├─ Sign in with Codex  (CodexAuth, device-code sign-in)             ┼─▶ token endpoints
│   │   └─ Paste a provider key → <provider>                               │
│   ├─ VigilKit                                                             │
│   │   ├─ ProviderRegistry                                                 ┼─▶ provider usage endpoints
│   │   ├─ FetchScheduler (ledger)                                          │
│   │   ├─ Vault (Keychain)                                                 │
│   │   ├─ SnapshotStore (App Group)                                        │
│   │   └─ ThresholdEngine → notifs                                         │
│   └─ Widgets (read snapshots, tick countdowns client-side)                │
└───────────────────────────────────────────────────────────────────────────┘
                            ▲
                            │  optional: reuse an existing Claude Code /
                            │  Codex sign-in  ·  vigil1 QR / paste
┌───────────────────── computer (optional) ──────────────────────┐
│  npx vigil-link  —  optional reuse lane                         │
│   ├─ reads ~/.claude/.credentials.json, ~/.codex/auth.json,     │
│   │   or the macOS Keychain  →  discover / mint credentials     │
│   ├─ live-verify against the provider                           │
│   └─ render vigil1 QR chunks (or paste output)                  │
└─────────────────────────────────────────────────────────────────┘
```

There is no Vigil server. The phone talks directly to provider endpoints, and credentials are provisioned on the phone itself: Claude through on-device "Sign in with Claude" OAuth (VigilKit `ClaudeAuth`), Codex through OpenAI's device-code sign-in (VigilKit `CodexAuth`), and each API-key provider by pasting a key. Reusing a Claude Code / Codex sign-in that already exists on a computer — via the `npx vigil-link` `vigil1` QR / paste handoff — is an optional convenience lane, not the primary path.

## The three reliability mechanisms

1. **Locked polling leases.** Every Apple fetch first reserves an account-specific lease in the App Group ledger. `FileLedgerStore` wraps the read, decision, and lease write in an OS `flock`, so app and widget processes cannot both pass the gate from the same ledger state. The lease expires if a process crashes, and `acquire` clamps the lease duration to at least the provider's poll floor (five minutes for every current provider), so even a crash-looping process cannot poll faster than `minSeconds`. `recordResult` clears only the caller's lease and records the next allowed time plus any 429 backoff. A ledger read or write failure fails closed and is surfaced to the app.

2. **Client-computed countdowns.** `resets_at` timestamps let every window surface render a live countdown with zero network. Timelines schedule entries at reset boundaries so a window can display 0% after its known reset even before the next provider fetch confirms it.

3. **Honest failure and persistence states.** Every provider snapshot carries `ok`, `rateLimited`, `authExpired`, `schemaChanged`, or `network`. Staleness stays visible. Malformed provider data degrades to `schemaChanged`. Credential-rotation, snapshot, account-index, Keychain-deletion, and ledger failures follow a separate visible storage-error path.

The CLI does not share the Apple App Group. It uses its own provider-level, cross-process poll gate. The gate stores only `lastAttemptAt`, `nextAllowedAt`, and a consecutive-429 counter under the user cache directory. Reservation happens before network I/O under a directory lock. If the safety state is unavailable, the CLI defers the request. CLI attempts abort at a hard 15-second per-attempt deadline; Apple requests set a 15-second `URLRequest` timeout, which bounds idle time between bytes rather than total request duration. One provider's CLI failure does not abort the remaining report.

The poll floor is enforced per gate, not as one global per-provider budget. The Apple ledger is keyed by account, so each linked account has its own five-minute clock — N linked accounts of one provider on Apple surfaces can produce N requests against that provider inside one five-minute window. The CLI gate is keyed by provider, and the CLI and the app on the same Mac keep separate state. Each gate honestly enforces its own floor; none of them can see the others' traffic.

## Cross-language lockstep

`protocol/providers.json` is the machine-readable source of truth for endpoints, headers, poll policy, discovery metadata, window mappings, and scalar metric mappings. TypeScript loads it at runtime. Swift hand-mirrors the runtime constants. Tests assert:

- `mapper(fixture) == expected` for every fixture pair in `protocol/fixtures/`
- Swift's compiled-in registry constants match `providers.json` (Swift hand-mirrors values for runtime independence; the test keeps them honest)
- QR vectors in `protocol/qr-vectors/` reassemble/decode identically (both sides assert byte-exact decode of the committed chunks; the CLI also asserts a fresh encode round-trips — encode bytes themselves are zlib-version-dependent and deliberately unpinned)

Adding a provider is not a data-only change. Credential discovery, OAuth, response shapes, UI behavior, fixtures, Swift parity constants, and user documentation may all require code. See [provider-contribution.md](provider-contribution.md).

## Normalized model (all languages)

```
UsageWindow      { id, label?: String, utilization: 0–100, resetsAt?: Date, windowSeconds?: Int, secondary: Bool }
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

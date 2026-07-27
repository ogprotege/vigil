# Vigil architecture

## System overview

```text
┌──────────────────────────────── iPhone ────────────────────────────────┐
│ Vigil app (SwiftUI, iOS 17+)                                           │
│  ├─ Add account                                                        │
│  │   ├─ Sign in with Claude                                            ┼─▶ Anthropic authorization and token endpoints
│  │   ├─ Sign in with Codex                                             ┼─▶ OpenAI device authorization and token endpoints
│  │   └─ Paste provider credential                                      │
│  ├─ VigilKit                                                           │
│  │   ├─ ProviderRegistry                                               ┼─▶ activated provider usage endpoints
│  │   ├─ UsageClient and UsageMapper                                    │
│  │   ├─ FetchScheduler and FileLedgerStore                             │
│  │   ├─ KeychainCredentialsStore                                       │
│  │   ├─ SnapshotStore and SQLite UsageHistoryStore                     │
│  │   └─ ThresholdEngine                                                │
│  └─ VigilWidgets                                                       │
│      └─ reads shared snapshots and obeys the shared poll ledger        │
└────────────────────────────────────────────────────────────────────────┘
```

There is no Vigil server. Every credential is minted or entered on the phone. The device sends usage requests directly to activated providers.

The product ships only on iOS. `VigilKit` retains a macOS package platform so its unit tests can run on macOS build hosts. That host declaration is not a macOS app surface.

## Repository boundaries

- `protocol/providers.json`: reviewable provider contract.
- `protocol/fixtures/`: sanitized or modeled response cases and hand-authored normalized expectations.
- `protocol/fixture-provenance.json`: evidence class and source for every fixture.
- `packages/VigilKit/`: UI-free Swift core.
- `apps/apple/Vigil/`: iOS views, lifecycle, browser presentation, account forms, notification coordination, and shared support code.
- `apps/apple/VigilWidgets/`: iOS widget extension.
- `apps/apple/VigilTests/`: app behavior and presentation tests.

## Provider contract and Swift mirror

`protocol/providers.json` is canonical in intent. It defines request templates, poll policy, response mappings, required-output contracts, capabilities, experimental state, and manual-entry guidance.

The iOS app cannot load a repository file at runtime, so Swift's `ProviderRegistry` compiles a mirror of the runtime values. `SpecParityTests` compare that mirror with the JSON contract. `FixtureParityTests` feed committed provider bodies into the sole shipped mapper and compare the result with hand-authored expected output.

This arrangement prevents contract drift inside the repository. It does not prove an upstream API remains unchanged. Fixture provenance and explicit live validation carry that separate claim.

Adding a provider can require authentication, request construction, mapping, fixtures, UI work, privacy review, and documentation. See [Provider contribution guide](provider-contribution.md).

## Normalized model

```text
UsageWindow {
  id, label?, utilization: 0...100, used?, limit?,
  resetsAt?, windowSeconds?, secondary
}

UsageMetric {
  id, label, kind: balance | spend | limit | remaining,
  value, unit?, secondary
}

ProviderSnapshot {
  providerId, accountKey, accountLabel?, planLabel?, fetchedAt,
  status: ok | authExpired | rateLimited | schemaChanged | network,
  windows, metrics
}

UsageHistorySample {
  source: observed | providerBackfill,
  accountKey, providerId, recordedAt, retrievedAt,
  status, normalized windows, normalized metrics
}
```

Windows represent reset-based percentage quotas. Metrics represent values without an honest denominator, such as spend or balance. Vigil does not invent percentages.

HTTP 401 and 403 become `authExpired`. HTTP 429 becomes `rateLimited` and advances the ledger backoff. Structural or semantic contract failure becomes `schemaChanged`. Other HTTP and transport failures become `network`.

## Reliability mechanisms

### Locked polling leases

Every app or widget fetch first acquires an account-level lease in the App Group ledger. `FileLedgerStore` wraps the read, decision, and write in an OS file lock.

The lease is durable and expires after a bounded interval. The scheduler clamps lease duration to at least the provider's poll floor. A crash loop therefore cannot poll faster than `minSeconds`.

`recordResult` clears only the caller's lease and records the next allowed time plus rate-limit backoff. A ledger read or write failure fails closed and becomes a visible storage error.

### Client-computed countdowns

Provider reset timestamps let every surface render a moving countdown without another request. Widget timelines can schedule reset-boundary entries. The UI still shows snapshot age because a live countdown does not imply fresh utilization.

Provider requests and Claude/Codex token exchanges use an ephemeral URL session
with no response cache or cookie store. Startup clears app-scoped default-session
cache and cookie residue left by pre-0.15 builds. Browser approval remains owned
by the system browser and is outside Vigil's storage boundary.

### Required-output contracts

Successful HTTP status is not enough. A provider response must parse and satisfy its declared minimum windows, metrics, IDs, exhaustive collections, and correlated-field rules.

This prevents a partial response from being labeled Live merely because one unrelated metric survived. Diagnostic partial output can remain available inside the classifier, but Apple surfaces preserve the last successful snapshot.

### Persistence honesty

Credential rotation, Keychain deletion, account index updates, snapshots, normalized history, notification state, and polling leases each have explicit failure paths. Storage failure is not collapsed into a provider-network state.

Account removal first tombstones the account across app and widget processes. It then clears credentials, current and prior snapshots, normalized and legacy history, pending event data, queued and delivered notifications, poll state, account-derived lock files, and damaged account-index backups. The account stays visible when a required cleanup fails so the user can retry. A final generation-scoped sweep prevents an older in-flight fetch from recreating removed state.

Async provider work owns an opaque scheduler lease. Release, result recording, cancellation, and lifecycle rotation can mutate only that exact lease. A late operation from an older account generation cannot clear the polling state of a prompt re-link. Notification identifiers also include an opaque lifecycle scope. Removal performs an account-wide sweep only while its tombstone is authoritative; stale post-delivery cleanup removes exact old-generation identifiers.

If an identity registry is unreadable, ordinary mutation remains blocked. Settings exposes a separately confirmed full local reset. The reset blocks new notification drains, waits for older account cleanup and notification delivery, replaces even a corrupt lifecycle registry with tombstones under the shared lock, deletes every enumerable Keychain credential and Vigil-owned local store, writes an empty account index, clears tombstones last, and performs a final owned-notification sweep. This ordering keeps app and widget writers invalid across crashes and partial failures.

### On-device history

Every accepted snapshot persisted by the app, background task, or widget also enters `UsageHistoryStore`. The store is `usage-history-v2.sqlite3` inside the App Group directory. It uses transactions, WAL mode, short-lived full-mutex connections, owner-only permissions, and iOS data protection. An external file lock coordinates legacy migration and whole-store deletion across processes.

Each window sample carries a segment identity derived from provider, window ID, and reset timestamp. A changed reset timestamp begins a new segment. Device observations remain distinct from historical buckets imported through an official provider API.

History retention is bounded to 400 days. Each account has independent capacities of 120,000 device observations and 5,000 provider-backfill records. A large provider import therefore cannot evict observed history for that account or another account. Every distinct successful fetch time remains a separate observation; only an exact duplicate write of the same fetch is idempotent. Corrupt history fails closed instead of being silently replaced.

Account detail reads summary counts without decoding the archive, then loads retained history newest-first with stable cursor paging. The normal archive page contains 100 records. This keeps launch and account-detail work bounded even when a source reaches its retention cap.

The current official backfill is limited to OpenAI API-platform organization data. A user-initiated import requests up to 365 days of documented completion-usage and organization-cost buckets with an Admin API key. Token quantities and costs remain separate because their provider grouping dimensions differ. These rows do not describe ChatGPT or Codex subscription activity.

Diagnostic export is intentionally smaller than the retained archive. It uses the bounded recent preview for each account and provenance source, then records `retainedSampleCount`, `exportedSampleCount`, and the `bounded-recent-per-account-and-source` selection rule in the report.

On upgrade, Vigil migrates the retired `usage-observations.json` money log into normalized observed metrics. Legacy UUIDs remain stable, so a retry cannot duplicate imported rows. The retired file is deleted only after every eligible reading is stored successfully.

## Authentication ownership

Claude and Codex sign-in mint credentials owned by Vigil. Only credentials marked as Vigil-minted may be refreshed automatically.

Manually pasted credentials are externally owned. Vigil never rotates their refresh credentials. This protects another client from refresh-token races.

## Fetch triggers

- App foreground: immediate ledger-gated attempt and a timer while active.
- Pull to refresh: ledger-gated with an explicit deferred result.
- iOS background: opportunistic `BGAppRefreshTask` execution.
- Widget timeline: fetches only when the snapshot is old enough and the shared ledger permits it.

iOS and WidgetKit decide when background work runs. Vigil cannot promise exact refresh times or five-minute sampling. The five-minute provider minimum is a rate floor, not a background schedule.

## Presentation rules

- Limits ranks accounts by required action and remaining quota.
- One decisive current window appears in each Home row. Complete windows and metrics live in account detail.
- Model-cap sections contain only windows whose provider contract explicitly identifies model scope. Generic secondary or labeled feature lanes are not assumed to be model caps.
- Device history is labeled `Observed by Vigil`. Provider-returned historical buckets are labeled `Imported from provider`.
- No calendar filter is applied to current provider reset windows.
- Experimental provider labels remain visible in onboarding and account surfaces.
- Stale or incompatible data never receives a Live label.

## Security posture

- Credentials use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in the shared Keychain group.
- Snapshots, normalized history, account metadata, leases, and notification state use the App Group container.
- New widget configurations and notification identifiers use non-reversible account digests. Existing raw widget selections remain readable only as an upgrade bridge.
- Provider traffic uses operating-system TLS directly from the device.
- Vigil has no collection server or analytics.
- The optional app lock uses system device-owner authentication with biometric or passcode handling. Vigil stores no biometric data.
- Root content is hidden from interaction and accessibility while locked. An opaque privacy cover replaces it whenever the scene is inactive or backgrounded, including app-switcher snapshots.
- The lock protects the app surface. It does not create a separate cryptographic boundary around Keychain or hide a configured widget.

See [Threat model](threat-model.md) and [Privacy](privacy.md) for precise limits.

## Known limits

- Consumer usage endpoints can be undocumented and can change without notice.
- Most opt-in fixtures are not sanitized Vigil production captures.
- Account-level poll leases do not create a global provider budget across several linked accounts.
- Background execution is opportunistic.
- Observed history can therefore contain gaps and cannot prove complete activity between readings.
- Balance and spend providers may have no percentage window suitable for a gauge.
- Vigil trusts the operating system certificate store and does not pin provider certificates.

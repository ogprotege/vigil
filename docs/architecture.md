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
│  │   ├─ SnapshotStore and observation history                          │
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
  id, label?, utilization: 0...100,
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

### Required-output contracts

Successful HTTP status is not enough. A provider response must parse and satisfy its declared minimum windows, metrics, IDs, exhaustive collections, and correlated-field rules.

This prevents a partial response from being labeled Live merely because one unrelated metric survived. Diagnostic partial output can remain available inside the classifier, but Apple surfaces preserve the last successful snapshot.

### Persistence honesty

Credential rotation, Keychain deletion, account index updates, snapshots, observation history, notification state, and polling leases each have explicit failure paths. Storage failure is not collapsed into a provider-network state.

## Authentication ownership

Claude and Codex sign-in mint credentials owned by Vigil. Only credentials marked as Vigil-minted may be refreshed automatically.

Manually pasted credentials are externally owned. Vigil never rotates their refresh credentials. This protects another client from refresh-token races.

## Fetch triggers

- App foreground: immediate ledger-gated attempt and a timer while active.
- Pull to refresh: ledger-gated with an explicit deferred result.
- iOS background: opportunistic `BGAppRefreshTask` execution.
- Widget timeline: fetches only when the snapshot is old enough and the shared ledger permits it.

iOS and WidgetKit decide when background work runs. Vigil cannot promise exact refresh times.

## Presentation rules

- Home leads with plan-wide session and weekly windows and can include a compact subset of model or special lanes, plus balances and spend.
- Models is the complete model-only list and contains only genuine model-specific or model-associated quota lanes.
- An account with no model-specific lane does not contribute a fallback weekly row to Models.
- Experimental provider labels remain visible in onboarding and account surfaces.
- Stale or incompatible data never receives a Live label.

## Security posture

- Credentials use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in the shared Keychain group.
- Snapshots, account metadata, leases, and notification state use the App Group container.
- Provider traffic uses operating-system TLS directly from the device.
- Vigil has no collection server or analytics.
- The optional app lock reduces casual access. It does not create a separate cryptographic boundary around Keychain.

See [Threat model](threat-model.md) and [Privacy](privacy.md) for precise limits.

## Known limits

- Consumer usage endpoints can be undocumented and can change without notice.
- Most opt-in fixtures are not sanitized Vigil production captures.
- Account-level poll leases do not create a global provider budget across several linked accounts.
- Background execution is opportunistic.
- Balance and spend providers may have no percentage window suitable for a gauge.
- Vigil trusts the operating system certificate store and does not pin provider certificates.

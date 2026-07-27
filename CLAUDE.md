# CLAUDE.md

This file gives coding guidance for this repository.

> Status: current
>
> Last reviewed: 2026-07-26
>
> Review again: after any architecture, provider, build, test, or release-process change

## What Vigil is

Vigil is an iOS 17+ AI usage monitor. It polls provider endpoints directly from the iPhone. There is no Vigil server.

Every credential is provisioned on the phone:

- Claude uses Vigil's own PKCE OAuth mint.
- ChatGPT/Codex uses OpenAI device authorization.
- Other providers use a key, account identifier, or session credential pasted into the app.

Credentials live in Apple Keychain. The app and widget share snapshots, leases, account metadata, and normalized history through the App Group container.

Fourteen providers ship in the registry. MiniMax global and China, Z.ai, Cursor, and Kimi K3 remain experimental because their endpoints lack both a stable vendor contract and a sanitized Vigil production capture.

## Commands

### Documentation

```sh
scripts/check-docs.sh
```

### Swift core

```sh
swift test --package-path packages/VigilKit
```

Swift tests locate the repository through `#filePath` and read `protocol/` directly. Run them from a full checkout.

The package retains `.macOS(.v14)` only because Swift package tests execute on macOS hosts. Vigil does not ship a macOS app.

### iOS app

```sh
cd apps/apple
xcodegen generate

xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
test -n "$DEVICE_UDID"
echo "Testing on simulator: $DEVICE_UDID"
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

The generated `.xcodeproj` is not checked in. XcodeGen reads `apps/apple/project.yml` as required by ADR-0002.

Device and App Store builds use manual distribution signing scoped to `[sdk=iphoneos*]`. Simulator builds remain signing-free. See `docs/development/release.md` before changing release settings.

CI uses `.github/workflows/apple.yml`. It validates documentation, runs VigilKit tests, generates the project, builds the iOS Simulator app, runs the complete iOS scheme, and validates property lists and entitlements. Device-only Keychain, background refresh, notification, and WidgetKit behavior still require an on-device release walk.

## Architecture: one contract, one shipped implementation

`protocol/providers.json` is the reviewable source of truth for provider endpoints, headers, poll policy, response mappings, required-output contracts, capabilities, and manual-entry guidance.

Swift's `ProviderRegistry` hand-mirrors the runtime fields so the app has no runtime dependency on a repository JSON file. `SpecParityTests` compare those compiled constants with `providers.json`. `FixtureParityTests` run every fixture through the Swift mapper and compare the normalized result with its expected output.

Fixture parity proves mapping behavior, not upstream truth. Every fixture must have a provenance entry in `protocol/fixture-provenance.json`. Use the narrowest true evidence class: `live_sanitized`, `vendor_example`, `community_research`, or `synthetic_derived`.

Adding a provider is not data-only. It may require credential entry, OAuth, request construction, response mapping, tests, UI presentation, privacy analysis, and documentation. Follow `docs/development/provider-contribution.md`.

### Normalized model and error taxonomy

- `UsageWindow`: reset-based utilization from 0 through 100.
- `UsageMetric`: balance, spend, limit, or remaining amount without an invented denominator.
- `ProviderSnapshot`: provider, account identity, fetch time, status, windows, and metrics.
- Statuses: `ok`, `authExpired`, `rateLimited`, `schemaChanged`, and `network`.

A successful response becomes `schemaChanged` when parsing fails or the provider's required-output contract is not met. Partial mapping must never be labeled Live. Apple surfaces retain the last successful snapshot for diagnosis and presentation.

## Invariants

- Never poll a provider faster than `poll.minSeconds`. Every current provider has a 300-second floor.
- Apple fetches acquire a durable account-level lease before network I/O. Ledger failure fails closed.
- Claude requests require the exact configured `User-Agent` and beta header.
- Refresh only credentials marked as minted by Vigil. Never rotate a credential copied or pasted from another client.
- Credentials go in Keychain. Snapshots, ledgers, account indexes, and notification state go in the App Group container.
- Reset countdowns are client-computed. A ticking countdown does not imply a recent network fetch.
- Provider failures stay isolated. One account must not stop another account's refresh.
- Missing required windows or metrics mean provider drift, even when an unrelated value mapped.
- VigilKit remains UI-free. Browser presentation, account forms, notifications, widgets, and view copy belong in the app target.
- Home shows one decisive provider value per account. Account detail shows every accepted window and metric without treating a metered-feature label as model scope or inventing missing limits.

## Key documents

- `docs/index.md`: current documentation index and authority rules.
- `docs/product-contract.md`: user-facing product and truth boundaries.
- `docs/development/architecture.md`: system boundaries and reliability mechanisms.
- `docs/providers/support-matrix.md`: provider contracts, evidence, and stability.
- `docs/development/provider-contribution.md`: complete provider change checklist.
- `docs/threat-model.md`: security boundaries and accepted risks.
- `docs/user-guide/privacy-deletion-notifications.md`: user-facing storage, notification, backup, and deletion claims.
- `docs/development/release.md`: TestFlight and App Store runbook.
- `docs/documentation-health.md`: review schedule and known documentation debt.
- `docs/decisions/`: historical and current design decisions.

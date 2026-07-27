# Vigil iOS 0.15 release-candidate code review

Last updated: 2026-07-26

## Decision

**Approve version 0.15.0, build 16 for a signed release archive.** No unresolved
P0 or P1 code defect remains in the reviewed candidate. Exporting that archive
uses `destination=upload`, so App Store Connect and Internal TestFlight remain
a separate, explicitly approved release action.

Vigil now has one clear recurring job: show which linked AI limit needs
attention next. Home stays concise. Account detail owns complete quotas,
balances, model lanes, source limitations, history, official imports, and an
account-scoped diagnostic export.

## Product truth

- First launch offers Claude, ChatGPT/Codex, and Other Provider in that order.
- Other Provider excludes the two guided providers and locks the selected
  provider in its credential form.
- Home ranks action-required accounts first, then the most depleted accepted
  provider window. It does not apply calendar filters to provider reset windows.
- Account detail shows every accepted window, exact used, limit, and remaining
  amounts when the provider supplied them, balances, spend, credits, and genuine
  Claude, Codex, and Cursor model lanes.
- A subscription label identifies an allowance tier. It is not converted into
  a fictional token or message ceiling. Claude and Codex workload costs vary,
  so exact amounts appear only when the provider returns an exact denominator.
- OpenAI official history is limited to API-organization completion usage and
  organization costs. It is never labeled ChatGPT or Codex subscription history.

## On-device history and diagnostics

`UsageHistoryStore` is a protected App Group SQLite archive using WAL, a
cross-process lock, owner-only permissions, bounded retention, cursor paging,
and corruption refusal. Every distinct successful fetch time can remain a
separate observation. Reset timestamps define provider segments.

Retention is 400 days, with independent per-account limits of 120,000 observed
records and 5,000 provider-backfill records. A large administrative import
cannot evict the device observations for that account or another account.

The compact history row answers what mattered at that moment. Expanding it
shows every normalized window, quantity, and metric, including exact amounts,
reset time, duration, source, provider period, retrieval time, and status.

Settings exports all linked accounts. Account detail exports one account. Both
exports use an allow-listed, credential-free schema and a bounded recent history
subset. The report states retained and exported counts and the selection rule.
It excludes credentials, cookies, authorization headers, raw responses,
credential-derived IDs, and free-form provider or account labels.

## Cache and authentication boundary

Current provider polling and Claude/Codex token exchanges use an ephemeral URL
session with cache reuse and cookie persistence disabled. On launch, build 16
removes only Vigil's app-scoped default-session cache and cookies left by builds
through 0.14. Confirmed full recovery repeats that cleanup.

Vigil neither reads nor deletes Safari, Claude, ChatGPT, Perplexity, Moonshot,
or another app's private cache or login store. The browser approval session
remains system-owned.

## Identity, reset, and concurrency review

No inverse lock ordering or stale-owner persistence path remains in the reviewed
flows.

- Shared lifecycle generations guard app and widget snapshot, history, pending
  event, credential-rotation, and scheduler mutations.
- Scheduler acquisition returns an opaque lease. Release, charging, result
  recording, and lifecycle retirement require the same lease owner.
- Removal tombstones identity before deleting data, serializes duplicate
  callers, blocks same-key re-linking until cleanup returns, and performs final
  state sweeps.
- Re-link preserves the selected Vigil account key, verifies provider identity,
  rotates the generation, and discards late results from older operations.
- Widget configuration uses an opaque hash identifier. Legacy raw selections
  migrate, but a widget can no longer create lifecycle authority or publish an
  account removed during a suspended timeline request.
- A corrupt account index, lifecycle registry, or Keychain payload fails closed.
  The explicit full reset force-tombstones every known storage root before
  deleting credentials and caches.
- Full reset invalidates suspended account operations, serializes destructive
  history I/O, waits for older account cleanup and notification delivery, blocks
  new refreshes and drains, performs a final Vigil-notification sweep, writes
  verified empty identity stores, then re-enables setup.
- The separate repair-backup deletion removes only the preserved damaged index.
  It does not delete accounts, credentials, snapshots, or history.

The focused recovery review found no remaining P0 or P1 reset, cache, widget,
notification, or identity race after these changes.

## Privacy and release configuration

- App and widget bundle identifiers, App Group, Keychain group, signing team,
  manual distribution profiles, and encryption declaration are consistent.
- Both executable bundles carry privacy manifests. CI now lints both manifests
  as well as Info plists and entitlements.
- Release builds set `VALIDATE_PRODUCT=YES` in the generated project.
- `scripts/verify-ios-archive.sh` asserts app and widget versions, identities,
  signatures, signed entitlements, embedded profiles and expiration dates,
  privacy declarations and required-reason codes, and matching dSYMs.
- The verifier passed against the existing signed 0.14.0 (15) archive before it
  was adopted for build 16.

## Verification evidence

- `git diff --check`: passed.
- `swift test --package-path packages/VigilKit`: 189 tests, 2 opt-in live
  endpoint probes skipped, 0 failures.
- iPhone 17 Pro, iOS 26.5 Simulator full scheme: 134 tests passed,
  including 126 app tests and 8 UI tests, with 0 failures or skips.
- UI coverage includes first launch, all setup routes, Home, account detail,
  targeted Re-link, Settings diagnostics, destructive removal confirmation,
  privacy lock modality, default text, XXXL, and accessibility XXXL.
- Generic unsigned iOS Simulator build: passed.
- Release build settings resolve version 0.15.0, build 16, and
  `VALIDATE_PRODUCT=YES`.
- Reconstructed runtime captures are stored beside this review for first launch,
  Home, account detail, and the modal privacy lock.

## Remaining device and provider checks

These are external acceptance checks, not known code defects:

1. Confirm signed App Group and shared Keychain access on a physical iPhone.
2. Exercise live Claude, Codex, and optional OpenAI Admin credentials. Provider
   endpoints and account policies can change independently of this repository.
3. Confirm WidgetKit reconciliation, local notifications, device-owner
   authentication, and opportunistic background refresh in the TestFlight build.
4. Accept that iOS cannot promise five-minute sampling and that no provider can
   supply historical subscription activity it does not expose.

## Release boundary

Create and verify the signed archive from the clean, rebased release commit.
Do not run `-exportArchive` until the release owner confirms this exact action:

> App 6792373775, version 0.15.0, build 16, upload and distribute to Internal
> TestFlight.

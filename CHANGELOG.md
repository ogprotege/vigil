# Changelog

## Versioning

Anything that changes shipped behavior gets an entry here: TestFlight app builds, provider contracts, registry changes, and local-state migrations. Historical command-line releases remain below as project history.

## Unreleased

- Reduced the account history preview from five short-lived SQLite connections per account to one: `UsageHistoryStore.accountState` reads all provenance summaries and both source pages over a single flock acquisition and checkpointed close, shortening the window where a suspension could kill the app for holding history locks.
- Extended the suspension guard to shared snapshot reconciliation, closing the last unguarded cross-process file-lock path in the app process.
- Restored Vigil's product identity in the README with the existing gauge mark,
  a restrained status badge set, clear navigation, and current iOS screenshots.
  Account values in the Limits image come from the gated demo-data path.
- Reworked the documentation index around user, data-interpretation, and
  maintainer routes. Reconciled the build 17 release record after PR #25 merged.

## 0.15.0 (18) — TestFlight internal candidate, 2026-07-27

- Fixed two TestFlight 0xdead10cc kills (0.15.0 build 17): iOS terminated the app when it was suspended while still holding the history file lock or SQLite WAL locks. Every lock-holding history read/write — including the persistence tail of each fetch — now runs inside a `SuspensionGuard` background-task assertion in the app target, so suspension waits until the locks are released. VigilKit and the widget extension are unchanged.

## 0.15.0 (17) — TestFlight internal candidate, 2026-07-27

- Fixed ChatGPT / Codex linking against OpenAI's current usage response. Vigil now accepts independently optional primary and secondary windows and a valid inactive `spend_control` wrapper instead of rejecting the authorized account as a schema change before saving it.
- Preserved fail-closed behavior for reached spend controls, concrete individual limits, unknown limit reasons, and malformed spend-control wrappers.
- Added a live-sanitized fixture and an app-level transaction test proving the verified account is stored and survives model reload.

## 0.15.0 (16) — Internal TestFlight, 2026-07-27

**Documentation now has one current source for each claim.** The product contract, user guides, provider support matrix, development references, diagnostic schema, and fail-closed release runbook replace duplicated setup and release instructions. Compatibility paths now route readers to the canonical files. CI checks local documentation links, review metadata, code fences, canonical paths, and release identity.

**Vigil now answers one question first: which AI limit needs attention next.**
Home ranks provider failures that require action first, then current finite quotas
by least remaining allowance. Stale, reset-pending, and unknown accounts no
longer outrank a fresh critical limit. Account detail holds every genuine
provider window, exact amount the provider supplied, balance, provider-declared
special lane, reset time, source explanation, and history action. Codex
additional limits remain metered features unless a separate provider field
proves model scope.

**Observed history is now a real normalized SQLite archive.** The app and widget
share it through the App Group, and every distinct successful fetch time remains
a separate on-device observation even when values did not change. Readings
retain utilization, exact used and limit values when supplied, balances, spend,
retrieval time, and provider reset segments. A one-time, retry-safe migration
preserves earlier money observations. Account archives read retained rows with
stable cursor paging instead of loading the whole database. The rolling archive
keeps up to 400 days, with independent per-account caps of 120,000 observations
and 5,000 provider-backfill records.

**Diagnostic exports are bounded and explicit about their scope.** The JSON
report exports only a recent per-account and per-source history selection, then
records both the total retained sample count and the exported sample count. It
remains credential-free and excludes raw provider responses and free-form
account or provider-controlled labels.

**Official history is explicit and correctly scoped.** OpenAI API-platform
organization Usage and Costs can be imported only after the user taps the
account-detail import action. The app no longer starts a 365-day import during
linking. Every surface warns that an Admin API key is a broad organization-owner
credential, although Vigil itself sends only documented GET requests. These
buckets never claim to represent ChatGPT or Codex subscription activity, and
organization costs remain separate from completion-token groups.

**Reset and notification state now fail honest.** A provider value whose reset
passed after its fetch is hidden until a new provider response arrives. Neither
the app nor widget rewrites it as a fabricated zero. Parked threshold alerts
carry observation and reset-segment metadata, then revalidate against a fresh
shared snapshot before delivery. Legacy, expired, mismatched, and no-longer-
crossed alerts are removed instead of interrupting the user with stale claims.

**Account transactions now have explicit recovery and cancellation boundaries.**
Damaged history cannot leave removal permanently stuck. Vigil offers a separate,
clearly destructive choice to erase all local history and finish cleanup. A
canceled add or re-link cannot cross from delayed verification into Keychain,
account-index, lifecycle, snapshot, or history mutation, and late tasks cannot
present setup prompts after dismissal. Removal and re-link operations use
generation-scoped notification identifiers and operation-scoped polling leases,
so an older async completion cannot erase or republish a newer lifecycle.
Duplicate removal is serialized per account. Upgrade cleanup removes polling
rows, account lock files, and raw-key notification identifiers left by earlier
builds.

If the account index, Keychain payload, or lifecycle registry cannot be decoded,
Vigil now remains fail-closed and offers an explicit **Erase Vigil data and
start over** action in Settings. After confirmation, it invalidates every app
and widget generation before deleting all Vigil Keychain credentials, local
history, snapshots, notifications, polling state, and damaged identity data.
Setup is re-enabled only after an empty account index and lifecycle registry are
written successfully.

Provider polling and Claude/Codex token exchanges now use an ephemeral,
cache-disabled session with cookies disabled. On launch, Vigil removes only its
own legacy `URLSession.shared` response cache and cookie residue from earlier
builds. It does not touch Safari or provider-app sessions. Full recovery also
waits for any already-started notification delivery, performs a final owned-ID
sweep before success, and clears the legacy network residue again.

**Privacy protection now covers both foreground access and app-switcher
snapshots.** The optional lock uses device-owner authentication, including the
system passcode fallback. Protected content is hidden from interaction and
accessibility while locked. An opaque cover replaces account content whenever
the scene is inactive or backgrounded. Account removal tombstones the identity
before cleanup, removes queued and delivered notifications, account-derived
snapshot and event lock files, SQLite history rows, legacy observations, poll
metadata, and damaged-index backups, then prunes the lifecycle tombstone after
the final sweep.

This candidate also replaces period and Models navigation with phone-native
setup choices, urgency summaries, account-scoped details, honest provider-plan
context, opaque widget account identifiers for new configurations, and large-
text coverage for the critical flows. Existing widget configurations remain
readable during migration. Physical-device sign-
in, App Group, WidgetKit, background refresh, and notification behavior remain
the final TestFlight acceptance gate.

## 0.14.0 (15) — TestFlight internal, 2026-07-22

**Vigil is now an iOS-only, phone-native product.** The macOS app target,
menu-bar UI, computer credential import, QR scanner and paste surfaces, custom
credential URL scheme, camera permission, and TypeScript command-line package
were removed. Every account is now provisioned on the iPhone: Claude through
Vigil's PKCE sign-in, Codex through device authorization, and other providers
through manual credential entry.

**The security boundary is smaller.** No app surface reads another program's
credential files or Keychain items. The app no longer accepts plaintext
credential handoff payloads. Apple targets require no camera permission or
custom URL scheme. The already-published `vigil-link@0.2.0` artifact remains
installable until the package owner completes the authenticated npm deprecation
step in the release runbook. Historical release entries and ADR rationale
remain for auditability.

**One implementation now owns provider behavior.** The provider JSON contract,
Swift `ProviderRegistry` mirror, deterministic fixtures, expected normalized
outputs, and fixture provenance remain. Swift parity and fixture tests replace
the former cross-language parity gate. `VigilKit` retains a macOS package
platform only so package tests can execute on macOS CI hosts; no macOS Vigil
application ships.

**Documentation now matches the product.** Setup, architecture, privacy,
security, troubleshooting, provider contribution, release, and repository
guidance describe only the iOS app and widgets. ADR-0003, ADR-0004, ADR-0006,
and ADR-0007 are marked superseded. ADR-0005 is amended around phone-native
mint ownership.

**Provider hardening from build 13 is preserved.** Required-output contracts,
fixture provenance, strict partial-mapping detection, corrected Claude
fractional timestamps and model percentages, Codex nested model lanes, honest
experimental labels, and Models-only genuine model lanes remain in build 15.

The release gate consists of VigilKit tests, an iOS Simulator build, the iOS app
test target, property-list and entitlement checks, archive version assertions,
signature verification, and an on-device phone-native sign-in walk.

## 0.13.0 (13) — TestFlight internal, 2026-07-22

**Provider contracts now follow observed or published response shapes.** The
previous fixtures often repeated the mapper's assumptions, so TypeScript and
Swift could agree while both were wrong about the provider. This release
audits all 14 registry entries and records an evidence class for every fixture.
Only the Claude 429 and scoped-limit bodies are `live_sanitized`; every other
fixture is labeled as a vendor example, community research, or synthetic case.

Provider corrections:

- **Claude:** extra-usage minor units now scale to major currency units. Active
  `weekly_scoped` entries read `percent`, and fractional reset timestamps stay
  compatible across TypeScript and Swift.
- **ChatGPT / Codex:** each `additional_rate_limits` entry can fan into nested
  primary and secondary model windows. IDs use `metered_feature`, labels use
  `limit_name`, and durations determine session versus weekly lanes. Flex
  credits and reset credits are mapped. The current production response shape
  was rechecked through the poll gate without retaining account data.
- **OpenRouter:** lifetime, daily, weekly, monthly, and BYOK usage are distinct.
  Optional key spending limits no longer masquerade as an account balance.
- **Moonshot global and China:** explicit response envelopes and required
  balance outputs fail closed. Both contracts are vendor-documented and no
  longer labeled experimental. The global fixture copies the vendor example;
  the China debt case is synthetic. Neither is a Vigil production capture.
- **MiniMax global and China:** `model_remains` is read at the response root,
  with the older nested wrapper retained as a fallback. Status-3 lanes are
  omitted, string percentages remain supported, and provider auth errors
  inside HTTP 200 bodies become `authExpired`. Both providers are now visibly
  experimental.
- **GitHub Copilot:** gross, discount, and net quantities now retain their
  documented meanings. Billable spend comes from `netAmount`.
- **xAI:** signed cent-denominated prepaid balance is converted to positive USD
  with the correct 100:1 scale. The vendor-documented endpoint is no longer
  mislabeled experimental.
- **Z.ai:** 5-hour and weekly token windows are selected by type, unit, and
  duration. Millisecond resets parse correctly. Web-search quotas remain
  scalar call metrics instead of being mislabeled token windows.
- **Cursor:** the billing reset comes from the response root, supports current
  individual and team shapes, and plan utilization can fall back to exact
  used/limit ratios. On-demand cents and model lanes map separately.
- **Kimi K3:** session counts under `limits[].detail` and weekly counts under
  `usage` now compute exact utilization. Fractional ISO reset timestamps parse,
  and zero limits fail closed.
- **Moonshot global/China, DeepSeek, and OpenAI:** body envelopes and required
  metric IDs now prevent explicit provider errors or renamed fields from
  becoming a healthy zero.

**Partial mapping is no longer Live.** Registry version 2 adds required-output
contracts, body-error envelopes, ordered source fallbacks, selected/omitted
array entries, root-relative fields, used/limit ratios, duration-derived IDs,
and nested dynamic-window fan-out. A successful response becomes
`schemaChanged` when a required window or metric disappears, or when an
eligible dynamic entry maps incompletely. The classifier retains partial output
for diagnosis, while Apple surfaces preserve the last successful snapshot.

**Models means models.** The Models tab no longer falls back to primary plan
windows and no longer accepts unrelated secondary caps such as Claude OAuth-app
or Cowork limits. It shows only named/model-scoped lanes.

**Release artifacts are deterministic.** Build 13 uses build-specific archive
and export paths, and App Store Connect may not silently rewrite the build
number during export. The signed `0.13.0 (13)` archive was version-checked,
signature-verified, and uploaded successfully to App Store Connect on
2026-07-22.

Release validation passed from a clean CLI install: 240 CLI tests, 148
VigilKit tests with only the two opt-in live probes skipped in the offline
suite, 81 app tests, the iOS Simulator build, package dry-run, and dependency
audit. The two live authorization probes then passed separately against the
real Claude and Codex endpoints.

## 0.13.0 (12) — TestFlight internal, 2026-07-22

**Claude limits display at all again.** The app showed a Claude account as
"Live" with nothing but "Extra usage (month) $0" — no 5-hour, no weekly, no
per-model — while `vigil-link status` showed all of them. Two independent bugs,
both found by running the app's own code path against the live endpoint instead
of against fixtures:

- **Every Claude window was being discarded on parse.** Claude returns
  `resets_at` with MICROSECOND precision (`2026-07-22T02:09:59.392525+00:00`).
  `ISO8601DateFormatter` without `.withFractionalSeconds` returns nil for that,
  so `readBucket`'s reset guard failed and dropped every window. `extra_usage`
  is a metric with no timestamp, so it survived — which is exactly why the one
  thing on screen was the extra-usage number. The CLI was immune because
  JavaScript's `new Date()` parses fractional seconds natively. The parser fix
  shipped in build 11's changelog but build 11 was never uploaded; this is the
  first build that actually carries it.
- **Per-model caps never mapped.** `additionalWindows` read utilization via
  `responseFields.utilization`, but live `limits[]` entries carry **`percent`**.
  Every model-scoped window was dropped. The committed fixture asserted the
  non-existent `utilization` shape, so both mappers agreed about an API neither
  had ever seen — parity green, feature dead. The fixture is now the response
  captured live on 2026-07-21.

Verified against the live endpoint with both a Claude Code token and a freshly
minted one: session, weekly, and `Fable` (model-scoped) all map. A minted token
returns exactly the same body as a copied one — worth recording, because
ADR-0005 claimed mint was "verified end-to-end" on the strength of a 200 status
without ever checking that the body contained windows.

**The Models tab shows models only.** It fell back to an account's primary
session/weekly windows whenever that account had no per-model lanes, so a Codex
account rendered "Weekly limit" under "Per-model caps" — Home's data, on the
wrong screen, labelled as something it is not. Accounts with no per-model caps
now contribute nothing there and the existing empty state explains why.

This build also carries everything in (11), which was never uploaded.

## 0.13.0 (11) — unreleased internal candidate, 2026-07-21

Full-codebase audit: 233 agents across 14 dimensions, every finding
adversarially verified. 31 survived; all are fixed here.

**Poll floor (hard invariant).** A cancelled in-flight fetch released the ledger
lease without charging the clock. The request was already on the wire, and
backgrounding the app cancels the refresh task group — so a
foreground/background cycle could send one Claude request per cycle with no
floor at all. New `FetchScheduler.chargeFloor` releases the lease *and* advances
`nextAllowedAt` (never pulling an existing 429 backoff earlier); a bare release
is now reserved for attempts where nothing was transmitted.

**Mapper parity (the app reported money the CLI knew was wrong).**

- Swift's aggregate `collect` dropped absent leaves, making the "leaves exist
  but none parsed" drift check unreachable. A provider renaming a billing field
  produced a confident **$0.00** in the app while the CLI correctly reported
  schemaChanged. Swift now mirrors the TS frontier exactly.
- A non-array aggregate root (an error envelope, a pagination wrapper) was read
  as an empty period and summed to $0.00 in **both** implementations. Only a
  genuinely empty array is a zero-spend month now.
- Swift rejected ISO-8601 timestamps with fractional seconds, so a cosmetic
  serializer change upstream would have dropped every Claude window while the
  CLI kept working. Both forms parse now.
- Swift rejected Unicode format characters (Cc+Cf) that TS accepted (Cc only),
  so a zero-width character in a provider label made a window visible in the CLI
  and silently absent from the app. TS now rejects both categories, which also
  closes bidi-override spoofing in terminal output.
- The shared `ISO8601DateFormatter` was mutable global state used from
  concurrent mapping — a data race, and a hard error in Swift 6. The codebase is
  now clean under `-strict-concurrency=complete`.

**Honest freshness.**

- The Models tab rendered preserved last-good windows with a live-ticking
  countdown and no marker of any kind — a three-day-old number presented as
  current. Rows now carry their snapshot's status and age.
- Connections showed a benign yellow "Stale" for *every* non-ok status, so
  "Re-link needed" and "Provider changed" were unreachable on the screen you go
  to in order to re-link.
- A transport failure on the post-refresh retry was reported as "Sign-in
  expired" even though the refresh had succeeded and the new token was saved —
  pushing users to re-link, which stranded a duplicate account row.
- The widget rendered `Date.distantPast` as a relative age (~2,000 years) for an
  account whose first fetch failed.

**Data loss and deletion.**

- `removeAccount` raced an in-flight refresh: the completed fetch rewrote the
  snapshot file, re-added an observation carrying the removed account's spend,
  and recreated its ledger entry — so a prompt re-link was then refused. The
  resume path now re-checks membership and sweeps anything a late write left.
- `UsageObservationStore` swallowed read errors and overwrote the file, so one
  corrupt read destroyed up to 400 days of history on the next poll — inverting
  the alert's promise that totals recover. Both `append` and `removeAll` now
  fail closed, like `SnapshotStore` and `PendingEventStore`, with a test pinning
  that the corrupt bytes survive.
- `removeAll` reported success when the file was unreadable, leaving the removed
  account's dollar amounts on disk while the UI said they were gone.

**Other correctness.**

- **CLI hang (blocker).** In the classic link flow the paste prompt ignored its
  AbortSignal, so after a successful browser mint the stale readline question
  swallowed every later prompt: the CLI hung forever at the consent gate, or —
  with `--yes` — left the credential QR on screen and never cleared it.
- Widget timelines were never reloaded after a refresh, so the home screen
  disagreed with the app for up to 30 minutes and a successful background fetch
  produced no visible change.
- `FetchScheduler`'s storage error was one actor-wide slot that concurrent
  accounts overwrote and cleared, so a ledger failure could be blamed on the
  wrong account or silently reported as an ordinary deferral. It is keyed by
  account now.
- The Codex device-code poll interval was unbounded, so `"inf"` from the server
  trapped converting to `UInt64` — an uncatchable crash on opening the sign-in
  screen.
- The paste screen filtered tokens by `hasPrefix("vigil")`, which matched the
  word "vigil-link" in the CLI's own output, so pasting exactly what the app
  told you to copy failed to decode.
- A CLI transport failure while streaming the response body was reported as
  schemaChanged ("provider changed their format") instead of network, and
  skipped the retry loop.
- The macOS app lock covered the main window but not the menu bar, which kept
  showing account labels (including the Codex sign-in email), live percentages
  and a working Refresh with no authentication.
- `connectionLabel` reported "OAuth" for QR-handed-over credentials Vigil copied
  and will never renew; only an explicit mint source claims that now.
- VoiceOver: Home's per-limit reset countdown was unreachable, and the freshness
  line was six separate stops per account including a bare "·".

**Docs.** Ten locations (and two CLI strings) told users to tap "Add a provider
directly", a control that does not exist — the shipped path is
**Add account → Paste a provider key → provider**. `cli/README.md` claimed
thirteen providers and that `status`/`doctor` scan every provider (only the
wizard does). `provider-spec.md` listed Kimi K3 as both shipped and deliberately
held back. README/FAQ described a "Model and special limits" grouping the app no
longer has.

## 0.13.0 (10) — TestFlight internal, 2026-07-21

Phone-native reliability pass — stop depending on `npx vigil-link` for core setup, and make Limits / Models actually fill after adding keys:

- **A failed link verify no longer burns the poll floor when nothing reached the provider.** A flaky network used to charge the scheduler, so the next attempt hit "polling safety cooldown deferred" / "Network problem" and left Home + Models empty. Verify now releases the lease when no request got through; a real provider answer — including a 401 — still charges the clock (see the invariant fix below).
- **Auth errors no longer say "Re-run npx vigil-link".** Phone paste / Sign in paths tell you to check the key or sign in again. `vigil-link` stays optional for computer QR handoff only.
- **Models tab fills for coding plans.** Accounts with only primary session/weekly windows (Kimi K3, Z.ai, …) now appear in Models; empty state explains balance-only providers (OpenRouter, DeepSeek) belong on Home.
- **Home shows every provider window** (session, weekly, and model caps) in one stacked list. The Watchline hero is replaced by the period summary described below; per-model caps live on the Models tab. Color scheme unchanged.
- **Cancel on verify / Claude exchange overlays** so a hung 15s timeout is not a dead end.
- Manual-entry hints for Claude / OpenRouter / DeepSeek no longer point at the CLI.
- **Local-first setup (token-monitor style).** Mac can **Import from this Mac** — reads `~/.claude/.credentials.json` and `~/.codex/auth.json` with no browser OAuth and no npm. Add Account now leads with paste/import; Sign in with Claude/Codex is demoted to optional "mint a renewing token." New `LocalCredentialDiscovery` in VigilKit mirrors the CLI discovery parsers, including the macOS login-Keychain fallback.
- **Home redesigned like token-monitor Limits.** Day / Week / Month / Year / Lifetime period picker, hero summary, a limits section with a one-tap refresh button (same feel as token-monitor's circular refresh), and compact per-provider cards showing the windows that match the selected period + "Updated Xm ago". Absolute token totals from local transcripts aren't available on iPhone — spend/balance history is recorded on-device for period heroes when providers report those metrics.
- **Honest refresh feedback.** Tapping refresh reports whether providers were actually fetched, deferred by the poll floor (with next safe time), or failed — so Home never pretends a gated tap was a live update. Poll clocks hydrate on launch.

Build fixes found cutting this build (the merged branches left `main` red — the
`apple` CI job had been failing since PR #12, so the iOS build break was never
reached):

- **iOS build restored.** `LocalCredentialDiscovery`'s default-path helpers used
  `FileManager.homeDirectoryForCurrentUser`, which is unavailable on iOS, so the
  whole app target failed to compile. The four filesystem helpers are now
  `#if os(macOS)`-gated — matching the feature, which is Mac-only — while the
  pure `parse*` functions stay cross-platform.
- **VigilKit tests compile again.** `LocalCredentialDiscoveryTests` passed an
  optional `Date?` to `XCTAssertEqual(_:_:accuracy:)`; it now unwraps first.
- **First-run empty state restored.** The Home redesign deleted
  `EmptyDashboardView` but kept its call site, so a fresh install with no
  accounts referenced a missing view. Restored unchanged.
- **`AppModel.refresh(account:surface:)`** is now `private`, matching the
  visibility of the `AccountRefreshOutcome` it returns.

Two invariant defects found by pre-release review of the same range:

- **The verify path no longer removes the 5-minute Claude poll floor.** The
  "failed verify releases the lease" change released it for *any* status other
  than `ok`/`429` — including 401/403 and a 2xx whose body did not map, which
  are completed provider round-trips. Because `release` never advances
  `nextAllowedAt` (still `.distantPast` on a fresh account), every retry was
  allowed instantly, so repeated Save taps on a wrong Claude token polled
  `api.anthropic.com` with no floor at all — violating a documented hard
  invariant. The clock is now charged whenever the provider answered; the lease
  is released only when no request reached it (transport failure, or a
  credential that cannot build a request). The genuine flaky-network case the
  original change targeted still retries immediately.
- **"Import from this Mac" could never find the files in a signed build.** The
  macOS app is sandboxed, where `homeDirectoryForCurrentUser` resolves to
  `~/Library/Containers/app.vigil.app/Data`, so the import read the container
  rather than the real `~/.claude` and `~/.codex` the entitlement grants. It now
  resolves the account's actual home via `getpwuid`.

Copy corrected to match the shipped UI: the Models empty state pointed at a
"Limits tab" this release renamed to Home, and claimed a wrong key "no longer
locks you out for five minutes" — which the poll-floor fix above makes untrue.

Two shipped changes this entry had omitted:

- **The Limits tab is now Home** (`VigilDestination.limits` → `.home`, house
  icon), which is why other copy referring to "Limits" was stale.
- **The macOS build requests two new sandbox entitlements** for local import:
  `files.user-selected.read-only` (the file picker) and a
  `temporary-exception.files.home-relative-path.read-only` for `.claude/` and
  `.codex/`. That is a security-posture change with App Store review
  implications; `docs/threat-model.md` now covers it and what happens if review
  refuses the exception.

Correctness fixes to the new period/history code, all found by the same review:

- **Spend deltas survive a counter reset.** `openai/spend_month`,
  `github/spend_month` and `claude/extra_used` all reset monthly, and Week /
  Month / Year are rolling ranges that always straddle a reset — so
  `last - first` reported `$0.00` or a meaningless difference. Deltas now sum
  consecutive rises and treat a drop as a reset. Balance-style metrics sum
  falls, so a mid-period top-up no longer reads as negative spend, and
  balance-only providers can produce a delta at all.
- **A single reading is no longer reported as `$0.00` spend.** One sample is a
  reading, not a delta; the hero now declines to claim a number instead of
  printing a confident zero for the first poll of every day.
- **The tightest limit outranks a balance in the Home hero.** Any account
  reporting a scalar metric used to suppress the percent-remaining hero for
  every account and period — so a linked OpenRouter balance hid a Claude
  session at 4% left. Limits lead; observed spend rides in the detail line.
- **Removing an account deletes its observation history**, which previously
  kept driving the hero and contradicted the "cached usage was deleted" copy.
- **Offline rows tell the truth.** The `.network` banner tested `windows` only,
  so every metric-only provider read "Not reached yet." while its cached
  balance was rendered directly beneath. It now checks metrics too and says
  "Offline · last known values."
- **History stops evicting its own baseline.** Identical consecutive readings
  are no longer appended, and the entry cap never discards an account's oldest
  sample — the row every delta measures from. Recording an observation also no
  longer decodes the whole file twice on the main actor.
- **Multi-balance providers record the primary metric.** Moonshot maps
  `balance` plus `balance_cash` and `balance_voucher`; last-wins meant the
  voucher sub-balance was stored as the account balance.
- **`testSpendDeltaAcrossDay` is no longer time-of-day dependent** — it pinned
  `Date()` against a `startOfDay` boundary and failed between local midnight
  and 01:00.

Local import on macOS also gained the **login-Keychain fallback** the CLI has
always had (`discovery.macosKeychain.service`) — the location macOS Claude Code
usually uses — and the file picker now shows hidden files and opens in the
directory the on-screen path names, since both targets are dot-paths it
previously could not display.

A second adversarial review of those fixes caught three more, now also closed:

- **A small drop in a spend counter is a correction, not a reset.** The first
  version of the reset handling booked the entire new reading for *any*
  decrease, so a two-cent refund on a $12.50 counter would have reported $12.48
  of spend — and re-added it on every downward tick. Only a drop below half the
  previous reading counts as a reset now; a shallow drop contributes nothing,
  which under-reports slightly instead of inventing a large number.
- **Period deltas seed from the last reading before the range.** Spend for a
  range is the value at the end minus the value at the start, and dropping every
  sample before the range meant a day whose first in-range reading was its only
  one reported nothing at all — which, with repeat readings now deduplicated on
  write, would have been most days. This also fixes a pre-existing under-report
  of every rolling period.
- **The Keychain lookup runs off the main actor.** `SecItemCopyMatching` reads
  an item owned by Claude Code and can block on a securityd prompt, which on the
  main actor froze the window on exactly the configuration the fallback exists
  to serve.

README screenshots and copy were regenerated against the shipped build: the old
ones still showed the removed Watchline and per-account card layout. Docs also
corrected: `getting-started.md` still walked users through the removed
Watchline; README and this entry claimed every provider row shows session *and*
weekly bars when a row shows the windows matching the selected period; and the
provider count was still thirteen (the registry has fourteen since Kimi K3).

## 0.13.0 (8) — TestFlight internal, 2026-07-20

Polish pass on the Models release:

- **Correct flagship model naming.** The Models view empty-state copy named a
  non-existent "Claire" Claude model; it now reads the real family (Fable, Opus,
  Sonnet). Fable is Claude's flagship — the labeled `weekly_scoped_*` windows
  and fixtures already used it correctly; this was the one stray copy string.
- **Fresh, accurate README screenshots.** The old shots predated the redesigned
  stacked limit meters and the Models view. Replaced them with current captures:
  the Limits dashboard (Watchline + per-account stacked session/weekly meters
  with live countdowns) and the new Models view (per-model caps — Fable weekly,
  Opus weekly, GPT-5.6 Sol, MiniMax video lanes — tightest first). Dropped the
  stale empty-state image.
- **Screenshot tooling (`VIGIL_DEMO` / `VIGIL_TAB`).** A tightly-gated,
  production-inert demo seed (`DemoData`) populates representative accounts and a
  preselected tab so screenshots can be captured from a fresh simulator with no
  credentials. It never writes to disk, never fetches, and is off unless
  `VIGIL_DEMO=1` — locked down by tests.

## 0.13.0 (7) — TestFlight internal, 2026-07-20

Adds the flagship coding-plan monitor requested alongside the Models view:

- **Kimi K3 coding plan** (`kimi_code`, opt-in · experimental). A new provider
  that reads Kimi's coding-plan usage endpoint (`api.kimi.com/coding/v1/usages`)
  and surfaces **session and weekly** limit windows — distinct from the existing
  balance-only Moonshot (Kimi) provider. Added on the phone (or via QR/paste)
  with a coding-plan key (`KIMI_CODE_API_KEY`), it feeds the new Models view so
  Kimi's per-plan caps sit next to Claude's model-scoped weeklies and Codex's
  per-model lanes. Registry, TS + Swift mappers, fixtures, and the Swift mirror
  land in lockstep (14 providers; CLI 163 tests, VigilKit 89 tests green).
- **Honest labeling.** The endpoint shape is modeled, not yet live-verified, so
  the provider carries the visible **Experimental** marker everywhere and needs a
  real coding-plan key to confirm the exact field/selector names before it's
  promoted. Docs (README, getting-started, FAQ, provider-spec, threat model)
  updated to match.

## 0.13.0 (6) — TestFlight internal, 2026-07-20

Follow-up to the mobile-first release:

- **Dedicated Models view.** A new Models tab gathers every per-model cap across
  all accounts — Claude Opus/Sonnet weekly, model-scoped caps, Codex per-model
  lanes, MiniMax video — into one tightest-first list, so model limits are no
  longer buried in an account-card subsection. The Limits view's windows now
  render as clean stacked meter bars (same colour scheme). Modeled on
  token-monitor's Limits + Models views.
- **Codex sign-in guidance.** The Codex device-code sign-in screen now shows the
  one-time OpenAI account requirement up front — enable "device code
  authorization" in ChatGPT → Settings → Security — so you don't hit OpenAI's
  refusal page first. (The on-device Codex flow itself is confirmed reaching
  OpenAI's device-code page from the phone.)
- **Documentation overhaul.** Fixed 26 audit findings: removed leftover
  terminal-first framing, corrected stale provider counts / ADR range / build
  number, fixed the deprecated `--loop` / QR auto-cycle description, and
  documented the on-device Claude/Codex sign-in flows across the doc set.

## 0.12.0 (4) — TestFlight internal, 2026-07-20

The mobile-first release: **every account now sets up entirely on the iPhone** —
Claude and ChatGPT/Codex sign in natively on-device (no computer), alongside the
API-key providers. Adds per-model and overage limit windows, a guided
`npx vigil-link` wizard for the optional computer path, and a full docs overhaul.
Detailed notes by track below. Both on-device OAuth flows are unit-tested and
build on iOS + macOS but still need a real-account device walk to confirm the
live sign-in round-trips.

### Native on-phone "Sign in with Codex" (PR E)

- **Codex can now be added entirely on the iPhone too** — every account is now
  phone-native. Add account → **Sign in with Codex** uses OpenAI's OAuth
  **device-code flow**: Vigil requests a one-time code, you approve it in the
  browser and enter the code, and Vigil polls for the tokens and mints its own
  renewable pair (`source: "mint"`). No computer, no `codex login`, no redirect
  handling. New `CodexAuth` in VigilKit (device-code request/poll builders,
  poll-status classification, form-encoded exchange, id_token account-id
  extraction — all unit-tested against the exact OpenAI shapes from the Codex
  CLI source).
- Codex gained an `oauth` block in the registry (`auth.openai.com` authorize/
  token/device endpoints, public client `app_EMoamEEZ73f0CkXaXp7hrann`),
  mirrored in Swift with spec-parity. `OAuthEndpoint` gained optional
  `deviceCodeUrl`/`deviceTokenUrl`. Minted Codex tokens now refresh through the
  shared `TokenRefresher` (independent of the Codex CLI — the "mint, don't copy"
  posture of ADR-0005); copied Codex tokens (`source: "file"`) still never refresh.
  `doctor` now reports Codex's refresh token.
- Onboarding now offers **Sign in with Claude** and **Sign in with Codex** as
  co-equal on-phone cards; the computer/QR handoff is fully optional.
- **Needs a device walk:** the on-device Codex flow (device-code request →
  browser approval → poll → exchange) is built and unit-tested against the
  documented OpenAI shapes but must be run once against a real ChatGPT account
  to confirm the live behavior (and Cloudflare posture — iOS's native TLS is
  expected to clear it where Linux CLIs are blocked).

### Set up on the phone — native "Sign in with Claude" (PR D)

- **Claude can now be added entirely on the iPhone**, no computer. Add account →
  **Sign in with Claude** opens Claude's OAuth approval in the browser; you paste
  back the code Claude shows, and Vigil exchanges it on-device for its own token
  pair (`source: "mint"`, so it auto-renews). This is the mobile twin of the CLI
  browser mint (ADR-0005), using Claude's out-of-band redirect instead of a
  desktop loopback server. New `ClaudeAuth` in VigilKit (PKCE, authorize URL,
  code parsing, token exchange — all unit-tested); `OAuthEndpoint` now carries
  `authorizeUrl`/`scopes`/`manualRedirectUri` (mirrored + spec-parity asserted).
- **Onboarding is now phone-first.** Add account leads with Sign in with Claude
  and the on-phone API-key providers; the `npx vigil-link` computer handoff is
  demoted to an optional path (at the time this was PR D's interim state, the
  only way to add Codex — superseded within this same release by PR E's on-phone
  Sign in with Codex).
- Hand-entered credentials are now marked `source: "manual"` (never auto-refreshed,
  per ADR-0005) — previously they were saved with no source.
- **Needs a device walk:** the on-device Claude OAuth (browser approval + code
  paste + token exchange) is built and unit-tested but must be run once against a
  real account to confirm the live browser/redirect behavior.
- **Codex research (GO):** confirmed OpenAI's Codex CLI uses an OAuth device-code
  flow that makes Codex fully on-phone too — now implemented in PR E above.

### Per-model and overage limit windows (PR B)

- **Claude model-scoped weekly caps** now surface. The live `api/oauth/usage`
  response carries model-specific caps only inside a structured `limits[]`
  array (`kind: "weekly_scoped"`, `scope.model.display_name`); Vigil maps each
  as a labeled secondary window (e.g. "Fable weekly") under **Model and special
  limits**. Fixture-modeled; **pending live re-verification** against a real
  account (field names / `kind` string may need the `additionalWindows.fields`
  override).
- **Claude extra-usage (overage) credits** now show as account metrics —
  spend-to-date and the monthly limit, in the response's own currency — instead
  of being dropped.
- **MiniMax `video` model** session and weekly windows are now mapped
  (previously only the `general` model was read), for both MiniMax and MiniMax
  China.
- Also added Claude's `weekly_oauth_apps` / `weekly_cowork` windows (null-safe,
  unverified) and a generalized `additionalWindows` registry mechanism (filter,
  dot-path id/label, id-prefix normalization, reset format, static duration,
  field overrides) plus a `unitKey` for currency-driven metric units.
- **Schema:** `UsageWindow` gains an optional `label` (model name). Additive and
  backward/forward-compatible — old persisted snapshots and older app/widget
  builds decode unchanged (the field is absent → nil). Both mappers, the Swift
  mirror, fixture parity, and spec parity updated in lockstep.
- Deferred (follow-up): Codex `rate_limits_by_limit_id` and the
  `rate_limit_reset_credits` balance (a second endpoint) — see the provider-spec
  backlog.

### vigil-link — guided setup wizard (PR A)

- `npx vigil-link` with no arguments now runs a guided wizard on an interactive
  terminal: it scans this computer for all 13 providers, shows what it found and
  what it didn't, lets you pick accounts (everything found preselected), walks
  you through pasting an API key for a missing provider (input hidden, held in
  memory only — ADR-0004), or signs you in to Claude via the browser. It then
  verifies each account, shows an auto-sized QR (multi-code handoff cycles until
  a keypress instead of manual Enter-advancing), and clears the screen.
- **A poll-deferred account is now included in the handoff instead of dropped.**
  Running `status` and then linking immediately no longer fails with "No account
  verified" — the account ships and the phone verifies it on its next refresh.
  The exit code is 0 whenever a payload is emitted.
- Added `--version` / `-V`, and friendly "did you mean" errors for unknown flags
  and commands.
- Deprecated `--loop` (multi-code cycling is now the default); it is accepted as
  a no-op with a notice. `--big`, `--no-clear`, `--no-verify` still work as
  overrides inside the wizard. `--provider`, `--json`, `--yes`, `--copy`, and
  `--mint` opt out of the wizard into the classic scripted flow (unchanged; the
  macOS app's `npx vigil-link --json --yes` paste path is untouched).
- The Claude browser-OAuth "paste a URL" prompt is now delayed ~15s and cancels
  itself when the loopback lane wins, so the happy path never shows it.
- No new runtime dependency: the prompts are hand-rolled (see
  [ADR-0007](docs/decisions/0007-hand-rolled-prompts.md)); the runtime supply
  chain stays at one package (`qrcode-terminal`). No protocol or registry change.
- iOS pairing copy updated to describe the wizard and rotating codes.

## 0.11.0 (3) — TestFlight internal, 2026-07-20

The full UI/UX redesign (PR #7): a `VigilTheme` design system, root navigation shell, a Connections management screen, a shared `UsagePresentation` layer with its own test suite, and overhauled dashboard, account cards, onboarding, manual entry, settings, menu bar, and widgets. Refreshed README screenshots. No protocol, registry, or CLI changes; this build otherwise ships the same 13-provider contract as 0.10.0 (2).

## 0.10.0 (2) — TestFlight internal, 2026-07-19

This release carries the audit remediation, the follow-up fix wave, and the 13-provider expansion (PR #6). The CLI half of these changes is versioned `vigil-link` 0.2.0 and is not yet published to npm; the npm release is a separate step. Existing users should read the migration notes before testing.

### Added

- Nine new opt-in providers (13 total). Stable tier: Moonshot/Kimi balances
  (`MOONSHOT_API_KEY`, `MOONSHOT_CN_API_KEY`), MiniMax Coding Plan windows
  (`MINIMAX_CODING_API_KEY`, `MINIMAX_CN_CODING_API_KEY`), OpenAI API
  month-to-date spend (`OPENAI_ADMIN_KEY`), GitHub Copilot AI-credit billing
  (`GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER`). Experimental tier,
  labeled everywhere: xAI prepaid balance (`XAI_MANAGEMENT_KEY` +
  `XAI_TEAM_ID`), Z.ai/GLM coding-plan quota (`ZAI_API_KEY`), Cursor plan
  usage (`CURSOR_SESSION_TOKEN`).
- Registry engine primitives, implemented identically in both mappers and
  pinned by fixtures: array-element selectors (`items[kind=general]`),
  summed metrics over `[]` flat-map paths with an honest zero-vs-drift
  distinction, metric `scale`, per-window field overrides,
  remaining-percent inversion, string-number tolerance, `unixMillis`
  resets, `{account_id}` URL templating, and computed UTC query params.
- A generic manual-entry account-id field driven by the spec templates, and
  an "Experimental" badge on every provider surface (pickers, account
  cards, CLI `status`/`doctor` output).
- Opt-in OpenRouter support through `OPENROUTER_API_KEY`.
- Opt-in DeepSeek support through `DEEPSEEK_API_KEY`.
- Scalar `balance`, `spend`, `limit`, and `remaining` metrics alongside reset-based percentage windows.
- Per-widget account selection through WidgetKit App Intents.
- Visible app alerts for credential, account-index, snapshot, and polling-ledger persistence failures.
- A CLI poll safety cache containing timestamps and 429 counters only.
- A shared Keychain access group with verified legacy-item migration for the
  app and widget.
- Provider contribution, troubleshooting, and threat-model documentation.
- Menu bar rows for scalar metrics and a read-only storage notice banner
  when a storage error is queued.
- A startup storage alert when the App Group container is unavailable and
  the app falls back to app-private storage.
- A privacy manifest for the widget extension.
- Hostile-input fixture pairs (`codex-usage-hostile`,
  `deepseek-balance-unicode`) that both mappers must satisfy.
- Absolute poll-floor tripwire tests on both sides that assert the literal
  300-second floor independent of the registry.
- Corrupt poll-state detection with recovery guidance in `status` and
  `doctor`.

### Changed

- The Apple scheduler now reserves an expiring lease under a cross-process file lock before network I/O.
- Scheduler result recording and release clear only the caller's lease.
- CLI requests use a 15-second per-attempt timeout and isolate provider failures.
- CLI discovery, live checks, and verification run providers concurrently while
  preserving registry order in output.
- Link payloads are bounded to 64 chunks and 32 accounts, with field-size and
  control-character validation in both implementations.
- Provider IDs in the CLI come from the registry rather than a closed two-provider union.
- New accounts without a provider account ID use a one-way credential fingerprint in the account key instead of `provider:default`.
- Link payloads more than 60 seconds in the future are rejected.
- `vigil-link --json` prints one or more protocol-sized lines instead of one
  unbounded line.
- The CLI is now described as credential-stateless, not disk-stateless.
- Credential-bearing CLI output requires `--yes` in `--json` mode or when
  stdin is not interactive; interactive runs keep the y/N prompt.
- A `vigil1:` deep link presents an explicit "Add account?" confirmation
  before any verification or persistence.
- The Apple scheduler clamps a fetch lease to at least the provider poll
  floor, so a crashed or crash-looping process cannot poll faster than
  five minutes.
- The lock-screen circular widget carries the same staleness and failure
  degradation signals as the home-screen widget.
- QR vectors were regenerated to carry `src: "mint"` on the Claude
  credential; the codex vector pins decoding of legacy payloads without
  `src`.
- Release signing material moved out of the repository tree into a
  permission-hardened local directory.

### Fixed

- App and widget processes could pass independent in-memory scheduler gates before either wrote a result.
- A rotated refresh token could fail to save while the app continued as if recovery succeeded.
- A deferred relink could replace a valid credential without proving the new
  credential worked.
- Notification events were removed from durable storage before the operating
  system accepted them.
- Corrupt account indexes could be treated as an empty account list and then
  overwritten.
- Existing shared-container directories could retain broader legacy
  permissions.
- Account removal could disappear from the UI after Keychain deletion failed.
- Multiple accounts for a provider without account IDs could collide.
- A configured widget could monitor only the first linked account.
- One CLI transport failure could abort a multi-provider report.
- Ambient CLI test variables could redirect credential-bearing requests.
- Provider-controlled labels and errors could emit terminal control sequences.
- Duplicate window IDs and oversized provider counters could trap or duplicate
  work in mappers, threshold processing, and polling backoff.
- A hostile `windowSeconds` value near 2^63 in a successful provider
  response could crash the Swift mapper; both mappers now bound window
  seconds to JavaScript's safe-integer range.
- Token refresh responses with a boolean `expires_in`, control characters
  in tokens, or an invalid expiry are rejected, and an invalid expiry
  clears the replaced token's stale date instead of keeping it.

### Migration notes

#### Existing accounts

Existing account references and Keychain entries remain readable. Newly linked accounts use either the provider account ID or a credential fingerprint. A legacy `provider:default` account is not automatically renamed because moving a Keychain item must be transactional.

Re-linking a legacy account can therefore create a second visible entry. Confirm the new entry works, then remove the legacy entry. Do not remove the old entry first unless the new link has been verified.

#### Existing snapshots and ledgers

Snapshots written before scalar metrics decode with an empty `metrics` array. Existing fetch-ledger entries decode without lease fields and receive a lease on their next acquisition.

#### Existing widgets

An unconfigured widget uses the first linked account. Long-press the widget, choose **Edit Widget**, and select an account. A widget configured for a later-removed account remains empty.

#### CLI safety state

The CLI now writes non-secret poll state under:

1. `VIGIL_STATE_DIR`, when set;
2. `$XDG_CACHE_HOME/vigil-link`;
3. `~/.cache/vigil-link`.

The files contain timestamps and 429 counters, not credentials or usage values. Removing them can cause an extra provider request and should not be used to bypass rate limits.

#### Optional providers

OpenRouter and DeepSeek are excluded from default commands. Name them with `--provider` and provide their environment variable in the same process.

## Vigil app 0.9.0 (1), 2026-07-18

First TestFlight build (internal testing): onboarding, dashboard, home-screen and lock-screen widgets, threshold notifications, background refresh, and the macOS menu bar from the same codebase.

## vigil-link 0.1.1, 2026-07-18

Fixed the Claude mint flow against the live OAuth endpoints: the authorize request needs `code=true`, the PKCE verifier as `state`, and the client's full registered scope set. ADR-0005 records the findings.

## vigil-link 0.1.0, 2026-07-18

Initial npm release: Claude and Codex credential discovery, live verification, `status` and `doctor`, the browser OAuth mint flow, and the `vigil1` QR link flow.

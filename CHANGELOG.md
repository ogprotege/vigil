# Changelog

## Versioning

Anything that changes shipped behavior gets an entry here: `vigil-link` npm versions, TestFlight app builds, and protocol or registry changes that affect both. Provider-schema and local-state migration notes are recorded per release so an existing installation can be upgraded deliberately.

## 0.13.0 (9) — TestFlight internal, 2026-07-21

Phone-native reliability pass — stop depending on `npx vigil-link` for core setup, and make Limits / Models actually fill after adding keys:

- **Failed link verify no longer burns the 5-minute poll floor.** A wrong API key or flaky network used to charge the scheduler, so the next attempt hit "polling safety cooldown deferred" / "Network problem" and left Limits + Models empty. Verify now releases the lease on auth/network/schema failures and only charges the clock on a real provider answer (ok) or 429.
- **Auth errors no longer say "Re-run npx vigil-link".** Phone paste / Sign in paths tell you to check the key or sign in again. `vigil-link` stays optional for computer QR handoff only.
- **Models tab fills for coding plans.** Accounts with only primary session/weekly windows (Kimi K3, Z.ai, …) now appear in Models; empty state explains balance-only providers (OpenRouter, DeepSeek) belong on Limits.
- **Limits screen shows every provider window** (session, weekly, and model caps) in one stacked list, plus a Models-at-a-glance strip under the Watchline. Color scheme unchanged.
- **Cancel on verify / Claude exchange overlays** so a hung 15s timeout is not a dead end.
- Manual-entry hints for Claude / OpenRouter / DeepSeek no longer point at the CLI.
- **Local-first setup (token-monitor style).** Mac can **Import from this Mac** — reads `~/.claude/.credentials.json` and `~/.codex/auth.json` with no browser OAuth and no npm. Add Account now leads with paste/import; Sign in with Claude/Codex is demoted to optional "mint a renewing token." New `LocalCredentialDiscovery` in VigilKit mirrors the CLI discovery parsers.
- **Home redesigned like token-monitor Limits.** Day / Week / Month / Year / Lifetime period picker, hero summary, LIMITS section with a one-tap refresh button (same feel as token-monitor's circular refresh), and compact per-provider cards with dual Session/Weekly bars + "Updated Xm ago". Absolute token totals from local transcripts aren't available on iPhone — spend/balance history is recorded on-device for period heroes when providers report those metrics.

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

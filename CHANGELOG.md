# Changelog

## Versioning

Anything that changes shipped behavior gets an entry here: `vigil-link` npm versions, TestFlight app builds, and protocol or registry changes that affect both. Provider-schema and local-state migration notes are recorded per release so an existing installation can be upgraded deliberately.

## Unreleased

- Nothing yet.

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

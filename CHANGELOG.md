# Changelog

## Unreleased

This remediation changes reliability behavior and expands the provider model. Existing users should read the migration notes before testing.

### Added

- Opt-in OpenRouter support through `OPENROUTER_API_KEY`.
- Opt-in DeepSeek support through `DEEPSEEK_API_KEY`.
- Scalar `balance`, `spend`, `limit`, and `remaining` metrics alongside reset-based percentage windows.
- Per-widget account selection through WidgetKit App Intents.
- Visible app alerts for credential, account-index, snapshot, and polling-ledger persistence failures.
- A CLI poll safety cache containing timestamps and 429 counters only.
- A shared Keychain access group with verified legacy-item migration for the
  app and widget.
- Provider contribution, troubleshooting, and threat-model documentation.

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

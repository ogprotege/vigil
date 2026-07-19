# Troubleshooting

Start with:

```sh
npx vigil-link doctor
npx vigil-link doctor --live
```

Use `--provider <id>` to isolate one provider. Live checks consume a poll slot.

## Credentials are not found

### Claude

1. Confirm Claude Code is signed in.
2. Check `~/.claude/.credentials.json`.
3. On macOS, the CLI also checks the `Claude Code-credentials` generic-password item.
4. Prefer `npx vigil-link --mint --provider claude` so Vigil owns its refresh token.
5. Use `--copy` only as a fallback.

### ChatGPT / Codex

1. Confirm the Codex CLI is signed in.
2. Check `${CODEX_HOME:-~/.codex}/auth.json`.
3. Vigil needs both `tokens.access_token` and `tokens.account_id`.
4. If the token is expired, run Codex, let it refresh, then re-link.

### OpenRouter

```sh
OPENROUTER_API_KEY='...' npx vigil-link doctor --provider openrouter
```

The variable must be set in the same process environment as `vigil-link`. OpenRouter is opt-in and is not selected by a plain `npx vigil-link`.

### DeepSeek

```sh
DEEPSEEK_API_KEY='...' npx vigil-link doctor --provider deepseek
```

DeepSeek is opt-in and is not selected by a plain `npx vigil-link`.

## A live check is deferred

The CLI reserves a provider-level poll slot before the request. It stores timestamps and a 429 counter, never credentials or usage values.

State location priority:

1. `VIGIL_STATE_DIR`
2. `$XDG_CACHE_HOME/vigil-link`
3. `~/.cache/vigil-link`

`status`, `doctor --live`, and link verification all use this gate. Re-running one command immediately after another can therefore show `deferred`. Wait until the reported time.

Deleting the state file removes the safety delay and can cause an extra provider request. Do it only to recover from a clearly invalid future timestamp, and do not use deletion to bypass normal rate limits.

## One provider says network, but others work

This is expected failure isolation. Each provider request has a 15-second per-attempt timeout and transport retries. A provider-specific DNS, TLS, timeout, or HTTP failure becomes `network` for that provider while the report continues.

Check:

- provider status pages;
- VPN, proxy, firewall, and DNS behavior;
- system clock;
- whether the credential can access the endpoint;
- `npx vigil-link doctor --provider <id> --live`.

## `authExpired`

- Claude with a Vigil-minted token: Vigil attempts one refresh. If the provider rotated the token but Keychain persistence fails, Vigil stops before retrying and asks for a re-link.
- Claude copied from another client: re-link. Vigil will not rotate another client's refresh token.
- Codex: run the Codex CLI to refresh its own sign-in, then re-link.
- API-key providers: verify that the key is active and copied completely.

## `rateLimited`

Wait for the next allowed time. Do not lower the provider's `minSeconds`.

Apple surfaces share an account-level ledger in the App Group container. Reservation and lease creation happen under an OS file lock. The CLI uses its own provider-level cache and does not share Apple's state.

## `schemaChanged`

Vigil received a successful response but could not map a valid window or metric. This usually means the provider changed its response.

1. Update Vigil and `vigil-link`.
2. Re-run the provider-specific live check.
3. Capture a sanitized response shape if you are developing a fix.
4. Update the registry, both mappings, fixtures, Swift parity constants, UI, and docs as needed.

Never post the raw response until tokens, account IDs, emails, request IDs, and distinctive billing data have been removed.

## The app says it could not save data

Do not dismiss repeated storage failures as a network problem.

- **Rotated credentials:** re-link before the next refresh. The previous refresh token may no longer be valid.
- **Snapshot:** the visible update may not survive an app restart.
- **Polling ledger:** Vigil fails closed and does not start a new request without a durable reservation.
- **Account index:** the app either rolls back the link or leaves the incomplete removal visible.
- **Keychain deletion:** the account remains linked because Vigil could not confirm credential deletion.

Check available device storage, reboot once, and retry. If the error persists, collect sanitized Console logs for subsystem `app.vigil`.

## The widget shows the wrong or no account

1. Long-press the widget.
2. Choose **Edit Widget**.
3. Select the intended Vigil account.

An unconfigured widget defaults to the first linked account. A widget configured for a removed account stays empty instead of silently switching to another account.

The widget fetches only when its snapshot is older than 30 minutes and the shared ledger permits it. WidgetKit decides when timelines run, so updates are not exact-time guarantees.

Window widgets need a percentage window such as `session`. Providers that expose only scalar spend or balance data may have no meaningful circular gauge.

## App and widget both fetched in a local build

Signed app and widget targets share `group.app.vigil.shared`. Unsigned previews or local builds can fall back to Application Support when the App Group container is unavailable. That fallback is per process, so it cannot provide cross-process locking.

Validate the App Group entitlements and test a properly signed build before treating this as a production scheduler failure.

## A link code is rejected

Vigil rejects:

- malformed or mixed-session chunks;
- payloads older than 10 minutes;
- payloads more than 60 seconds in the future;
- unsupported provider IDs;
- invalid compressed or JSON content.

Check both devices' clocks and create a fresh code. Do not keep or reuse old credential QR screenshots.

## Build and CI mismatches

Current CI:

- builds and tests the Node CLI;
- runs VigilKit tests;
- generates the Xcode project;
- builds the iOS Simulator app;
- runs the app reliability test target against macOS.

CI cannot prove device-only Keychain entitlements, camera scanning, background refresh timing, notification delivery, or real WidgetKit scheduling. Run the on-device checklist before release work.

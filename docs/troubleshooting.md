# Troubleshooting

Start by confirming that you installed the newest TestFlight build. Then open **Accounts**, select the affected account, and note its status and last-update time.

If you are setting up Vigil for the first time, read [Getting started](getting-started.md).

## Claude sign-in does not finish

- Complete the browser approval and copy the full code Claude displays.
- Return to the same pending sign-in screen before submitting the code.
- Do not reuse an earlier code. The PKCE verifier belongs to the sign-in attempt that created it.
- If the browser shows an authorization error, cancel the attempt and begin again from Vigil.
- If the account later says **Re-link needed**, open that account and use **Re-link**. Vigil keeps its existing local identity and history.

Vigil refreshes only Claude credentials it minted. A manually pasted Claude token is not auto-refreshed.

## Codex sign-in does not finish

- Confirm the short code exactly matches the one Vigil displays.
- OpenAI may require device-code authorization under ChatGPT **Settings → Security**.
- Keep Vigil available while approval completes. The app respects the server's polling interval.
- If the code expires, cancel and start a new sign-in.
- If the account later says **Re-link needed**, open that account and use **Re-link**.

## Claude says Live but shows no limits

Update to the newest build. Claude reset timestamps can contain fractional seconds, and older builds discarded those windows even when another metric survived.

Current builds also enforce required outputs. A successful response with missing required windows becomes **Provider changed**, not Live.

## Account detail shows no model-specific cap

Account detail labels a lane as a model cap only when the provider contract identifies model scope. Ordinary session, weekly, modality, and generic feature limits remain current or special limits.

Some providers do not expose model-specific limits. Their absence is correct and does not hide plan-wide limits.

## A card shows Cooling down, Stale, Re-link needed, Provider changed, or Offline

- **Cooling down:** the provider returned HTTP 429. Vigil backs off and retries after the allowed time.
- **Stale:** a new accepted snapshot did not arrive. Vigil keeps the last-known values and labels their age.
- **Re-link needed:** the provider rejected the credential. Sign in again or replace the pasted credential.
- **Provider changed:** the response failed parsing or the provider's required-output contract. Update Vigil before attempting repeated refreshes.
- **Offline:** a network, transport, or other provider HTTP failure prevented an accepted response.

## A manual provider credential is rejected

Check these provider-specific requirements:

- **OpenAI API:** use a dedicated API-platform organization Admin API key only after accepting its broad organization-owner access. Vigil sends Usage and Costs GET requests, but the credential itself is not read-only. Revoke it when you disconnect permanently. A project key such as `sk-proj-...` cannot access the organization endpoints.
- **GitHub Copilot:** provide both a fine-grained token with Account Plan read permission and the username. Organization-managed seats can return an empty per-user result.
- **Moonshot and MiniMax:** global and China hosts use separate key namespaces. Choose the matching provider.
- **xAI:** provide a Management Key and team ID, not a model-inference key.
- **Cursor:** paste the `WorkosCursorSessionToken` cookie. Browser sessions expire.
- **Kimi K3:** use the coding-plan key from `kimi.com/code/console`, not a Moonshot open-platform balance key.

Copy the credential again without leading or trailing spaces. Revoke and replace any credential that appeared in a screenshot, log, issue, or shared clipboard history.

## Refresh is deferred

Every current provider has a 300-second poll floor. The app and widgets reserve an account-level lease in shared storage before a request.

A deferred refresh protects the account from rapid polling. Wait until the displayed next-safe time. Do not delete local data or reinstall the app to bypass a normal delay.

The 300-second floor is not a promise that iOS will collect a reading every five minutes. Foreground, background, and widget checks all obey the same floor, while iOS decides when background work actually runs.

## The app stays in Cooling down

Some providers return HTTP 429 without a `Retry-After` header. Vigil applies its configured exponential backoff and preserves the last accepted snapshot.

Repeated manual refreshes do not bypass the backoff. Wait for the displayed time. If the state persists far beyond that time, check the provider's status page and network conditions.

## Provider changed

Vigil received a successful response, but parsing failed or the accepted result did not satisfy that provider's contract. Examples include:

- a missing required window or metric;
- an unknown array identity in an exhaustive collection;
- malformed percentage, reset, currency, or denomination metadata;
- a partial correlated field family;
- an eligible model entry whose nested windows no longer map.

The app preserves the last successful snapshot. It does not present partial new output as Live.

If you are developing a fix:

1. Capture the response only from an account you control.
2. Sanitize tokens, account IDs, emails, request IDs, and distinctive billing values.
3. Update `protocol/providers.json`, Swift `ProviderRegistry`, fixtures, expected output, provenance, UI behavior, and documentation as required.
4. Run the full gate in [Provider contribution guide](provider-contribution.md).

Do not post a raw response.

## Provider-specific schema notes

- **MiniMax:** 2xx error-envelope codes 1004, 1011, and 1024 become authentication failures. Confirm you selected the correct regional provider.
- **Z.ai, Cursor, MiniMax, MiniMax China, and Kimi K3:** these integrations are experimental. Their undocumented or community-researched endpoints can drift without notice.
- **GitHub Copilot:** an organization-managed seat can legitimately produce an empty personal billing result.
- **OpenAI API:** Vigil requires `has_more == false` because it does not report a partial monthly page as a total.
- **Cursor:** an expired session cookie becomes Re-link needed.

## The app says it could not save data

Storage failures are separate from provider-network failures:

- A rotated credential that could not be persisted requires a re-link.
- A snapshot write failure means the visible update may not survive restart.
- A ledger write failure blocks a new provider request.
- An account-index failure rolls back or exposes the incomplete operation.
- A Keychain deletion failure leaves the account linked and visible.

Check free device storage, restart once, and try again. If the error persists, collect sanitized Console logs for subsystem `app.vigil`.

If Vigil reports that its account index, Keychain payload, or lifecycle registry cannot be recovered, ordinary linking and removal stay blocked. Open **Settings** and use **Erase Vigil data and start over** only if you accept permanent deletion of every local Vigil credential, account, snapshot, history record, notification, and polling record. The action does not delete provider accounts. A failed reset remains blocked and can be retried; it never reactivates a partially erased account.

## History has gaps or fewer rows than expected

**Observed by Vigil** contains only successful readings that this installation retained. It cannot fill activity between provider checks, and iOS does not guarantee a background schedule. A quota percentage also cannot be converted into complete token history.

The SQLite archive keeps rows for up to 400 days. Each account has independent caps of 120,000 observed readings and 5,000 provider-backfill records. **Load more** uses a stable cursor. If one page fails, retry it without removing the account.

The OpenAI administrative import is separate. It requests up to 365 days of API organization completion usage and costs. It does not import ChatGPT or Codex subscription activity.

## A diagnostic export has fewer rows than the archive

This is expected. The diagnostic report intentionally exports a bounded recent selection per account and source. Inspect `historyScope.retainedSampleCount` and `historyScope.exportedSampleCount` to see the difference. The report is not a full history backup.

## Vigil says it preserved an account repair backup

Vigil keeps the damaged account-index copy after rebuilding the visible account list. Confirm the recovered accounts first. Then use **Settings → Delete account repair backup** to remove only that preserved copy. This action does not remove linked accounts, credentials, snapshots, or usage history, and it is separate from the full local reset used when identity data cannot be recovered.

## App lock or app-switcher privacy needs attention

Enable **Require Face ID or Touch ID** in Vigil Settings and confirm the iPhone has device-owner authentication configured. iOS can use the device passcode when biometrics do not complete. Vigil stores no biometric data.

Moving Vigil into the app switcher should replace account content with an opaque cover. A configured widget is a separate surface and remains visible according to its own placement and iOS settings.

## Account removal did not finish

Vigil keeps an account visible when a required deletion fails, even if its credential was already removed. Retry **Remove account** after checking free storage. Successful removal clears snapshots, SQLite and legacy history, event and lock metadata, pending and delivered notifications, poll state, and damaged account-index backups.

If unreadable history blocks removal, Vigil offers a separate destructive recovery action. That action deletes all local Vigil history for every account, then retries removal. Read the confirmation carefully because the history cannot be reconstructed unless a provider exposes an official administrative history API.

## Shared storage is unavailable

The app and widgets normally share `group.app.vigil.shared`. If that App Group container cannot be resolved, the app uses app-private storage and shows a warning. The app and widget then cannot share one polling ledger.

On an installed build, this usually means a signing or entitlement problem. Reinstall the current TestFlight build. Developers should verify both target entitlements with a signed device build.

## The widget shows the wrong or no account

1. Long-press the widget.
2. Choose **Edit Widget**.
3. Select the intended Vigil account.

An unconfigured widget uses the first linked account. A widget configured for a removed account stays empty.

The widget fetches only when its snapshot is old enough and the shared ledger permits it. WidgetKit controls timeline scheduling, so exact refresh times are not guaranteed.

Providers that expose only balances or spend may have no percentage window for a circular gauge.

## App and widget both fetched in a development build

Signed targets share the App Group ledger. Unsigned previews and some local builds can fall back to process-private Application Support, which cannot provide cross-process locking.

Validate App Group entitlements in a signed build before treating this as a production scheduler defect.

## Notifications did not arrive

- Enable notifications in iOS Settings.
- Confirm the account has a percentage window. Balance-only providers do not cross utilization thresholds.
- Threshold notifications fire on observed crossings, not inferred activity between provider polls.
- Background execution is opportunistic. iOS decides when the app may refresh.

## Build and CI mismatches

Current CI:

- runs VigilKit tests;
- generates the Xcode project;
- builds the iOS Simulator app;
- runs the iOS app test target;
- validates property lists and entitlements;
- rejects tracked signing secrets.

CI cannot prove device-only Keychain behavior, background scheduling, notification delivery, or real WidgetKit timing. Complete the on-device release walk before shipping.

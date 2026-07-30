# Troubleshooting Vigil

Start with the status shown beside the account. Vigil keeps failed, deferred, and stale checks visible so an old value does not look current.

> Last reviewed: 2026-07-30
>
> Review again: when an error state or recovery flow changes

## Common states

| What you see | What it means | What to do |
|---|---|---|
| **Waiting for the first check** | The account was saved without an accepted reading, or its first check has not completed. | Connect to the network and refresh after the displayed provider cooldown. |
| **Providers were checked recently** | The shared polling gate deferred a request. | Wait or pull to refresh — a manual pull fetches on demand but never interrupts an in-flight check or a rate-limit cooldown. Widget reloads cannot bypass the gate. |
| **Cooling down** | The provider rate-limited the request. | Keep the last accepted value in context and wait. The delay can be longer than five minutes. |
| **Offline** | Vigil could not reach the provider. | Check connectivity, VPN, DNS, and provider availability, then refresh when allowed. |
| **Re-link needed** | The provider rejected or expired the credential. | Open the account and use **Re-link**. Revoke an old copied key at the provider if needed. |
| **Provider changed** | The endpoint responded, but required fields no longer mapped safely. | Update Vigil if a newer build exists, and see [When a provider changes](provider-changes.md) to recover and report it. Do not treat retained values as live. |
| **Stale** | The last accepted reading is over 30 minutes old. | Check the last-checked and next-allowed times. Open the app and refresh when allowed. |
| **Awaiting update** | A provider reset passed, so Vigil hid the old quota. | Wait for a successful provider check. Vigil will not assume the new usage is zero. |
| **Provider reports no finite quota** | The provider authenticated but returned no reset quota. | Open account detail for balances, spend, or other metrics. |

## Claude sign-in does not finish

- Copy the complete code Claude displays, including any state portion.
- If Claude says the code expired or Vigil says it does not look right, reopen Claude sign-in and use a new code.
- Finish the exchange before closing the Vigil setup screen.

The shipped setup flow does not provide a manual Claude token fallback.

## ChatGPT/Codex rejects the device code

In ChatGPT, open **Settings → Security** and enable **Device code authorization**. Then return to Vigil and choose **Try again** to obtain a new code.

The shipped setup flow does not provide manual Codex token and account-ID entry.

## “Save anyway” appeared

Vigil could not verify the account: a network failure, its shared provider cooldown, or a provider response this version of Vigil cannot read (**Provider changed** — see [When a provider changes](provider-changes.md)). **Save anyway** stores the credential without claiming it is valid. The account remains in **Waiting** or another degraded state until a later provider check succeeds.

If the provider explicitly rejected a credential, correct it or sign in again. Save anyway never appears for that rejection and is not a bypass of it.

## No Perplexity option appears

This is expected. Perplexity usage credits are not supported in the current provider registry. Vigil cannot read them from the Perplexity iPhone app's cache or login session.

## A subscription shows a percentage but no token limit

The provider returned utilization without a fixed amount denominator. A plan such as Plus, Pro, or Max can affect the percentage, but the plan name alone does not prove an exact token or message ceiling. Vigil therefore shows the percentage and reset time without inventing a total.

## History has gaps or starts recently

Observed history begins after Vigil records successful checks. iOS schedules background work and widgets opportunistically. Network failures, polling floors, rate limits, authentication failures, and provider changes also create gaps.

Vigil cannot reconstruct older Claude or ChatGPT/Codex subscription activity from another app's cache.

## OpenAI official import fails

Check all of these conditions:

- The linked provider is **OpenAI API**, not **ChatGPT / Codex**.
- The credential is an organization Admin API key, not a regular project key.
- The key still has access to the organization Usage and Costs APIs.
- The request can reach `api.openai.com`.

The import covers API organization completion usage and costs only. It does not import ChatGPT or Codex subscription activity.

## A widget is empty or old

- Open Vigil once after installation or update.
- Edit the widget and select a currently linked account.
- If its configured account was removed, select another account manually.
- Check the account's last accepted reading in Vigil.
- Remember that WidgetKit controls refresh timing.

The app lock does not hide widgets. Remove a widget if its contents are too sensitive for the Home or Lock Screen.

## Notifications reveal too much

Vigil notifications can include a provider name, quota window, and utilization. In iOS **Settings → Notifications → Vigil**, disable alerts or set previews to a more private option.

Deleting a notification does not change the quota. Removing an account removes Vigil's queued and delivered threshold notifications for that account.

## Removal says all history must be deleted

The account credential is already unavailable or scheduled for cleanup, but damage in the shared history archive prevented safe account-only deletion. Vigil offers a broader recovery action that deletes observed and imported history for every linked account.

Cancel if you need to preserve the remaining archive. Approve only if finishing removal is more important than keeping all local history.

## Vigil reports an App Group storage problem

The signed app could not open the shared container used by the app and widget. Reinstalling the same current build can repair an entitlement or installation problem. Until the issue is resolved, app and widget polling may not share one cooldown.

Do not dismiss repeated storage errors as cosmetic. Export a diagnostic report if available before reinstalling, then remember that the export is only a bounded support artifact, not a full history backup.

## Data remains after account removal or recovery reset

Account removal and reset affect Vigil's current local stores. They cannot erase:

- provider-side accounts, credentials, or logs;
- Apple-managed backups that already exist;
- files already exported to Files or another app; or
- data displayed by a widget snapshot until iOS refreshes that system surface.

Revoke provider credentials at the provider and delete prior exports separately when needed.

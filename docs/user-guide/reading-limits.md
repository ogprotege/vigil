# Read limits correctly

Vigil presents provider data without turning estimates or labels into invented precision.

> Last reviewed: 2026-07-30
>
> Review again: when ranking, freshness, or presentation changes

## Home shows what needs attention

The **Limits** screen is urgency-ranked, not alphabetical.

It puts credentials that need repair and provider-response changes first. Current finite quotas follow, with the least remaining quota ranked highest within that group. Stale, offline, cooling-down, and reset-pending accounts follow. Healthy balance-only accounts can appear later because they do not have a finite quota to compare.

Each card shows one decisive value. Open the card to see every accepted window and metric for that account.

## Percentage is not an exact token count

Providers return different levels of detail:

- A utilization percentage supports **percent left**.
- Used and limit amounts support an exact ratio.
- A remaining amount is shown when the provider supplies it.
- A balance or spend value is an account metric, not a reset quota.
- A plan name identifies an allowance tier but does not define a fixed token or message ceiling.

Claude and ChatGPT/Codex subscription capacity can depend on model, context, workload, and provider policy. Vigil does not calculate a token limit from **Pro**, **Max**, **Plus**, or another tier name. The provider's own utilization percentage already reflects the account context it chose to apply.

If a provider's percentage and amount fields describe different allowance bases, account detail preserves both and explains the mismatch.

## Reset times are provider boundaries

Vigil displays the reset timestamp returned by the provider. A countdown runs locally between checks. It does not mean Vigil contacted the provider again.

When a reset time passes, the old value is no longer current. Vigil does not assume the new usage is zero. It hides the expired quota and shows **Awaiting update** until a provider check confirms the new value. Other unexpired limits and metrics remain visible.

History keeps the earlier observation in its original reset segment. A new reset timestamp starts a new observed segment.

## Freshness and status labels

| Label | Meaning |
|---|---|
| **Live** | The latest accepted response satisfied the provider contract and is not over 30 minutes old. |
| **Stale** | The last accepted response is more than 30 minutes old. |
| **Awaiting update** | A reported reset passed and the new value has not been confirmed. |
| **Cooling down** | The provider rate-limited a request. |
| **Re-link needed** | The provider rejected the saved credential. |
| **Provider changed** | The response succeeded, but required usage fields no longer mapped safely. |
| **Offline** | The provider could not be reached. |
| **Waiting** | The account has no accepted provider reading yet. |

For failed checks, Vigil can retain the last accepted windows and metrics. The degraded label and the age of the retained data — "Provider changed, data from 2 hours ago" — are part of the value. Do not read a retained value as current. See [When a provider changes](provider-changes.md) for the recovery and reporting path.

## Refresh timing

Pull-to-refresh, the toolbar refresh button, foreground checks, background tasks, and widgets all use the same account-level polling gate.

The automatic polling floor is one minute plus jitter for every provider. A manual pull-to-refresh fetches on demand — it skips the floor but never interrupts an in-flight check or a rate-limit backoff. Provider rate limits can require a longer wait. iOS can delay background tasks and widget updates, so Vigil does not promise fixed sampling intervals.

## Account detail

Open an account to inspect:

- every current reset window;
- model-specific or special limits the provider identifies;
- used, limit, and remaining amounts when available;
- balances, spend, and other provider metrics;
- plan context;
- the time of the last accepted reading and the next allowed check;
- observed and imported history; and
- a credential-free account diagnostic export.

A provider that returns only a balance can still be connected. Its card presents that value instead of pretending it has a reset quota.

# Vigil product contract

Vigil shows which linked AI limit needs attention next. Every feature must support that job without overstating what the app knows.

> Status: current contract
>
> Last reviewed: 2026-07-26
>
> Review again: for every behavior or provider-contract change

## Primary experience

1. First launch offers Claude, ChatGPT/Codex, and Other provider.
2. Home ranks linked accounts by required action and remaining quota.
3. Each Home card shows one decisive provider value with freshness and reset context.
4. Account detail shows every accepted window, metric, model-specific cap, and retained history item for that account.
5. Accounts and Settings contain setup, removal, security, and diagnostics controls.

Home is an attention list. It is not a calendar report, provider directory, or complete analytics dashboard.

## Truth rules

Vigil must preserve the distinction between these data types:

| Data | What Vigil may say |
|---|---|
| Provider utilization | Show percent used or percent left, with the provider's reset time when present. |
| Exact quota amounts | Show used, limit, and remaining only when the provider returns the required values. |
| Plan or subscription tier | Show the tier as context. Never derive a fixed token or message ceiling from its name alone. |
| Balance or spend | Show the provider value and unit when the provider returns them. Do not relabel it as token usage. |
| Local observation | Label it **Observed by Vigil** and preserve its fetch time. |
| Official historical bucket | Label it **Imported from provider** and preserve both the provider period and retrieval time. |
| Failed or stale fetch | Retain the last accepted value only with a visible degraded state. |
| Passed reset | Hide the pre-reset quota until the provider confirms a new value. Never rewrite it to zero. |

If a provider returns percentage and amount fields that use different allowance bases, Vigil may show both with an explanation. It must not force them into one calculation.

## Provider boundary

Vigil talks directly to a provider endpoint only after the user activates that provider. It does not read another app's sandbox, browser cookies, cache, database, or login session.

The current interface provides guided sign-in and guided re-linking for Claude and ChatGPT/Codex. It does not offer manual Claude or Codex token entry.

Perplexity is not supported in the current registry. **Other provider** means another listed provider, not an arbitrary API endpoint.

Experimental providers must remain labeled. A fixture proves that Vigil can map a captured shape. It does not prove that an undocumented endpoint is still available.

## History boundary

Observed history starts after a successful Vigil check. It is not a reconstruction of earlier subscription activity. Gaps are expected when iOS does not run background work or a provider check does not succeed.

The current official history import is limited to an OpenAI API organization account. It requests documented completion-usage and cost buckets with an organization Admin API key. It does not include ChatGPT or Codex subscription activity, and regular project API keys do not have the required access.

Provider costs stay separate from token quantities. Imported provider buckets stay separate from device observations.

## Scheduling boundary

Manual refresh, foreground refresh, background work, and widgets share one provider polling gate: a one-minute provider floor plus jitter as a minimum delay, not a sampling promise. Rate limits can extend it. A manual pull-to-refresh fetches on demand — it skips the floor but never an in-flight fetch or a rate-limit backoff. iOS decides when background tasks and widgets run.

Countdowns may advance locally without a network request. A moving countdown is not proof of fresh provider data.

## Privacy boundary

Vigil has no user account, collection server, analytics, advertising, crash-reporting service, or cloud synchronization service.

Credentials remain in a device-bound Keychain access group shared by the app and widget. Normalized account references, snapshots, history, pending threshold events, and polling metadata remain in the App Group container. These local records can reveal provider relationships, usage, balances, spend, and timing even though they do not contain bearer credentials.

The app lock protects the app surface and app-switcher snapshot. It does not hide a configured widget or a local notification preview.

## Deletion boundary

Removing an account must delete its credential and account-scoped local state, including observed and imported history, snapshots, polling records, and Vigil notifications. If a damaged shared history database prevents safe account-scoped deletion, Vigil must ask before deleting all local history.

The full recovery reset is shown only when Vigil cannot safely reconcile its local identity stores. It removes recoverable Vigil credentials and local state from the iPhone. Neither removal path deletes the user's provider account, provider-side records, Apple-managed backups, or diagnostic files already exported outside Vigil.

## Acceptance test for a claim

Before adding a user-facing claim, answer all four questions:

1. Which provider or local source supplies the value?
2. Does the source return an exact amount, a percentage, or only a label?
3. What timestamp proves its freshness or period?
4. What limitation must remain visible?

If any answer is unknown, the interface must state the uncertainty or omit the claim.

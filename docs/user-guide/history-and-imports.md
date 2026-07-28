# History and provider imports

Vigil keeps two kinds of history. Their source labels are not interchangeable.

> Last reviewed: 2026-07-26
>
> Review again: when storage retention or an import changes

## Observed by Vigil

**Observed by Vigil** contains successful provider readings retained after an account was connected.

Each retained reading records its fetch time and the normalized values the provider returned, including available utilization, used, limit, remaining, balance, spend, status, and reset time. Distinct successful fetch times remain distinct observations even if the value did not change.

Vigil groups quota observations by the provider's reset timestamp. A changed reset timestamp starts a new segment. The app does not convert a reset into assumed zero usage.

Observed history is not complete provider history. It can contain gaps because:

- iOS did not run a background task or widget;
- the shared polling floor deferred a request;
- the phone was offline;
- the provider rate-limited or rejected the request; or
- the provider response could not be accepted safely.

The normal one-minute polling floor is not a promise of one-minute history.

## Imported from provider

**Imported from provider** contains historical buckets returned by a supported official administrative API.

The current import is available only on an **OpenAI API** account linked with an organization Admin API key. From account detail, choose **Import official records** or **Refresh official records**.

OpenAI documents these organization records in its [Usage API reference](https://platform.openai.com/docs/api-reference/usage). Vigil requests only the completion-usage and cost resources described below.

Vigil requests up to 365 days of:

- OpenAI API organization completion usage, grouped by model; and
- OpenAI API organization cost buckets, grouped by line item.

Each completion record stores input, output, cached-input, input-audio, output-audio, and request-count quantities. Vigil normalizes omitted optional cached-input or audio counters to zero. Cost records remain separate from token quantities.

This import does not contain ChatGPT or Codex subscription activity. ChatGPT/Codex sign-in cannot authorize it. A regular OpenAI project API key cannot authorize it either.

## Retention

The current local archive keeps eligible rows for up to 400 days. Each account has separate limits of:

- 120,000 observed readings; and
- 5,000 provider-imported records.

An import cannot consume the capacity reserved for observations. One account cannot consume another account's per-account capacity.

Account detail loads a recent preview. Choose **View all records**, then **Load more**, to read the retained archive in pages.

**Up to 400 days** is a retention ceiling, not a promise that every interval exists. Capacity pruning, removal, recovery reset, storage failure, provider availability, and iOS scheduling can reduce what remains.

## What cannot be reconstructed

Vigil cannot read another iPhone app's cache, protected database, cookies, or login state. iOS app sandboxing prevents that access, and Vigil does not attempt it.

Unless a provider offers a supported history API, Vigil cannot recover activity from before the account was connected. Current Claude and ChatGPT/Codex subscription integrations return present provider quota state, not a complete historical token ledger.

Subscription tiers can affect the utilization reported by a provider. A tier name still does not reveal a fixed token denominator. History therefore preserves the values actually returned instead of estimating a token count from the subscription.

## Diagnostics are not a history backup

Diagnostic exports contain a bounded recent subset of observations and imports, plus current normalized state. They report both the retained and exported sample counts. They are intended for support, not complete archive backup or later re-import.

Vigil does not currently import its own diagnostic files.

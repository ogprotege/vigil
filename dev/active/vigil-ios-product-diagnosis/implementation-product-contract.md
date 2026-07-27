# Vigil implementation product contract

Last updated: 2026-07-26

## One recurring job

Vigil shows which linked AI limit needs attention next. It is an iPhone quota and balance instrument, not a claim that iOS can reconstruct desktop transcripts or another app's private logs.

## Source-of-truth rules

| Data shown | Required source | Required label |
|---|---|---|
| Current quota | Accepted provider window | Provider window name, percent left, reset time, and freshness |
| Current balance or spend | Accepted provider metric | Provider label, amount, unit, and freshness |
| Device history | Successful snapshots archived by Vigil | `Observed by Vigil`, with first observation and gaps disclosed |
| Provider backfill | Official documented administrative API | `Imported from provider`, with bucket range and retrieval date |
| Token history | Provider token-usage report or paired desktop collector | Never inferred from quota percentages |
| Unavailable history | No source | Explain that history begins after linking. Do not fabricate a graph. |

Private subscription endpoints may provide current quota windows. They do not become official historical APIs merely because authentication succeeds.

## First use

An accountless launch presents three actions in this order:

1. Connect Claude.
2. Connect ChatGPT / Codex.
3. Other provider.

No empty analytics, calendar selector, Models tab, provider catalog, or settings prose precedes those actions.

## Connected Home

Home ranks accounts by action required, then remaining quota, then freshness. It shows one decisive real window per account. Complete windows, balances, model caps, observed history, provider imports, and diagnostics live in account detail.

## History

Every successful fetch from the app, widget, or background task enters the protected App Group history. A provider reset starts a new segment. Distinct fetch times remain distinct even when the values form a plateau. Only an exact retry of the same logical fetch is idempotent. History remains bounded to 400 days, with independent per-account limits of 120,000 observed and 5,000 imported records.

iOS schedules background work opportunistically. History can contain gaps. The interface states that fact and never turns observed samples into a claim of complete activity.

## Export

The user can export normalized account, snapshot, and bounded recent history data as JSON from Settings or one account's detail. The export records retained and exported counts. It excludes access tokens, refresh tokens, cookies, authorization headers, raw provider bodies, Keychain attributes, credential fingerprints, and free-form labels. Export account identifiers are local aliases generated for that file.

## Acceptance gates

- Guided Claude and Codex sign-in is reachable in one tap from first launch.
- Current quotas never appear under Day, Week, Month, Year, or Life selectors.
- Every connected Home row opens complete account detail.
- A successful widget fetch appears in both current state and observed history after app activation.
- Account removal deletes credentials, current snapshots, history, observations, events, and poll state.
- OpenAI organization history can import through its official Admin APIs without being called ChatGPT history.
- Default, XXXL, and accessibility XXXL layouts retain readable actions and values.
- Diagnostic export tests prove that known secret markers never appear in output.

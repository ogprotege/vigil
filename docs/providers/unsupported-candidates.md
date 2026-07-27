# Unsupported provider candidates

- Status: Current
- Last reviewed: 2026-07-26
- Review again: whenever a provider is added to or removed from the registry

A provider is supported only when it appears in the [support matrix](support-matrix.md). A name mentioned in an issue, a public subscription limit, or a credential that works in another app does not make it a Vigil integration.

## Perplexity

Perplexity is not supported in the current app.

The repository contains no:

- `perplexity` entry in `protocol/providers.json`
- `perplexity` runtime `ProviderSpec`
- Perplexity setup row or credential guidance
- Perplexity fixture or expected normalized output
- Perplexity evidence entry in `protocol/fixture-provenance.json`
- Perplexity authentication, request, mapping, or failure-classification test

Vigil therefore cannot fetch, infer, import, or display Perplexity subscription usage or API credits. The app must not relabel another provider's generic token field as Perplexity support.

Perplexity currently documents billing and usage views for API groups and reports per-request usage and cost fields in API responses. Vigil has not implemented or evidenced an authenticated account-level credit or balance contract from those materials. This is the current integration status, not a claim that Perplexity can never expose another supported endpoint.

- [Perplexity API groups and billing](https://docs.perplexity.ai/docs/getting-started/api-groups)
- [Perplexity response usage fields](https://docs.perplexity.ai/api-reference/sonar-post)

## Why public plan limits are insufficient

A published subscription allowance can explain the context of a provider-returned percentage. It cannot prove an account's current usage, reset segment, exceptions, temporary promotions, model-specific rules, or provider-side enforcement state.

Vigil requires authenticated account data. It does not derive live usage from a plan name alone. It also cannot read another iPhone app's private container, Keychain entries, or browser session storage.

## Candidate acceptance requirements

A candidate becomes supportable only after all of these are complete:

1. Identify a provider endpoint that returns account-specific quota, balance, spend, or counted usage.
2. Record whether the contract is vendor-documented, captured and sanitized, or based on community research.
3. Confirm that authentication can be performed safely on iOS without taking credentials from another app's private storage.
4. Define honest normalized windows, metrics, or quantities. Do not create a denominator from subscription marketing.
5. Define required-output and schema-drift rules that fail closed.
6. Add the JSON registry entry and matching Swift runtime entry.
7. Add sanitized or modeled input fixtures, hand-authored expected outputs, and provenance.
8. Add mapping, request, failure, parity, presentation, and privacy tests.
9. Mark the integration Experimental when its endpoint lacks a stable vendor contract and verified production evidence.
10. Add it to the canonical support matrix only after the test suite passes.

See the [provider contribution guide](../development/provider-contribution.md) for the implementation sequence.

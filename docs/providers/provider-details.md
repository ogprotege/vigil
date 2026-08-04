# Provider details

- Status: Current
- Last reviewed: 2026-07-30
- Review again: whenever provider authentication, mapping, or user-facing setup changes

The [support matrix](support-matrix.md) is the canonical provider list. This guide explains how to interpret each integration without repeating its evidence table.

## Rules shared by every provider

Vigil stores provider responses in two normalized forms:

- A **window** is a reset-based quota with percentage used. It can also contain exact used, limit, and remaining values when the provider returns them.
- A **metric** is a balance, spend, limit, or remaining value without a reset-based percentage contract.

Vigil never creates a token or message ceiling from a subscription name. A plan label identifies the tier only. If the provider returns 35 percent used but no denominator, Vigil preserves 35 percent and leaves exact amounts empty.

Every provider request is a direct device-to-provider request. The request session is ephemeral, ignores local cache data, and has no response cache or cookie store. Cursor is the exception only in credential shape: Vigil places the manually supplied session token in that provider request's `Cookie` header. It still does not use the shared iOS cookie store.

## Guided accounts

### Claude

The primary setup opens Claude authorization in the system browser. The user pastes the returned code into Vigil. Vigil exchanges it for its own refreshable credential pair.

Claude can return a five-hour session, a general weekly window, named weekly lanes, active model-scoped weekly limits, and extra-usage money values. Most Claude quota responses provide utilization and reset time rather than an absolute token allowance. The account detail screen must say so.

The current UI uses this guided flow for both first setup and re-linking. Claude is excluded from the Other Provider catalog, so there is no user-facing manual-token route.

### ChatGPT / Codex

The primary setup uses OpenAI device authorization. The user must enable device-code authorization in ChatGPT security settings. Vigil receives its own refreshable token pair and the account ID required by the usage request.

Codex can return either or both of its primary and secondary rate windows. Their duration decides whether Vigil calls them session or weekly windows. Additional entries are keyed by a provider `metered_feature` value and labeled from `limit_name` when available. These are metered-feature limits. A label that resembles a model does not make the whole collection a model-cap API.

Flex credits appear only when the provider reports a finite balance. Reset credits appear as a count of resets available. Neither metric supplies an exact denominator for a percentage-only rate window.

OpenAI can also return an optional workspace spend-control object. An inactive wrapper with an explicit Boolean `reached: false` does not invalidate otherwise complete usage data. A malformed wrapper, reached control, or concrete individual monthly limit remains unsupported until Vigil maps it, so the app reports provider drift instead of silently presenting incomplete data as live.

The current UI uses device authorization for both first setup and re-linking. ChatGPT / Codex is excluded from the Other Provider catalog, so there is no user-facing manual-token route.

ChatGPT / Codex and OpenAI API are separate Vigil providers. Their credentials, endpoints, current readings, and history have different meanings.

## Direct-credential accounts

### OpenRouter

Vigil reads key-level usage and limit data. All mapped money fields are USD dollar amounts exactly as returned. For example, a response value of `12.5` becomes `$12.50`, not `$0.125`.

The key can have no finite spending limit. In that case Vigil keeps the eight usage counters and omits the limit and remaining pair. It does not create a percentage gauge.

### DeepSeek

DeepSeek can return several balance rows. Vigil keeps one balance metric for each sanitized currency identifier. It does not collapse different currencies into one amount or convert exchange rates.

### Moonshot global and China

The two Moonshot entries use different hosts and credential namespaces. Global results are mapped as USD. China results are mapped as CNY. Each integration keeps available, cash, and voucher balance as separate metrics.

Moonshot open-platform keys are not Kimi Code plan keys. Use Kimi K3 for the coding-plan endpoint.

### MiniMax global and China

The two MiniMax entries also use different hosts and credential namespaces. The provider reports remaining percentage, so Vigil converts it to percentage used with `100 - remaining`.

General and video entries can each contain interval and weekly states. Status `3` means no finite limit in the researched contract. Vigil omits that lane instead of rendering an unlimited plan as zero percent used. A valid response can therefore contain no finite window.

### OpenAI API

This integration requires an organization Admin API key. The key has broad organization-owner authority and is not read-only. Vigil limits its own behavior to documented `GET` requests, but that does not reduce the key's provider-side authority. Use a dedicated key and revoke it when disconnecting permanently.

The normal refresh reads organization costs from the start of the current UTC month. It reports month-to-date spend only after receiving a complete, non-paginated response.

The account detail screen can request up to 365 days of official history. It reads:

- Daily completion usage grouped by model
- Daily organization costs grouped by line item

Completion rows store input, output, cached input, input audio, output audio, and model-request quantities. Cost rows remain separate money metrics. The import uses `providerBackfill` provenance. It does not reconstruct ChatGPT or Codex subscription use.

### GitHub Copilot

The request requires both a fine-grained token and the GitHub username used in the URL. Vigil requests the current calendar month and sums documented gross, discount, net quantity, and net amount fields.

The normalized result separates credits consumed, included credits, billable credits, and billable USD spend. Organization-managed seats can return no personal usage data, so an empty personal result is not a subscription limit.

### xAI API

The request requires a Management Key and team ID. The current provider contract returns a signed cent-denominated total. Vigil applies the contract's `-0.01` scale and presents the result as USD prepaid balance.

This is the xAI **API platform** prepaid balance. It is not Grok Build subscription usage. Connect Grok Build separately.

### Grok Build

Grok Build is xAI's coding agent product (the terminal agent, not the xAI API prepaid balance). Setup prefers on-device OIDC **device authorization** against `auth.x.ai` with the public Grok CLI client id. That is the same family of flow the desktop CLI uses for `grok login` / `/login`: short user code, browser approval, renewable session. Vigil completes that flow on the phone and mints its own pair; it never copies tokens from `~/.grok/auth.json`. Manual entry of a session access token remains only for recovery and does not auto-renew.

The usage request is a bearer GET to the Grok Build CLI chat-proxy billing endpoint (`cli-chat-proxy.grok.com/v1/billing`). The primary accepted shape returns monthly used and limit values under `config.*.val` wrappers plus a billing period end. When used and limit are absent, Vigil falls back to `creditUsagePercent` with the period end. On-demand used and cap appear only when both amounts are present and the cap is positive.

The endpoint is experimental and undocumented. Unexpected shapes mark the response incompatible rather than inventing limits from a SuperGrok or X Premium plan name.

### Z.ai Coding Plan

The mapper accepts either a four-hour or five-hour token session plus a weekly token window. It accepts both root-level and `data.limits` collections, and both `type` and `name` identity keys.

Web-search usage is a separate set of call metrics: used, limit, and remaining. Vigil does not treat those call counters as token usage.

The endpoint is experimental. Unexpected identities, duplicate required entries, or unrecognized token durations can make the response incompatible instead of silently dropping new data.

### Cursor

Cursor setup uses a manually copied `WorkosCursorSessionToken`. Vigil has no refresh authority for it. The user must paste a new token when the session expires.

The mapper selects one compatible plan source from individual plan, individual overall, or team pooled data. It can also show auto-selected and API-model percentages when returned. On-demand spend and limit appear together only when their fields form a compatible pair. Personal spend is not combined with an unrelated team limit.

### Kimi K3

Kimi K3 uses a Kimi Code key, not a Moonshot open-platform key. The current contract requires a 300-minute session entry and a weekly usage object. Both can contain exact used, limit, and remaining values.

The endpoint serializes protobuf-style JSON that omits zero-valued numbers, confirmed by a sanitized 2026-07-30 production capture: a session with zero usage arrives without its `used` field, and a fully used window can arrive without `remaining`. Vigil accepts the omission as exactly zero, and only when the declared limit and the other amount agree that zero is the omitted value. A present malformed amount, or an absence whose pair implies a nonzero amount, still marks the response incompatible.

The endpoint is experimental. An unexpected duration or collection identity marks the response incompatible rather than pretending that the changed data is understood.

## What a subscription tier can and cannot prove

A provider can vary an allowance by subscription. Vigil may show the returned plan label alongside the live quota. That still does not justify calculating an exact token limit from a public plan description.

An exact limit is safe to show only when the authenticated provider response returns the denominator, or when exact provider fields permit a lossless derivation. Percentage-only responses stay percentage-only.

## Related documentation

- [Provider support matrix](support-matrix.md)
- [Unsupported candidates](unsupported-candidates.md)
- [Provider contribution guide](../development/provider-contribution.md)
- [Architecture](../development/architecture.md)

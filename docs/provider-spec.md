# Provider registry and support

`protocol/providers.json` is the canonical reviewable registry for every provider Vigil polls. The iOS runtime uses a compiled Swift mirror in `ProviderRegistry`, and `SpecParityTests` keep that mirror aligned.

The registry defines request policy and response mapping. It does not eliminate provider-specific code. OAuth, device authorization, unusual authentication, request construction, and UI behavior can still require adapters.

## Support and stability matrix

| Provider | Phone activation | Normalized data | Poll floor | Refresh | Endpoint and evidence |
|---|---|---|---:|---|---|
| Claude | Sign in with Claude, or manual token | 5-hour, weekly, named/model-scoped windows; extra-usage spend and limit | 300 s | Only Vigil-minted credentials | Undocumented consumer endpoint. Live sign-in and scoped-limit response confirmed July 2026. Scoped-limit and 429 fixtures are live-sanitized; denomination handling is modeled from observed data. |
| ChatGPT / Codex | Sign in with Codex, or manual token plus account ID | Session, weekly, nested model lanes, Flex credits, reset credits | 300 s | Only Vigil-minted credentials | Undocumented consumer endpoint. Live device sign-in and response behavior confirmed July 2026. Committed bodies remain modeled from upstream Codex source. |
| OpenRouter | Paste API key | Lifetime, daily, weekly, monthly, and BYOK usage; optional key limit and remaining amount | 300 s | Not applicable | Vendor-documented key endpoint with synthetic fixtures. No Vigil production capture. |
| DeepSeek | Paste API key | Balance by returned currency | 300 s | Not applicable | Vendor-documented balance endpoint with synthetic fixtures. No Vigil production capture. |
| Moonshot (Kimi) | Paste global API key | Available, cash, and voucher balances in USD | 300 s | Not applicable | Vendor-documented balance contract with synthetic fixtures. No Vigil production capture. |
| Moonshot (Kimi) China | Paste China API key | Available, cash, and voucher balances in CNY | 300 s | Not applicable | Vendor-documented balance contract with synthetic fixtures. No Vigil production capture. |
| MiniMax Coding Plan | Paste global coding-plan key | General and video session and weekly windows | 300 s | Not applicable | **Experimental.** Undocumented token-plan endpoint, community-researched fixtures, no Vigil production capture. |
| MiniMax Coding Plan China | Paste China coding-plan key | General and video session and weekly windows | 300 s | Not applicable | **Experimental.** Undocumented token-plan endpoint, community-researched fixtures, no Vigil production capture. |
| OpenAI API | Paste dedicated organization Admin API key | Month-to-date spend; optional completion-token and cost history import | 300 s | Not applicable | Vendor-documented organization Usage and Costs APIs with synthetic fixtures. The Admin API key is a broad organization-owner credential. Vigil sends only GET requests. Regular project keys cannot access these endpoints. No Vigil production capture. |
| GitHub Copilot | Paste fine-grained token and username | Credits consumed, included and billable credits, billable spend | 300 s | Not applicable | Vendor-documented billing endpoint with synthetic fixtures. Organization-managed seats can report empty personal usage. |
| xAI API | Paste Management Key and team ID | Prepaid balance | 300 s | Not applicable | Vendor-documented management endpoint with synthetic fixtures. No Vigil production capture. |
| Z.ai Coding Plan | Paste GLM Coding Plan key | 5-hour and weekly token windows; web-search counters | 300 s | Not applicable | **Experimental.** Undocumented endpoint, community-researched fixture, no Vigil production capture. |
| Cursor | Paste `WorkosCursorSessionToken` | Plan and model lanes; billing reset; on-demand spend and limit | 300 s | None | **Experimental.** Undocumented web endpoint, community-researched fixture, no Vigil production capture. |
| Kimi K3 | Paste Kimi Code key | Session and weekly coding-plan windows | 300 s | Not applicable | **Experimental.** Undocumented coding-plan endpoint, community-researched fixture, no Vigil production capture. |

Definitions:

- **Poll floor** is `poll.minSeconds`. The app and widgets enforce it through a shared account-level ledger.
- **Supported** means Vigil intends to present the provider. It does not mean a production body was captured.
- **Experimental** means the endpoint lacks both a stable vendor contract and a sanitized Vigil production capture.
- **Fixture-covered** means CI validates deterministic mapping for a committed example. It is not a live-availability claim.
- **Undocumented** means the vendor can change or remove the endpoint without notice.

Region variants are separate providers because Moonshot and MiniMax use separate global and China credential namespaces.

## Fixture provenance

Every input and expected-output file is listed in [fixture-provenance.json](../protocol/fixture-provenance.json).

Evidence classes are narrow:

- `live_sanitized`: Vigil captured the production body and removed account-specific data before commit.
- `vendor_example`: the body came from a vendor-published example.
- `community_research`: a maintained independent client supplied response-shape evidence.
- `synthetic_derived`: the body was hand-authored from another source to test mapping or a boundary.

Expected files are hand-authored normalization oracles. They prove what the Swift mapper should produce from the input. They are not independent evidence about the provider.

Authorization success, HTTP 200, and fixture parity do not justify a `live_sanitized` label. That label requires the response body itself, sanitation, date, and durable provenance.

## Activating providers

All activation happens on the iPhone.

- Claude: **Add account → Sign in with Claude**.
- ChatGPT/Codex: **Add account → Sign in with Codex**.
- Other providers: **Add account → Paste a provider key → provider**.

Some providers require a second identifier:

- GitHub Copilot requires a username.
- xAI requires a team ID.
- Manual Codex entry requires an account ID.

Vigil stores credentials in Keychain. Manually entered credentials do not gain auto-refresh authority.

## Registry fields

A provider can use only the blocks it needs.

```jsonc
{
  "displayName": "Example",
  "experimental": true,
  "auth": "api_key_bearer",
  "usage": {
    "method": "GET",
    "url": "https://provider.example/usage",
    "headers": {
      "Authorization": "Bearer {access_token}",
      "X-Account": "{account_id}"
    }
  },
  "poll": {
    "minSeconds": 300,
    "jitterSeconds": 60,
    "backoff429BaseSeconds": 900,
    "backoffMaxSeconds": 3600
  },
  "manualEntryHint": "Where the user obtains the credential.",
  "responseFields": {
    "utilization": "used_percent",
    "resetsAt": "reset_at",
    "windowSeconds": "window_seconds"
  },
  "windows": [
    {
      "id": "session",
      "sourceKey": "rate_limit.session",
      "resetFormat": "unixSeconds",
      "secondary": false
    }
  ],
  "requiredOutputs": {
    "minimumWindows": 1,
    "minimumPrimaryWindows": 1,
    "windowIds": ["session"]
  },
  "metricMappings": [
    {
      "id": "usage",
      "label": "Credits used",
      "sourceKey": "data.usage",
      "kind": "spend",
      "unit": "USD",
      "secondary": false
    }
  ],
  "capabilities": ["rate_windows", "spend"]
}
```

Important behavior:

- `experimental` drives visible product labeling.
- `usage.url`, headers, and query fields substitute `{access_token}` and `{account_id}` at request time.
- Query values can be literals or supported UTC computations such as month start.
- `manualEntryHint` must tell the user exactly which credential and identifier the phone form expects.
- `poll` is enforced by the Apple scheduler. Do not lower it to improve apparent responsiveness.
- `windows` maps static quota buckets.
- `additionalWindows` maps dynamic arrays such as model-specific limits.
- `additionalWindows.entryWindows` can fan one dynamic entry into nested primary and secondary windows.
- `responseEnvelope` classifies provider-defined failures inside HTTP 2xx bodies.
- `requiredOutputs` defines the minimum result allowed to become Live.
- `requiredPaths`, `absentOrNullPaths`, `requiredConditions`, and `exhaustiveCollections` express structural contracts.
- `metricMappings` maps fixed scalar values.
- `metricCollectionMappings` maps arrays such as balances by currency.
- `capabilities` describes the provider. It does not create rendering behavior by itself.

## Mapping semantics

A static window reads `sourceKey` as a dot path. Ordered `sourceKeys` provide bounded compatibility fallbacks. A selector segment such as `items[kind=general]` chooses one exact array record. Multiple matching records are invalid.

A missing or null optional bucket produces no window. A present malformed bucket is omitted and marks the result incomplete. An explicit null reset remains a valid unknown reset when the contract permits it.

Reset formats are `iso8601`, `unixSeconds`, or `unixMillis`. The ISO parser accepts fractional seconds. Normalized dates use whole-second precision.

Direct percentages must be finite and fall from 0 through 100. Ratio windows require nonnegative used values and a positive limit. A legitimate over-limit ratio displays at 100 percent. Providers that report remaining percent use `utilizationKind: "remaining"`.

Field paths beginning with `$` resolve from the response root. This supports a reset timestamp shared by nested buckets.

Dynamic-window filters, conditions, labels, prefixes, reset formats, field overrides, and required-entry behavior follow the same bounded rules as static windows.

Fixed metrics accept finite JSON numbers. Exact decimal strings are accepted where declared. Missing or null optional values are omitted. A present nonnumeric value is schema drift.

Money mappings can apply a fixed `scale` or a validated provider exponent. Denomination metadata must align with every aggregated value. Vigil never guesses a currency or converts between currencies.

Aggregate paths ending in `[]` flat-map arrays. A present empty collection can honestly sum to zero. A missing root, malformed leaf, excessive collection, or unit mismatch marks the response incomplete.

Raw bodies must be strict UTF-8 JSON. Vigil rejects raw NUL, duplicate semantic object keys, leading `U+FEFF` inside strings, non-finite decoded numbers, lone surrogates, excessive depth, and oversized node counts. One document-level UTF-8 BOM is tolerated.

A successful response becomes `schemaChanged` when parsing fails or required outputs are not met. The classifier can retain partial values for diagnosis, but Apple surfaces preserve the last successful snapshot instead of labeling partial output Live.

## Claude

- Request: `GET https://api.anthropic.com/api/oauth/usage`.
- Required headers include bearer authorization, `anthropic-beta: oauth-2025-04-20`, `Accept`, and the configured Claude Code-style `User-Agent`.
- Primary buckets include `five_hour` and `seven_day`.
- Named legacy buckets and active `weekly_scoped` entries become genuine model or special lanes when their contract is met.
- Live `limits[]` entries use `scope.model.display_name`, `percent`, and fractional `resets_at` timestamps.
- The observed `spend.used` and `spend.limit` family maps minor units through each value's exponent and currency. The older `extra_usage` family remains an ordered fallback.
- A partial spend family is schema drift. Vigil never combines fields from two schema families.
- Phone sign-in uses PKCE and mints Vigil-owned credentials.
- Only minted credentials refresh automatically.
- Poll floor: 300 seconds. The endpoint can return 429 without `Retry-After`.

## ChatGPT / Codex

- Request: `GET https://chatgpt.com/backend-api/wham/usage`.
- Phone sign-in uses OpenAI device authorization.
- The account ID comes from the token claim used by Codex.
- Primary and secondary plan windows map from the rate-limit family.
- `additional_rate_limits` entries can fan into nested primary and secondary model windows.
- Dynamic IDs use `metered_feature`, labels use `limit_name`, and observed durations distinguish session and weekly lanes.
- Flex credits and reset credits map when their complete contract is present.
- Minted credentials refresh independently. Manually pasted credentials do not.
- The usage and device-authorization endpoints are undocumented consumer surfaces.

## OpenRouter

- Request: `GET https://openrouter.ai/api/v1/key`.
- Maps lifetime, daily, weekly, and monthly usage plus the same BYOK periods.
- An optional key spending limit and remaining amount maps only when the pair is coherent.
- Absent or null limit fields mean no finite key limit.

Official reference: <https://openrouter.ai/docs/api_reference/limits>

## DeepSeek

- Request: `GET https://api.deepseek.com/user/balance`.
- Maps each valid `balance_infos` entry by currency.
- Vigil does not combine or convert currencies.

Official reference: <https://api-docs.deepseek.com/api/get-user-balance/>

## Moonshot global and China

- Request: `GET /v1/users/me/balance` on the selected regional host.
- Maps available, cash, and voucher balances.
- The 2xx body must carry the expected success envelope. Explicit provider failures do not become a healthy zero.
- Region credentials are not interchangeable.
- Global values use USD. China values use CNY.

Official references: <https://platform.kimi.ai/docs/api/balance> and <https://platform.kimi.com/docs/api/balance>

## MiniMax global and China

- Request: `GET /v1/token_plan/remains` on the selected regional host.
- Maps general and video session and weekly windows.
- Root `model_remains[]` is primary. The older nested wrapper remains a compatibility fallback.
- Percentages are reported as remaining and inverted.
- Status 3 represents an unlimited lane and is omitted.
- Error-envelope codes 1004, 1011, and 1024 become authentication failures even inside HTTP 200.
- Both integrations are experimental.

## OpenAI API

- Request: `GET https://api.openai.com/v1/organization/costs`.
- Requires an API-platform organization Admin API key. It is a broad organization-owner credential, not a read-only key, and can authorize organization-management actions beyond the GET requests Vigil sends.
- Vigil sends only documented GET requests to the organization Usage and Costs APIs. Create a dedicated key for Vigil and revoke it when the integration is no longer needed. A regular project key cannot access these endpoints.
- Computes UTC month start and sums daily cost buckets.
- A present empty data array maps to honest zero.
- `has_more` must be present and false because this release does not report a partial page as the monthly total.
- Account detail can separately import up to 365 days from `GET /v1/organization/usage/completions` and `GET /v1/organization/costs`.
- Completion tokens and organization costs remain separate imported quantities. Missing or malformed cost amounts are skipped rather than invented.
- The import does not contain ChatGPT or Codex subscription activity. Those products do not share this Admin API credential or history contract.

Official reference: <https://platform.openai.com/docs/api-reference/usage/costs>

## GitHub Copilot

- Request: the documented enhanced billing usage endpoint for the supplied username and current UTC month.
- Maps gross quantity as credits consumed, discount quantity as included credits, net quantity as billable credits, and net amount as billable spend.
- Required outputs demand both consumed credits and billable spend.
- Organization-managed seats can return an empty personal result.

Official reference: <https://docs.github.com/en/rest/billing/usage?apiVersion=2026-03-10>

## xAI API

- Request: `GET https://management-api.x.ai/v1/billing/teams/{account_id}/prepaid/balance`.
- Requires a Management Key and team ID.
- The documented signed cent value is multiplied by `-0.01` to produce positive USD prepaid balance.

Official reference: <https://docs.x.ai/developers/rest-api-reference/management/billing>

## Z.ai Coding Plan

- Request: `GET https://api.z.ai/api/monitor/usage/quota/limit`.
- Token windows are selected by type, unit, and duration.
- Reset values are Unix milliseconds.
- Web-search quotas map as scalar call metrics, not token windows.
- The 2xx body must carry the expected provider success envelope.
- This integration is experimental.

Community reference: <https://github.com/robinebers/openusage/blob/9d2bf09f10e21f769494a525a9d65c84d7aeb1df/Sources/OpenUsage/Providers/ZAI/ZAIUsageMapper.swift>

## Cursor

- Request: `GET https://cursor.com/api/usage-summary`.
- Uses the `WorkosCursorSessionToken` cookie.
- The billing reset comes from root `billingCycleEnd`.
- The plan window uses ordered percentage or exact-ratio candidates.
- Optional model lanes and on-demand spend map separately.
- Monetary values are cents and scale by `0.01`.
- The session cookie expires and must be pasted again.
- This integration is experimental.

Community reference: <https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift>

## Kimi K3

- Request: `GET https://api.kimi.com/coding/v1/usages`.
- Requires the Kimi Code credential, separate from a Moonshot open-platform key.
- The 5-hour bucket is selected from `limits[]` by a 300-minute duration.
- Session values live under `detail`. Weekly values live under `usage`.
- String counts compute exact used-to-limit utilization.
- `resetTime` is ISO-8601 and can include fractional seconds.
- This integration is experimental.

Community reference: <https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/kimi.md>

## Provider candidates

Provider count is not the goal. Add a provider only when it exposes a meaningful value through a supportable authentication path.

| Candidate | Current blocker |
|---|---|
| Codex separate reset-credit endpoint | Requires multi-request provider support. The main response already maps reset credits when present. |
| GitHub Copilot percent windows | The undocumented endpoint requires new GitHub device-flow OAuth machinery. |
| Anthropic Admin API cost report | Organization-only, and the complete query contract lacks live validation. |
| Mistral Admin usage | Plausible route exists, but the response shape remains unconfirmed. |
| Fireworks billing summary | Time parameter format and exact string totals require validation. |
| Gemini CLI / Antigravity | Google-private endpoints require additional OAuth machinery with no stability promise. |
| Volcengine / Alibaba | Require request-signing implementations rather than bearer authentication. |
| Windsurf and Grok CLI | Available surfaces use protobuf or gRPC-web rather than the current JSON mapper. |
| Session-cookie and HTML-only providers | Cloudflare and markup drift conflict with Vigil's honesty requirements. |
| Together AI, Cohere, Replicate, Gemini API key | Research found no usable programmatic personal usage or billing endpoint. |

The implementation checklist is in [Provider contribution guide](provider-contribution.md).

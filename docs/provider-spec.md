# Provider registry and support

`protocol/providers.json` is the canonical machine-readable registry for every provider Vigil can poll. It defines request policy and response mapping. It does not eliminate provider-specific code. Authentication, credential discovery, OAuth minting, unusual response shapes, and UI behavior may still require adapters.

## Support and stability matrix

| Provider | Default | Credential activation | Normalized data | Poll floor | Token refresh | Endpoint status | Evidence |
|---|---:|---|---|---:|---|---|---|
| Claude | Yes | Vigil-owned OAuth mint, Claude Code file, or macOS Keychain | Session, weekly, model-scoped windows, and extra-usage spend/limit | 300 s | Yes, only for credentials Vigil minted | Undocumented consumer endpoint | Live account path confirmed July 2026. The scoped-limits and 429 fixtures are live-sanitized; extra-usage denomination is community-verified and modeled. |
| ChatGPT / Codex | Yes | On-device device-code sign-in, or Codex CLI file | Session, weekly, nested per-model lanes, Flex credits, and reset credits | 300 s | Minted tokens refresh independently; copied ones do not | Undocumented consumer endpoint | Live sign-in and current response shape confirmed July 2026. Committed fixtures are modeled from upstream Codex source, not production captures. |
| OpenRouter | No | `OPENROUTER_API_KEY`, QR/paste handoff, or app manual entry | Lifetime, daily, weekly, monthly, and BYOK usage; optional key limit/remaining | 300 s | Not applicable; API key | Documented key endpoint | Vendor-documented contract with synthetic fixtures. No Vigil production capture. |
| DeepSeek | No | `DEEPSEEK_API_KEY`, QR/paste handoff, or app manual entry | Balance by returned currency | 300 s | Not applicable; API key | Documented balance endpoint | Vendor-documented contract with synthetic fixtures. No Vigil production capture. |
| Moonshot (Kimi) | No | `MOONSHOT_API_KEY` (`MOONSHOT_CN_API_KEY` for the China provider), QR/paste, or app manual entry | Available, cash, and voucher balances (USD global, CNY China) | 300 s | Not applicable; API key | Documented balance endpoints on the global and China platforms | Vendor-documented contracts with synthetic fixtures. No Vigil production capture. |
| MiniMax Coding Plan | No | `MINIMAX_CODING_API_KEY` (`MINIMAX_CN_CODING_API_KEY` for China), QR/paste, or app manual entry | General and video session/weekly windows (inverted from remaining-percent) | 300 s | Not applicable; API key | Undocumented Token Plan endpoint used by shipping clients | **Experimental.** Community-researched fixtures. No Vigil production capture. |
| OpenAI API | No | `OPENAI_ADMIN_KEY` (read-only org Admin key), QR/paste, or app manual entry | Month-to-date spend summed over daily cost buckets | 300 s | Not applicable; API key | Documented organization costs endpoint | Vendor-documented contract with synthetic fixtures. No Vigil production capture. |
| GitHub Copilot | No | `GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER` (fine-grained PAT with Account → Plan read), QR/paste, or app manual entry | Credits consumed, billable/included credits, and billable spend for the current month | 300 s | Not applicable; PAT | Documented billing usage endpoint; org-managed seats report empty | Vendor-documented contract with synthetic fixtures. No Vigil production capture. |
| xAI API | No | `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID` (console Management Key), QR/paste, or app manual entry | Prepaid balance | 300 s | Not applicable; API key | Documented management endpoint | Vendor-documented contract with a synthetic fixture. No Vigil production capture. |
| Z.ai Coding Plan | No | `ZAI_API_KEY`, QR/paste handoff, or app manual entry | 5-hour and weekly token windows, plan label, and web-search counters | 300 s | Not applicable; API key | Undocumented; observed in independent clients | **Experimental.** Community-researched fixture. No Vigil production capture. |
| Cursor | No | `CURSOR_SESSION_TOKEN` (browser `WorkosCursorSessionToken` cookie), QR/paste, or app manual entry | Plan and model-lane windows, billing-cycle reset, on-demand spend/limit | 300 s | None; session cookie expires and must be re-pasted | Undocumented web API; individual accounts have no official endpoint | **Experimental.** Community-researched fixture. No Vigil production capture. |
| Kimi K3 (coding plan) | No | `KIMI_CODE_API_KEY` (coding-plan key, separate from the Moonshot balance key), QR/paste, or app manual entry | Session and weekly coding-plan windows | 300 s | Not applicable; API key | Undocumented coding-plan usage endpoint (`api.kimi.com/coding/v1/usages`) | **Experimental.** Community-researched fixture. No Vigil production capture. |

Definitions:

- **Poll floor** is the registry `poll.minSeconds`, enforced independently by the CLI's per-provider gate and the Apple per-account scheduler. Do not lower it.
- **Supported** describes Vigil's intended product support. It does not imply that every committed fixture came from a real account.
- **Opt-in preview** means the provider is implemented but excluded from the default command. Users must name it explicitly.
- **Fixture-covered** means CI verifies deterministic mapping for committed examples. It does not prove that a provider still returns that shape.
- **Undocumented** means the vendor may change or remove the consumer endpoint without notice.
- **Experimental** means the endpoint lacks both a stable vendor contract and a Vigil production capture (`"experimental": true` in the registry). Its mapping may be community-researched or repository-researched. The CLI, app pickers, and account surfaces label these visibly. Detected structural drift surfaces as `schemaChanged` or `authExpired`; semantic changes still require live verification.

Fixture evidence is recorded in [fixture-provenance.json](../protocol/fixture-provenance.json). The evidence levels are deliberately narrow:

- `live_sanitized` means Vigil captured the production body and removed account-specific data before commit.
- `vendor_example` means the body came from a vendor-published example. It is not a live Vigil result.
- `community_research` means a maintained independent client supplied the response-shape evidence.
- `synthetic_derived` means the body was hand-authored from another source to test mapping or a boundary case.

The paired `-expected.json` files are hand-authored normalization oracles. They prove that TypeScript and Swift implement the intended mapping. They are not independent evidence of the upstream API. A successful HTTP probe, a 200 response, or mapper parity does not justify a `live_sanitized` claim without a sanitized body and a provenance entry.

Region variants (`moonshot` / `moonshot_cn`, `minimax` / `minimax_cn`) are separate providers because the vendors run separate key namespaces. A China-platform key against the global host can return 401. MiniMax error-envelope codes 1004, 1011, and 1024 become `authExpired`, even when the server uses HTTP 200.

## Activating providers

Claude and Codex are set up **on-device in the app**: "Add account" → "Sign in with Claude" (approve in a browser, then paste the code back) or "Sign in with Codex" (the app shows a code, you approve it in a browser, and the app polls until it completes). Other providers are added under "Paste a provider key" with the requested API key, account identifier, or Cursor session credential. `npx vigil-link` is an **optional** path for reusing a Claude Code / Codex sign-in that already lives on a computer; the CLI commands below are that optional/advanced lane, not a prerequisite.

The default command selects Claude and Codex:

```sh
npx vigil-link doctor
npx vigil-link status
npx vigil-link
```

OpenRouter and DeepSeek read API keys from the process environment and require an explicit provider selection:

```sh
OPENROUTER_API_KEY='...' npx vigil-link doctor --provider openrouter --live
OPENROUTER_API_KEY='...' npx vigil-link status --provider openrouter
OPENROUTER_API_KEY='...' npx vigil-link --provider openrouter

DEEPSEEK_API_KEY='...' npx vigil-link doctor --provider deepseek --live
DEEPSEEK_API_KEY='...' npx vigil-link status --provider deepseek
DEEPSEEK_API_KEY='...' npx vigil-link --provider deepseek
```

To link all four in one QR session:

```sh
OPENROUTER_API_KEY='...' DEEPSEEK_API_KEY='...' \
  npx vigil-link --provider claude,codex,openrouter,deepseek
```

Environment variables exist only in the CLI process unless the shell or user stores them elsewhere. Vigil does not create a shell profile or `.env` file. The resulting QR still contains the selected credentials in compressed plaintext. Read [qr-protocol.md](qr-protocol.md) and [threat-model.md](threat-model.md) before linking.

## Registry fields

The following example combines fields used by the current providers. A provider does not need every mapping block.

```jsonc
{
  "displayName": "Example",
  "defaultEnabled": false,
  "auth": "api_key_bearer",
  "usage": {
    "method": "GET",
    "url": "https://provider.example/usage",
    "headers": {
      "Authorization": "Bearer {access_token}",
      "X-Account": "{account_id}"
    }
  },
  "oauth": {
    "authorizeUrl": "https://provider.example/oauth/authorize",
    "tokenUrl": "https://provider.example/oauth/token",
    "clientId": "public-client-id",
    "scopes": ["usage:read"],
    "loopbackPort": 54545,
    "manualRedirectUri": "https://provider.example/oauth/callback"
  },
  "poll": {
    "minSeconds": 300,
    "jitterSeconds": 60,
    "backoff429BaseSeconds": 900,
    "backoffMaxSeconds": 3600
  },
  "discovery": {
    "adapter": "environment",
    "environment": { "accessToken": "EXAMPLE_API_KEY" }
  },
  "manualEntryHint": "Where the user can obtain this credential.",
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
  "responseEnvelope": {
    "codeKey": "code",
    "okCode": "0",
    "authCodes": ["1004"]
  },
  "requiredOutputs": {
    "minimumWindows": 1,
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
  "metricCollectionMappings": [
    {
      "sourceKey": "balances",
      "idKey": "currency",
      "valueKey": "amount",
      "label": "Balance",
      "kind": "balance",
      "unitKey": "currency",
      "secondary": false
    }
  ],
  "capabilities": ["rate_windows", "spend", "balance"]
}
```

Field behavior:

- `defaultEnabled: false` keeps a provider out of an unqualified CLI command.
- `experimental: true` marks an endpoint without a stable vendor contract or Vigil production capture; the CLI report and app surfaces label it.
- `usage.url` may contain `{account_id}`, substituted (percent-encoded) from the credential. A provider whose URL needs an account id the credential lacks makes no request and reports `authExpired`. Such providers must declare `discovery.environment.accountId`.
- `usage.headers` substitutes `{access_token}` and `{account_id}` at request time.
- `usage.query` adds query parameters: `{ "value": "literal" }` or `{ "compute": ... }` where compute is one of `monthStartUnixSeconds`, `currentYear`, `currentMonth` — evaluated client-side in UTC at request time (billing APIs need time ranges).
- `poll` is enforced independently by the CLI safety gate and the Apple scheduler.
- `discovery.adapter` selects code registered by the CLI. Registry data cannot create a new discovery or OAuth implementation.
- `windows` maps reset-based percentages. `sourceContainer` declares whether each source must be an object or array, and `sourceKeys` supplies ordered compatibility fallbacks. `conditions` selects an array entry by exact scalar fields. Conditions may declare `valueType` and `allowedNonMatches`, so malformed or unknown enum values fail closed. `omitWhen` suppresses inactive or unlimited lanes. `duration.allowedSeconds` restricts derived durations to observed exact values. `fallbackGroup` stops after the first successful candidate, and `requiredWhenPresent: false` permits absent optional candidate fields. Present malformed values still mark the response incomplete. A window may carry a provider label, a duration-derived ID, and `fields` overrides. `fields.utilization` reads a direct percentage; `fields.used` plus `fields.limit` computes the exact ratio. A field path beginning with `$` resolves from the response root, which supports a root-level reset shared by nested buckets.
- `additionalWindows` maps a response array of dynamically named windows. Claude uses one entry per model cap. Codex uses `entryWindows` to fan one model entry into its nested primary and secondary windows, with duration-derived suffixes. `requiredWhenPresent` marks an eligible entry incomplete if its identifier or every nested bucket fails to map. Filters, conditions, labels, prefixes, reset formats, static durations, and field overrides use the same bounded mapping rules as static windows.
- `responseFields.utilizationKind: "remaining"` inverts the percentage (utilization = 100 − value) for providers that report quota left. `responseFields.allowStringNumbers: true` accepts string-encoded window numbers ("46.5") for that provider only.
- `responseEnvelope` classifies provider-defined failures inside HTTP 2xx bodies. A configured field that disappears is schema drift. Listed `authCodes` become `authExpired`; another explicit provider error becomes `network`.
- `requiredOutputs` defines the minimum useful result: total and primary-window counts, metric counts, and required IDs. `minimumPrimaryWindows` prevents secondary lanes from satisfying a missing primary quota. It prevents a partial response from being labeled Live merely because one unrelated value survived.
- `requiredPaths` requires a key to exist while permitting an explicit JSON null. `absentOrNullPaths` permits only absence or null for a family Vigil has not implemented yet. Both detect upstream additions or removals before a subset is labeled Live.
- `exhaustiveCollections` declares wrapper paths, identity keys, allowed and unique identities, and optional duration rules for arrays whose complete shape matters. Unknown entries, competing wrappers, duplicate identities, and unsupported durations become schema drift.
- `incompleteWhen` marks a successful response incomplete when a provider flag matches. `requiredConditions` requires known body flags to remain present with their declared value. OpenAI uses both for pagination because this release does not follow later cost pages.
- `metricMappings` maps fixed scalar paths. `presencePaths` makes a present family contract-significant even when its leaf disappeared. `requires`, `requiresPresent`, `equalFields`, `requiresPositive`, `incompleteWhenAnyRequiredPresent`, and `fallbackBlockedBy` keep paired fields and ordered schema families coherent. With `aggregate: "sum"`, path segments ending in `[]` flat-map arrays (`data[].results[].amount.value`) and every resolved value is added. `aggregateUnitKey` and `aggregateExpectedUnit` require one aligned currency/unit entry for every aggregated amount. `scale` multiplies the result (0.01 converts cents to dollars). `exponentKey` takes precedence when present and valid. `unitKey` overrides the static unit only with a safe provider string; malformed present metadata is schema drift. Any present non-null scalar source must be numeric even when the metric is optional.
- `metricCollectionMappings` maps arrays such as balances returned in several currencies. Malformed entries and normalized-ID collisions retain valid diagnostics but make the response incomplete.
- `capabilities` describes the provider but does not, by itself, add rendering behavior.

## Mapping semantics

For a window mapping, Vigil reads `sourceKey` as a dot path. A segment may end in a selector, `items[kind=general]`, which picks one array element whose property string-equals the value. Multiple selector matches are invalid. `conditions` is preferred when omission or multiple candidates matter because it evaluates each array record. A missing or `null` bucket produces no window. A present malformed bucket is omitted and marks the response incomplete. A configured reset key must exist; an explicit JSON null remains a valid unknown reset. `resetFormat` is `iso8601`, `unixSeconds`, or `unixMillis`. Direct and remaining percentages must be within 0 through 100. Ratio windows require nonnegative used values and positive limits; a legitimate over-limit ratio displays as 100 percent. Unknown response fields are ignored unless an exhaustive or required-field contract covers them.

Both runtimes validate the raw response before mapping. Provider bodies must be strict UTF-8 JSON with no raw NUL, duplicate semantic object keys, leading `U+FEFF` inside a string, non-finite decoded numbers, lone surrogates, excessive nesting, or oversized node counts. One document-level UTF-8 BOM is tolerated. These rules prevent Node and Foundation from assigning different meanings to identical provider bytes.

For a scalar mapping, Vigil accepts finite JSON numbers. Balance APIs may encode exact decimal values as strings, which the metric mapper also accepts. Missing or null optional values are omitted. Present nonnumeric values are schema drift. Vigil preserves the provider's unit and does not convert currencies.

A summed metric distinguishes an honest zero from drift: a present-but-empty bucket array sums to 0 (a fresh account shows $0.00). A missing root key, any nonnumeric leaf, a changed container, or an array over the 128-entry safety bound drops the metric and marks the response incomplete. Static-window arrays, dynamic-window arrays, and metric collections use the same bound.

A successful response becomes `schemaChanged` when parsing fails or the result violates `requiredOutputs`. This includes missing required IDs, too few windows or metrics, and eligible dynamic entries that map incompletely. The classifier retains partial output for diagnostics. Apple surfaces preserve the last successful snapshot instead of presenting that partial response as Live.

## Claude

- Request: `GET https://api.anthropic.com/api/oauth/usage`.
- Required headers include `Authorization`, `anthropic-beta: oauth-2025-04-20`, `Accept`, and a Claude Code-style `User-Agent`.
- Response buckets: `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, and (null-tolerant, unverified) `seven_day_oauth_apps` / `seven_day_cowork`.
- Model-scoped weekly caps: a live response captured on 2026-07-21 carries `weekly_scoped` entries under `limits[]`, with `scope.model.display_name`, `percent`, and `resets_at`. Vigil maps each as a labeled secondary window (`weekly_scoped_<model>`), rendered as "&lt;Model&gt; weekly". The fixture preserves the observed keys, nesting, nullability, and fractional timestamp precision while replacing account-specific values.
- Overage credits: the observed `spend.used` and `spend.limit` family maps `amount_minor` through each value's exponent and currency. The legacy `extra_usage` family remains an ordered fallback. Vigil never mixes one member from each family, and a partial present family becomes schema drift. Disabled or absent extra usage carries null numbers and is skipped.
- Poll floor: 300 seconds. Do not lower it. The endpoint can return hard 429 responses without `Retry-After`.
- Discovery: `~/.claude/.credentials.json`, then the macOS Keychain service `Claude Code-credentials`.
- **On-device sign-in (mint):** PKCE authorize at `https://claude.ai/oauth/authorize` (`code=true`, the PKCE verifier passed as `state`), with an out-of-band redirect to `https://console.anthropic.com/oauth/code/callback`; the user pastes the returned code back into the app, which exchanges it at `https://platform.claude.com/v1/oauth/token`. Minted pairs (`src: "mint"`) refresh via the same token URL. Implemented in VigilKit `ClaudeAuth`, unit-tested, and completed on a real device and account on 2026-07-22.
- Preferred link path: mint a separate Vigil token pair. Copying another client's refresh token can cause rotation conflicts.
- Refresh: `POST https://platform.claude.com/v1/oauth/token`, only for pairs marked `src: "mint"`.
- Stability: the usage and OAuth behavior is not a public contract. The main buckets and scoped `limits[]` shape were observed live in July 2026. Only the fixture files marked `live_sanitized` in the provenance manifest are preserved captures. Other Claude cases remain synthetic boundary examples.

The CLI's desktop OAuth flow (the `npx vigil-link` mint path) currently requires the registered scope set, a literal `localhost` loopback host, `code=true`, and the PKCE verifier as `state`; the on-device app flow above uses the out-of-band `console.anthropic.com` redirect instead of the loopback host. Preserve the live tests and ADR-0005 when modifying either.

## ChatGPT / Codex

- Request: `GET https://chatgpt.com/backend-api/wham/usage`.
- Required headers include `Authorization`, `ChatGPT-Account-Id`, `Accept`, and a Codex-style `User-Agent`.
- Response buckets: `rate_limit.primary_window`, `rate_limit.secondary_window`, and optional `additional_rate_limits`. Each additional entry is identified by `metered_feature`, labeled by `limit_name`, and can fan into nested primary and secondary windows. Window duration determines whether each lane is session or weekly.
- Other mapped fields: `credits.balance` becomes Flex credits and `rate_limit_reset_credits.available_count` becomes reset credits available. Optional `spend_control` and `code_review_rate_limit` objects remain absent on the live account used for the 2026-07-22 shape check; Vigil does not invent values for null fields.
- Discovery: `~/.codex/auth.json` or `$CODEX_HOME/auth.json` (copied, `source: "file"` — never auto-refreshed).
- **On-device sign-in (mint):** OpenAI's OAuth device-code flow (`POST auth.openai.com/api/accounts/deviceauth/usercode` → poll `…/deviceauth/token` where 403/404 mean "pending" and success returns an `authorization_code` + server PKCE → exchange at `auth.openai.com/oauth/token`). The account id comes from the id_token `chatgpt_account_id` claim. Minted tokens (`source: "mint"`) refresh independently via `auth.openai.com/oauth/token`. Implemented in VigilKit `CodexAuth`, unit-tested against Codex source shapes, and completed on a real device and account on 2026-07-22. The committed Codex fixtures remain modeled examples rather than sanitized captures.
- Refresh: minted tokens refresh independently; a copied (`file`) token that expires becomes `authExpired` and the user re-links.
- Stability: both the usage endpoint and the device-code login are internal consumer surfaces (undocumented for third parties) and can change without notice.

## OpenRouter

- Request: `GET https://openrouter.ai/api/v1/key`.
- Credential: bearer API key from `OPENROUTER_API_KEY`.
- Mapped metrics: lifetime, daily, weekly, and monthly usage, the same four BYOK periods, plus key spending limit and remaining amount when both are present.
- Units: USD as reported by the endpoint.
- Both absent or null limit fields mean unlimited and remain optional. A one-sided limit/remaining pair is schema drift.

Official reference: <https://openrouter.ai/docs/api_reference/limits>

## DeepSeek

- Request: `GET https://api.deepseek.com/user/balance`.
- Credential: bearer API key from `DEEPSEEK_API_KEY`.
- Mapped metrics: every valid entry in `balance_infos`, keyed and labeled by currency.
- Vigil does not combine or convert balances from different currencies.

Official reference: <https://api-docs.deepseek.com/api/get-user-balance/>

## Moonshot (Kimi) and Moonshot China

- Request: `GET /v1/users/me/balance` on the matching global or China host.
- Mapped metrics: available, cash, and voucher balances. Global values use USD; China values use CNY.
- The 2xx body must contain `code == 0`, `scode == "0x0"`, and `status == true`. A missing or mistyped envelope field is schema drift. An explicit provider failure becomes `network` unless HTTP status already identifies authentication or rate limiting.
- Region credentials are not interchangeable. Vigil never converts currencies or folds a negative balance into zero.
- Both balance contracts are vendor-documented and are not labeled experimental. Their fixtures remain synthetic, not sanitized Vigil production captures.

Official references: <https://platform.kimi.ai/docs/api/balance> and <https://platform.kimi.com/docs/api/balance>

## OpenAI API

- Request: `GET https://api.openai.com/v1/organization/costs` with a read-only organization Admin key.
- Vigil computes the UTC month start, requests daily buckets, and sums every `data[].results[].amount.value` into month-to-date spend.
- A genuinely empty `data` array maps to `$0.00`. A missing, renamed, or non-array root becomes `schemaChanged` instead of a false zero.
- `has_more` must be present and false. A missing, renamed, or true flag becomes `schemaChanged`; this release does not silently report a partial page as the monthly total.

Official reference: <https://platform.openai.com/docs/api-reference/usage/costs>

## GitHub Copilot

- Request: the documented enhanced billing usage endpoint for the supplied username and current UTC year/month.
- Mapped metrics: `grossQuantity` as credits consumed, `netQuantity` as billable credits, `discountQuantity` as included credits, and `netAmount` as billable spend.
- The required-output contract demands both consumed credits and billable spend. A partial field rename cannot leave the account labeled Live.
- Organization-managed seats can return an empty per-user list. The aggregate mapper preserves a genuine empty month as zero.

Official reference: <https://docs.github.com/en/rest/billing/usage?apiVersion=2026-03-10>

## xAI API

- Request: `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance` with a Management Key and team ID.
- The documented `total.val` is a signed cent-denominated decimal string. Vigil multiplies by `-0.01`, so a provider value of `-1000` becomes a positive `$10.00` prepaid balance.
- xAI is opt-in but not experimental because this management endpoint is vendor-documented. The fixture is synthetic and has no Vigil production capture.

Official reference: <https://docs.x.ai/developers/rest-api-reference/management/billing>

## MiniMax (and MiniMax China)

- Request: `GET https://api.minimax.io/v1/token_plan/remains` (China: `api.minimaxi.com`).
- Credential: bearer API key from `MINIMAX_CODING_API_KEY` (China: `MINIMAX_CN_CODING_API_KEY`).
- Windows: session and weekly for both the `general` model (primary) and the `video` model (secondary). Current community clients report root-level `model_remains[]`; Vigil retains `data.model_remains[]` as a compatibility fallback. Percentages are reported as remaining and inverted to used. MiniMax's CLI identifies status 3 as unlimited, so those non-finite quota lanes are omitted while missing status fields remain valid.
- Intentionally unmapped: the `current_interval_usage_count` / `current_interval_total_count` absolute counts — `UsageWindow` is percentage-based, and the percentage already normalizes them; carrying raw counts as metrics would misrepresent them as currency/credits.

## Z.ai Coding Plan

- Request: `GET https://api.z.ai/api/monitor/usage/quota/limit` with a GLM Coding Plan key.
- Token windows are selected by all three discriminators: `type == TOKENS_LIMIT`, `unit`, and `number`. Unit 3/number 5 is the 5-hour window; unit 6/number 1 is weekly. Resets are Unix milliseconds.
- `TIME_LIMIT` is not a token quota. Vigil maps its current, limit, and remaining values as web-search call metrics.
- A 2xx body must contain `code == 200` and `success == true`. Known authentication codes become `authExpired`.
- This endpoint is experimental and community-researched. No Vigil production capture is committed.

Community reference: <https://github.com/robinebers/openusage/blob/9d2bf09f10e21f769494a525a9d65c84d7aeb1df/Sources/OpenUsage/Providers/ZAI/ZAIUsageMapper.swift>

## Cursor

- Request: `GET https://cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie.
- The billing reset is the response-root `billingCycleEnd` ISO-8601 value, not a field inside `individualUsage`.
- The primary plan window prefers `totalPercentUsed`, then exact used/limit ratios from individual or team shapes. These candidates form one ordered fallback group. Auto-selected and API-model percentages are optional model lanes. An enabled on-demand family requires a complete used/limit pair. Vigil prefers the personal capped pair, then the team pair. A zero limit is the documented unlimited case, so Vigil may retain personal or team spend without inventing a cap. Values are cents and scale by `0.01`.
- This web endpoint is experimental. Session cookies expire and must be pasted again.

Community reference: <https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift>

## Kimi K3 coding plan

- Request: `GET https://api.kimi.com/coding/v1/usages` with a Kimi Code key from `kimi.com/code/console`.
- The 5-hour bucket is selected from `limits[]` by a 300-minute duration. Values live under `detail`. Weekly values live under `usage`.
- `limit`, `used`, and `remaining` are decimal strings. Vigil computes utilization from `used / limit`; a zero or malformed limit is rejected. `resetTime` is ISO-8601 and can include fractional seconds.
- This endpoint is experimental and community-researched. It is distinct from the Moonshot open-platform balance API.

Community reference: <https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/kimi.md>

## Provider candidates

Provider count alone is not the goal. Vigil should add a provider only when it can report a meaningful value through a supportable authentication path.

Every candidate below was researched against vendor documentation and real client implementations (2026-07-19). They are held back deliberately; each row records why, so a future implementation starts from the blocker, not from scratch.

| Backlog candidate | Why it is not shipped yet |
|---|---|
| Codex separate reset-credit endpoint | Vigil maps `rate_limit_reset_credits.available_count` when it appears in the main WHAM response. Polling the separate reset-credit endpoint would require multi-request provider support and remains deliberately unimplemented. |
| GitHub Copilot percent windows | The only per-user quota window is the undocumented `copilot_internal/user` endpoint, which needs a GitHub device-flow OAuth mint — new machinery. The shipped GitHub provider covers spend/credits honestly via the documented billing API. |
| Anthropic Admin API cost report | Organization accounts only, and the query-parameter shape has not been verified against a live key. |
| Mistral Admin usage | Route verified live (401 unauthenticated) but the response shape is unconfirmed. Negative finding: `api.mistral.ai/v1/usage` does not exist (404) despite third-party claims. |
| Fireworks billing summary | Documented, but the time-parameter format is unverified; token totals arrive as int64 strings. |
| Gemini CLI / Antigravity | Google-private `cloudcode-pa` endpoints reachable only with Google OAuth token machinery; no stability promise. |
| Volcengine / Alibaba (Qwen) | Documented but require AWS-SigV4-style HMAC request signing — a real implementation burden with no bearer alternative. |
| Windsurf, Grok CLI | Usable endpoints answer in protobuf/gRPC-web framing, not JSON. |
| Qoder, MiMo, Perplexity, Groq console, OpenCode, Ollama cloud, Grok consumer | Session-cookie or HTML-scrape paths whose fragility (Cloudflare challenges, redeploy-sensitive URLs, markup regex) conflicts with the honest-freshness taxonomy. |

| Not viable | Verified reason |
|---|---|
| Together AI | No balance/usage endpoint: live probes 404 on every plausible route while `/v1/models` works; dashboard-only. |
| Cohere | Zero billing endpoints in Cohere's own published OpenAPI spec. |
| Replicate | `/v1/account` returns identity only; billing is web-only per the official schema. |
| Gemini API (AI Studio key) | No programmatic usage or quota endpoint accepts an API key; quota surfaces only as 429 at request time. |

The complete implementation checklist is in [provider-contribution.md](provider-contribution.md).

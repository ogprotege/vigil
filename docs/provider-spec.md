# Provider registry and support

`protocol/providers.json` is the canonical machine-readable registry for every provider Vigil can poll. It defines request policy and response mapping. It does not eliminate provider-specific code. Authentication, credential discovery, OAuth minting, unusual response shapes, and UI behavior may still require adapters.

## Support and stability matrix

| Provider | Default | Credential activation | Normalized data | Poll floor | Token refresh | Endpoint status | Vigil confidence |
|---|---:|---|---|---:|---|---|---|
| Claude | Yes | Vigil-owned OAuth mint, Claude Code file, or macOS Keychain | Session, weekly, Sonnet, and Opus windows | 300 s | Yes, only for credentials Vigil minted | Undocumented consumer endpoint | Supported, live-validated July 2026, fixture-covered; on-device sign-in pending device walk |
| ChatGPT / Codex | Yes | On-device device-code sign-in, or Codex CLI file | Session, weekly, and optional additional windows | 300 s | Minted tokens refresh independently; copied ones do not | Undocumented consumer endpoint | Supported, live-validated July 2026, fixture-covered; on-device sign-in pending device walk |
| OpenRouter | No | `OPENROUTER_API_KEY`, QR/paste handoff, or app manual entry | Spend, credit limit, remaining credits | 300 s | Not applicable; API key | Documented key endpoint | Opt-in preview, fixture-covered; live validation remains a release check |
| DeepSeek | No | `DEEPSEEK_API_KEY`, QR/paste handoff, or app manual entry | Balance by returned currency | 300 s | Not applicable; API key | Documented balance endpoint | Opt-in preview, fixture-covered; live validation remains a release check |
| Moonshot (Kimi) | No | `MOONSHOT_API_KEY` (`MOONSHOT_CN_API_KEY` for the China provider), QR/paste, or app manual entry | Available, cash, and voucher balances (USD global, CNY China) | 300 s | Not applicable; API key | Documented balance endpoint (`/v1/users/me/balance`) | Opt-in preview, fixture-covered (research-verified 2026-07-19); live validation remains a release check |
| MiniMax Coding Plan | No | `MINIMAX_CODING_API_KEY` (`MINIMAX_CN_CODING_API_KEY` for China), QR/paste, or app manual entry | Session and weekly windows (inverted from remaining-percent) | 300 s | Not applicable; API key | Documented Token Plan endpoint (`/v1/token_plan/remains`), also used by the official MiniMax CLI | Opt-in preview, fixture-covered (research-verified 2026-07-19); live validation remains a release check |
| OpenAI API | No | `OPENAI_ADMIN_KEY` (read-only org Admin key), QR/paste, or app manual entry | Month-to-date spend summed over daily cost buckets | 300 s | Not applicable; API key | Documented organization costs endpoint | Opt-in preview, fixture-covered (research-verified 2026-07-19); live validation remains a release check |
| GitHub Copilot | No | `GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER` (fine-grained PAT with Account → Plan read), QR/paste, or app manual entry | AI spend and credits used, current month | 300 s | Not applicable; PAT | Documented billing usage endpoint; org-managed seats report empty | Opt-in preview, fixture-covered (research-verified 2026-07-19); live validation remains a release check |
| xAI API | No | `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID` (console Management Key), QR/paste, or app manual entry | Prepaid balance | 300 s | Not applicable; API key | Documented management endpoint; balance denomination unverified live | **Experimental**, fixture-covered |
| Z.ai Coding Plan | No | `ZAI_API_KEY`, QR/paste, or app manual entry | Session and monthly quota windows, plan label | 300 s | Not applicable; API key | Undocumented; verified across independent community clients | **Experimental**, fixture-covered; schema drift is the known hazard |
| Cursor | No | `CURSOR_SESSION_TOKEN` (browser `WorkosCursorSessionToken` cookie), QR/paste, or app manual entry | Plan usage window, billing-cycle reset, on-demand spend | 300 s | None; session cookie expires and must be re-pasted | Undocumented web API; individual accounts have no official endpoint | **Experimental**, fixture-covered; expect authExpired on cookie expiry |
| Kimi K3 (coding plan) | No | `KIMI_CODE_API_KEY` (coding-plan key, separate from the Moonshot balance key), QR/paste, or app manual entry | Session and weekly coding-plan windows (utilization percent, unix resets) | 300 s | Not applicable; API key | Undocumented coding-plan usage endpoint (`api.kimi.com/coding/v1/usages`); response shape modeled, not yet live-verified | **Experimental**, fixture-covered; needs a live coding-plan key to confirm the exact field/selector names |

Definitions:

- **Poll floor** is the registry `poll.minSeconds`, enforced independently by the CLI's per-provider gate and the Apple per-account scheduler. Do not lower it.
- **Supported** means the implementation has fixtures and has been checked against a real account. It does not mean the vendor supports Vigil.
- **Opt-in preview** means the provider is implemented but excluded from the default command. Users must name it explicitly.
- **Fixture-covered** means CI verifies known response shapes without sending credentials or calling production.
- **Undocumented** means the vendor may change or remove the consumer endpoint without notice.
- **Experimental** means the endpoint is community-proven but not vendor-documented (`"experimental": true` in the registry). The CLI, the app pickers, and the account surfaces label these visibly. They can break without notice; a break surfaces as `schemaChanged` or `authExpired`, never as silently wrong numbers.

Region variants (`moonshot` / `moonshot_cn`, `minimax` / `minimax_cn`) are separate providers because the vendors run separate key namespaces: a China-platform key against the global host returns 401, and MiniMax's global host answers wrong-region keys with an HTTP 200 error body, which Vigil surfaces as `schemaChanged`.

## Activating providers

Claude and Codex are set up **on-device in the app** — "Add account" → "Sign in with Claude" (approve in a browser, then paste the code back) or "Sign in with Codex" (the app shows a code, you approve it in a browser, and the app polls until it completes) — and each API-key provider is added by tapping it under "Paste a provider key" and pasting the key. `npx vigil-link` is an **optional** path for reusing a Claude Code / Codex sign-in that already lives on a computer; the CLI commands below are that optional/advanced lane, not a prerequisite.

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
- `experimental: true` marks a community-proven, undocumented endpoint; the CLI report and app surfaces label it.
- `usage.url` may contain `{account_id}`, substituted (percent-encoded) from the credential. A provider whose URL needs an account id the credential lacks makes no request and reports `authExpired`. Such providers must declare `discovery.environment.accountId`.
- `usage.headers` substitutes `{access_token}` and `{account_id}` at request time.
- `usage.query` adds query parameters: `{ "value": "literal" }` or `{ "compute": ... }` where compute is one of `monthStartUnixSeconds`, `currentYear`, `currentMonth` — evaluated client-side in UTC at request time (billing APIs need time ranges).
- `poll` is enforced independently by the CLI safety gate and the Apple scheduler.
- `discovery.adapter` selects code registered by the CLI. Registry data cannot create a new discovery or OAuth implementation.
- `windows` maps reset-based percentages. A window may carry `fields: { utilization, resetsAt }` overriding the provider `responseFields` for that window alone (MiniMax keeps session and weekly numbers under different keys of one bucket). A window may also carry a `label` (a model name) when the response supplies one; static windows have no label and are named at the UI layer.
- `additionalWindows` maps a response array of dynamically-named windows (Codex per-model lanes, Claude `limits[]` model caps). It takes `sourceKey` (the array), `idKey` (a dot path within each entry to the id string), and `secondary`, plus optional: `filter: { key, equals }` (keep only matching entries — e.g. Claude's `kind == "weekly_scoped"`), `idPrefix` (synthesize a stable normalized id `prefix_<slug>`; absent means the raw id stands), `labelKey` (dot path to a display label carried on the window), `resetFormat` (default `unixSeconds`), `windowSeconds`, and `fields` (per-entry `responseFields` override).
- `responseFields.utilizationKind: "remaining"` inverts the percentage (utilization = 100 − value) for providers that report quota left. `responseFields.allowStringNumbers: true` accepts string-encoded window numbers ("46.5") for that provider only.
- `metricMappings` maps fixed scalar paths. With `aggregate: "sum"`, path segments ending in `[]` flat-map arrays (`data[].results[].amount.value`) and every resolved value is added. `scale` multiplies the result (0.01 converts cents to dollars). `unitKey` (a dot path to a currency/unit string) overrides the static `unit` when it resolves.
- `metricCollectionMappings` maps arrays such as balances returned in several currencies.
- `capabilities` describes the provider but does not, by itself, add rendering behavior.

## Mapping semantics

For a window mapping, Vigil reads `sourceKey` as a dot path. A segment may end in a selector, `items[kind=general]`, which picks the first array element whose property string-equals the value. A missing or `null` bucket produces no window. A malformed bucket is skipped. `resetFormat` is `iso8601`, `unixSeconds`, or `unixMillis`. Utilization is clamped to 0 through 100 (after any `remaining` inversion). Unknown response fields are ignored.

For a scalar mapping, Vigil accepts finite JSON numbers. Balance APIs may encode exact decimal values as strings, which the metric mapper also accepts. Vigil preserves the provider's unit and does not convert currencies.

A summed metric distinguishes an honest zero from drift: a present-but-empty bucket array sums to 0 (a fresh account shows $0.00), while a missing root key, or leaves that all fail to parse, drops the metric.

A successful response becomes `schemaChanged` when no valid window or metric can be mapped. This prevents an empty but apparently successful dashboard.

## Claude

- Request: `GET https://api.anthropic.com/api/oauth/usage`.
- Required headers include `Authorization`, `anthropic-beta: oauth-2025-04-20`, `Accept`, and a Claude Code-style `User-Agent`.
- Response buckets: `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, and (null-tolerant, unverified) `seven_day_oauth_apps` / `seven_day_cowork`.
- Model-scoped weekly caps: the response's `limits[]` array carries `weekly_scoped` entries (`scope.model.display_name`, `utilization`, `resets_at`). Vigil maps each as a labeled secondary window (`weekly_scoped_<model>`), rendered as "&lt;Model&gt; weekly". **Fixture-modeled from prior research, not yet live-validated** — the `additionalWindows.fields` override exists to fix a field-name mismatch (e.g. `used_percent` vs `utilization`) once a live payload is captured.
- Overage credits: `extra_usage` (when `is_enabled`) maps to two metrics — `extra_used` (spend) and `extra_limit` (limit) — in the response's own `currency` (via `unitKey`). Disabled/absent extra usage carries null numbers and is skipped.
- Poll floor: 300 seconds. Do not lower it. The endpoint can return hard 429 responses without `Retry-After`.
- Discovery: `~/.claude/.credentials.json`, then the macOS Keychain service `Claude Code-credentials`.
- **On-device sign-in (mint):** PKCE authorize at `https://claude.ai/oauth/authorize` (`code=true`, the PKCE verifier passed as `state`), with an out-of-band redirect to `https://console.anthropic.com/oauth/code/callback`; the user pastes the returned code back into the app, which exchanges it at `https://platform.claude.com/v1/oauth/token`. Minted pairs (`src: "mint"`) refresh via the same token URL. Implemented in VigilKit `ClaudeAuth` (unit-tested); **pending a live device walk** against a real Claude account.
- Preferred link path: mint a separate Vigil token pair. Copying another client's refresh token can cause rotation conflicts.
- Refresh: `POST https://platform.claude.com/v1/oauth/token`, only for pairs marked `src: "mint"`.
- Stability: the usage and OAuth behavior is not a public contract. The window buckets were live-validated in July 2026; the `limits[]`/`extra_usage` shapes are fixture-modeled pending a live capture, and can drift.

The CLI's desktop OAuth flow (the `npx vigil-link` mint path) currently requires the registered scope set, a literal `localhost` loopback host, `code=true`, and the PKCE verifier as `state`; the on-device app flow above uses the out-of-band `console.anthropic.com` redirect instead of the loopback host. Preserve the live tests and ADR-0005 when modifying either.

## ChatGPT / Codex

- Request: `GET https://chatgpt.com/backend-api/wham/usage`.
- Required headers include `Authorization`, `ChatGPT-Account-Id`, `Accept`, and a Codex-style `User-Agent`.
- Response buckets: `rate_limit.primary_window`, `rate_limit.secondary_window`, and optional `additional_rate_limits`.
- Discovery: `~/.codex/auth.json` or `$CODEX_HOME/auth.json` (copied, `source: "file"` — never auto-refreshed).
- **On-device sign-in (mint):** OpenAI's OAuth device-code flow (`POST auth.openai.com/api/accounts/deviceauth/usercode` → poll `…/deviceauth/token` where 403/404 mean "pending" and success returns an `authorization_code` + server PKCE → exchange at `auth.openai.com/oauth/token`). The account id comes from the id_token `chatgpt_account_id` claim. Minted tokens (`source: "mint"`) refresh independently via `auth.openai.com/oauth/token`. Implemented in VigilKit `CodexAuth` (unit-tested against the Codex CLI source shapes); **pending a live device walk** against a real ChatGPT account.
- Refresh: minted tokens refresh independently; a copied (`file`) token that expires becomes `authExpired` and the user re-links.
- Stability: both the usage endpoint and the device-code login are internal consumer surfaces (undocumented for third parties) and can change without notice.

## OpenRouter

- Request: `GET https://openrouter.ai/api/v1/key`.
- Credential: bearer API key from `OPENROUTER_API_KEY`.
- Mapped metrics: `data.usage`, `data.limit`, and `data.limit_remaining` when present.
- Units: USD as reported by the endpoint.
- A missing optional limit does not fabricate a percentage or turn a valid usage value into an error.

Official reference: <https://openrouter.ai/docs/api-reference/limits>

## DeepSeek

- Request: `GET https://api.deepseek.com/user/balance`.
- Credential: bearer API key from `DEEPSEEK_API_KEY`.
- Mapped metrics: every valid entry in `balance_infos`, keyed and labeled by currency.
- Vigil does not combine or convert balances from different currencies.

Official reference: <https://api-docs.deepseek.com/api/get-user-balance/>

## MiniMax (and MiniMax China)

- Request: `GET https://api.minimax.io/v1/token_plan/remains` (China: `api.minimaxi.com`).
- Credential: bearer API key from `MINIMAX_CODING_API_KEY` (China: `MINIMAX_CN_CODING_API_KEY`).
- Windows: session and weekly for both the `general` model (primary) and the `video` model (secondary), selected from `data.model_remains[]` by `model_name`. Percentages are reported as remaining and inverted to used.
- Intentionally unmapped: the `current_interval_usage_count` / `current_interval_total_count` absolute counts — `UsageWindow` is percentage-based, and the percentage already normalizes them; carrying raw counts as metrics would misrepresent them as currency/credits.

## Provider candidates

Provider count alone is not the goal. Vigil should add a provider only when it can report a meaningful value through a supportable authentication path.

Every candidate below was researched against vendor documentation and real client implementations (2026-07-19). They are held back deliberately; each row records why, so a future implementation starts from the blocker, not from scratch.

| Backlog candidate | Why it is not shipped yet |
|---|---|
| Codex `rate_limits_by_limit_id` | The response also carries per-limit-id windows as an object keyed by id (not the array `additionalWindows` iterates). Supporting it needs an object-fan-out engine primitive; the shipped Codex windows already cover primary/secondary plus `additional_rate_limits` lanes. |
| Codex reset-credit balance | `chatgpt.com/backend-api/wham/rate-limit-reset-credits` is a *second* endpoint; the registry models one usage request per provider. Multi-request providers need an engine change. |
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

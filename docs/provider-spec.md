# Provider registry and support

`protocol/providers.json` is the canonical machine-readable registry for every provider Vigil can poll. It defines request policy and response mapping. It does not eliminate provider-specific code. Authentication, credential discovery, OAuth minting, unusual response shapes, and UI behavior may still require adapters.

## Support and stability matrix

| Provider | Default | Credential activation | Normalized data | Token refresh | Endpoint status | Vigil confidence |
|---|---:|---|---|---|---|---|
| Claude | Yes | Vigil-owned OAuth mint, Claude Code file, or macOS Keychain | Session, weekly, Sonnet, and Opus windows | Yes, only for credentials Vigil minted | Undocumented consumer endpoint | Supported, live-validated July 2026, fixture-covered |
| ChatGPT / Codex | Yes | Codex CLI file; access token and account ID required | Session, weekly, and optional additional windows | No independent refresh | Undocumented consumer endpoint | Supported, live-validated July 2026, fixture-covered |
| OpenRouter | No | `OPENROUTER_API_KEY`, QR/paste handoff, or app manual entry | Spend, credit limit, remaining credits | Not applicable; API key | Documented key endpoint | Opt-in preview, fixture-covered; live validation remains a release check |
| DeepSeek | No | `DEEPSEEK_API_KEY`, QR/paste handoff, or app manual entry | Balance by returned currency | Not applicable; API key | Documented balance endpoint | Opt-in preview, fixture-covered; live validation remains a release check |

Definitions:

- **Supported** means the implementation has fixtures and has been checked against a real account. It does not mean the vendor supports Vigil.
- **Opt-in preview** means the provider is implemented but excluded from the default command. Users must name it explicitly.
- **Fixture-covered** means CI verifies known response shapes without sending credentials or calling production.
- **Undocumented** means the vendor may change or remove the consumer endpoint without notice.

## Activating providers

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
- `usage.headers` substitutes `{access_token}` and `{account_id}` at request time.
- `poll` is enforced independently by the CLI safety gate and the Apple scheduler.
- `discovery.adapter` selects code registered by the CLI. Registry data cannot create a new discovery or OAuth implementation.
- `windows` maps reset-based percentages.
- `metricMappings` maps fixed scalar paths.
- `metricCollectionMappings` maps arrays such as balances returned in several currencies.
- `capabilities` describes the provider but does not, by itself, add rendering behavior.

## Mapping semantics

For a window mapping, Vigil reads `sourceKey` as a dot path. A missing or `null` bucket produces no window. A malformed bucket is skipped. `resetFormat` is `iso8601` or `unixSeconds`. Utilization is clamped to 0 through 100. Unknown response fields are ignored.

For a scalar mapping, Vigil accepts finite JSON numbers. Balance APIs may encode exact decimal values as strings, which the metric mapper also accepts. Vigil preserves the provider's unit and does not convert currencies.

A successful response becomes `schemaChanged` when no valid window or metric can be mapped. This prevents an empty but apparently successful dashboard.

## Claude

- Request: `GET https://api.anthropic.com/api/oauth/usage`.
- Required headers include `Authorization`, `anthropic-beta: oauth-2025-04-20`, `Accept`, and a Claude Code-style `User-Agent`.
- Response buckets: `five_hour`, `seven_day`, `seven_day_sonnet`, and `seven_day_opus`.
- Poll floor: 300 seconds. Do not lower it. The endpoint can return hard 429 responses without `Retry-After`.
- Discovery: `~/.claude/.credentials.json`, then the macOS Keychain service `Claude Code-credentials`.
- Preferred link path: mint a separate Vigil token pair. Copying another client's refresh token can cause rotation conflicts.
- Refresh: `POST https://platform.claude.com/v1/oauth/token`, only for pairs marked `src: "mint"`.
- Stability: the usage and OAuth behavior is not a public contract. The details were live-validated in July 2026 and can drift.

The verified OAuth flow currently requires the registered scope set, a literal `localhost` loopback host, `code=true`, and the PKCE verifier as `state`. Preserve the live tests and ADR-0005 when modifying it.

## ChatGPT / Codex

- Request: `GET https://chatgpt.com/backend-api/wham/usage`.
- Required headers include `Authorization`, `ChatGPT-Account-Id`, `Accept`, and a Codex-style `User-Agent`.
- Response buckets: `rate_limit.primary_window`, `rate_limit.secondary_window`, and optional `additional_rate_limits`.
- Discovery: `~/.codex/auth.json` or `$CODEX_HOME/auth.json`.
- Refresh: not independently verified. An expired token becomes `authExpired`, and the user must refresh Codex and re-link.
- Stability: the usage endpoint is an internal consumer surface and can change without notice.

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

## Provider candidates

Provider count alone is not the goal. Vigil should add a provider only when it can report a meaningful value through a supportable authentication path.

| Candidate | Current blocker or required decision |
|---|---|
| GitHub Copilot | Public APIs focus on organization usage. Personal quota support needs a stable, permitted endpoint. |
| Cursor | Official APIs focus on team or admin data. Personal account support needs a safe credential path. |
| Gemini CLI | No stable public personal quota API has been established for Vigil. |
| Kimi, Qwen, Hugging Face | Require endpoint, authentication, and terms review before implementation. |
| Other API gateways | Prefer documented balance or spend endpoints with user-scoped keys. |

The complete implementation checklist is in [provider-contribution.md](provider-contribution.md).

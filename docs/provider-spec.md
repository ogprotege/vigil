# Provider spec

`protocol/providers.json` is the canonical, machine-readable registry of every provider Vigil knows how to poll. This document explains the fields and records the verified facts behind the v1 providers. **All consumer usage endpoints are undocumented vendor internals** — they can change without notice; the `schemaChanged` snapshot status plus fixture-driven mappers are how Vigil degrades gracefully when they do.

## Registry fields

```jsonc
{
  "displayName": "Claude",
  "auth": "oauth_bearer",
  "usage": {                       // the polling request, as data
    "method": "GET",
    "url": "https://…",
    "headers": { "Authorization": "Bearer {access_token}", … }   // {access_token}, {account_id} substituted at request time
  },
  "oauth": { … },                  // authorize/token URLs, public clientId, scopes (mint + refresh flows)
  "poll": {                        // the reliability contract
    "minSeconds": 300,             // NEVER poll faster than this
    "jitterSeconds": 60,           // random 0..jitter added to every scheduled fetch
    "backoff429BaseSeconds": 900,  // first backoff after a 429
    "backoffMaxSeconds": 3600      // backoff cap (doubles each consecutive 429)
  },
  "discovery": { … },              // where the companion CLI finds existing credentials
  "windows": [                     // response → UsageWindow mapping
    { "id": "session", "sourceKey": "five_hour", "resetFormat": "iso8601",
      "windowSeconds": 18000, "secondary": false }
  ],
  "capabilities": ["rate_windows"] // "spend" reserved for v1.1
}
```

Mapping semantics: for each `windows[]` entry, read `sourceKey` (dot-path) from the response JSON. A `null`/missing bucket produces **no window** (not an error). `resetFormat` is `iso8601` (string timestamp) or `unixSeconds` (number). `windowSeconds` in the spec is a fallback for providers whose response includes it (response value wins). Unknown response fields are always ignored; a response where **no** window mapping resolves is `schemaChanged`.

## Claude (verified July 2026)

- `GET https://api.anthropic.com/api/oauth/usage` — powers claude.ai's own usage panel and Claude Code `/usage`.
- Headers: `Authorization: Bearer <sk-ant-oat…>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, and **`User-Agent: claude-code/<ver>` is mandatory** — without it requests land in an aggressively-limited bucket (401s/429s).
- Response buckets: `five_hour` (session), `seven_day` (weekly all-model), `seven_day_sonnet`, `seven_day_opus` (model sub-quotas; may be null) — each `{ "utilization": 0-100, "resets_at": ISO-8601 | null }`. Other buckets are experimental — ignored.
- Rate limiting: hard 429s with **no Retry-After**. Community-established safe floor: **≥5 min between polls**. This is the #1 cause of "broken" monitor apps.
- Token scope: usage requires `user:profile`; an inference-only token 401s.
- Refresh: `POST https://platform.claude.com/v1/oauth/token`, public client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, `grant_type=refresh_token`. Access tokens are short-lived (~1–8 h).
- Credential discovery: `~/.claude/.credentials.json` → `.claudeAiOauth.{accessToken,refreshToken,expiresAt,scopes,subscriptionType}`; macOS Keychain generic password `Claude Code-credentials` (same JSON).
- **Mint-don't-copy:** `vigil-link` defaults to minting Vigil its own token pair via the browser OAuth flow (PKCE, loopback redirect) so Vigil's refreshes can never race Claude Code's own refresh-token rotation on the computer. `--copy` exists as a fallback and may require re-linking more often.

## ChatGPT / Codex (verified July 2026)

- `GET https://chatgpt.com/backend-api/wham/usage`.
- Headers: `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`, a codex-style `User-Agent`.
- Response: `rate_limit.primary_window` (session) and `rate_limit.secondary_window` (weekly), each `{ "used_percent", "reset_at" (unix seconds), "limit_window_seconds" }`; optional `additional_rate_limits[]` (model-specific lanes → mapped as secondary windows; shape is best-effort, entries that don't parse are skipped); `plan_type`.
- Credential discovery: `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) → `tokens.{access_token,refresh_token,id_token,account_id}`. Plan label decodable from the `id_token` JWT claims (decode only, never verified, never included in QR payloads — JWTs are large).
- Refresh: handled by the Codex CLI itself; the endpoint is not yet independently verified, so v1 surfaces expiry as `authExpired` → "re-link from your computer".

## Expansion map (in rough order)

| Provider | Path | Notes |
|---|---|---|
| GitHub Copilot | `GET api.github.com/copilot_internal/user` | GitHub OAuth device flow (`read:user`); `quotaSnapshots.premiumInteractions` |
| Kimi (Moonshot) | mirror CodexBar's Kimi integration | user-requested |
| Qwen (Alibaba) | Qwen Code CLI creds (`~/.qwen/oauth_creds.json`, Gemini CLI fork) | user-requested |
| Hugging Face | Pro inference credits — no precedent, exploratory | user-requested |
| Cursor | `GET cursor.com/api/usage-summary` (browser session cookie) | harder handoff |
| Windsurf / Grok / Poe / Cline / Warp | per CodexBar docs (github.com/steipete/CodexBar) | canonical reference |
| Gemini CLI | `cloudcode-pa` retrieveUserQuota | consumer tier deprecating mid-2026; wait for Antigravity to settle |

v1.1 API-spend tiers (researched, roadmap): **A** plain-key pollable (OpenRouter `/api/v1/key`, DeepSeek `/user/balance`, Fireworks `billingUsage`, Moonshot balance) → **B** admin-key (Anthropic/OpenAI/Mistral/xAI org reports) → **C** no pollable surface (Together, Cohere, Perplexity, Cerebras — shown honestly as unsupported).

## Adding a provider (the contract)

1. Add the registry entry to `protocol/providers.json`.
2. Capture/synthesize at least two response fixtures + hand-write their `-expected.json` normalized outputs.
3. Implement the thin mapper in the CLI (`cli/src/providers/`) and VigilKit (`Sources/VigilKit/Providers/`).
4. Both CI suites must pass fixture parity; the Swift spec-parity test must be updated with the mirrored constants.

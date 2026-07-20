# vigil-link

`vigil-link` checks supported AI-provider usage from the terminal and transfers selected credentials to the Vigil iPhone and Mac app. It talks directly to each provider. There is no Vigil account, analytics service, or cloud relay.

## Requirements

- Node.js 20 or later
- A supported provider sign-in or API key

Run without installing:

```sh
npx vigil-link status
npx vigil-link doctor
npx vigil-link
```

## Guided setup

Running `npx vigil-link` with no arguments starts a guided wizard (when your terminal is interactive):

1. It scans this computer for all supported providers and shows what it found (`✓ Claude — Claude Code sign-in`) and what it didn't (`✗ OpenRouter — enter an API key now`).
2. You pick which accounts to link — everything found is preselected; press Enter to accept.
3. For any provider it couldn't find, it walks you through pasting an API key (input hidden), or signs you in to Claude via your browser.
4. It verifies each account, shows the QR code (auto-sized to your terminal; multiple codes cycle until you press a key), and clears the screen when you're done.

No flags to memorize. The flags below are for scripting and advanced use — passing any of `--provider`, `--json`, `--yes`, `--copy`, or `--mint` opts out of the wizard.

This wizard is an optional path, not the main way in. On the iPhone, **Add account → Sign in with Claude** and **Sign in with Codex** sign in to Claude and ChatGPT/Codex directly (a browser approval and a short code), and **Add a provider directly** lets you paste any API key straight into the app — no terminal required. Reach for `vigil-link` when you'd rather reuse a Claude Code or Codex sign-in already on a computer and hand it to the phone by QR.

## Supported providers

Thirteen providers ship in the registry. Claude and ChatGPT/Codex are enabled by default; the rest are opt-in and activate when you set their environment variable(s). Plain `npx vigil-link` (and `status`/`doctor`) scans **every** provider in the registry — see [docs/provider-spec.md](https://github.com/ogprotege/vigil/blob/main/docs/provider-spec.md) for the full list and verified endpoint facts.

| Provider | Data | Activation | Default |
|---|---|---|---|
| Claude | Session and weekly usage windows | Claude Code credentials or a Vigil-owned browser OAuth token | Yes |
| ChatGPT / Codex | Session, weekly, and additional windows | Codex CLI credentials | Yes |
| OpenRouter | Spend, credit limit, and remaining credits | `OPENROUTER_API_KEY` | No |
| DeepSeek | Balance by currency | `DEEPSEEK_API_KEY` | No |
| Moonshot (Kimi) | Balance | `MOONSHOT_API_KEY` | No |
| Moonshot (Kimi) China | Balance | `MOONSHOT_CN_API_KEY` | No |
| MiniMax Coding Plan | Session and weekly windows | `MINIMAX_CODING_API_KEY` | No |
| MiniMax Coding Plan China | Session and weekly windows | `MINIMAX_CN_CODING_API_KEY` | No |
| OpenAI API | Month-to-date spend | `OPENAI_ADMIN_KEY` (Admin key) | No |
| GitHub Copilot | AI-credit spend | `GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER` | No |
| xAI API *(experimental)* | Prepaid balance | `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID` | No |
| Z.ai / GLM Coding Plan *(experimental)* | Session and monthly windows | `ZAI_API_KEY` | No |
| Cursor *(experimental)* | Plan usage and on-demand spend | `CURSOR_SESSION_TOKEN` | No |

**xAI, Z.ai, and Cursor are experimental** — their endpoints are undocumented and can drift.

For example, OpenRouter and DeepSeek activate like this:

```sh
OPENROUTER_API_KEY='...' npx vigil-link status --provider openrouter
DEEPSEEK_API_KEY='...' npx vigil-link status --provider deepseek

OPENROUTER_API_KEY='...' DEEPSEEK_API_KEY='...' \
  npx vigil-link --provider claude,codex,openrouter,deepseek
```

Claude and Codex use undocumented consumer usage endpoints and can change without notice. OpenRouter and DeepSeek use documented endpoints, but this release validates them with sanitized fixtures rather than live CI credentials.

## Commands

```text
vigil-link                  Guided setup: scan this computer, pick accounts, show the QR
vigil-link status           Print current usage, spend, and balances
vigil-link doctor           Show credential-discovery diagnostics
vigil-link doctor --live    Add a provider request to the diagnostics
vigil-link --version        Print the vigil-link version
```

Use `--provider` with comma-separated provider IDs. A command without that option selects only the default providers.

The normal Claude link flow mints a separate token for Vigil. Use `--copy` only when you intentionally want to transfer credentials owned by another CLI. Use `--json --yes` for a credential-bearing paste code when QR scanning is unavailable, then clear your terminal scrollback.

Run `npx vigil-link --help` for every option.

## Poll safety

Provider endpoints impose strict request limits. `vigil-link` reserves each check in a cross-process poll gate before network access. It stores only timestamps and consecutive-429 counters under the first available location:

1. `VIGIL_STATE_DIR`
2. `$XDG_CACHE_HOME/vigil-link`
3. `~/.cache/vigil-link`

It never writes credentials or usage values to that cache. Removing the cache can cause an unnecessary provider request and should not be used to bypass a rate limit.

Each network attempt has a 15-second timeout. Transport retries are bounded. One failed provider does not abort the remaining report.

## QR security

The `vigil1` QR and paste formats contain compressed plaintext credentials. Show them only in a private place. The CLI asks for consent, clears terminal scrollback by default, and the app rejects codes older than 10 minutes or more than 60 seconds in the future.

Use `--no-clear` only when you accept leaving the QR in terminal history. Revoke any credential exposed in a screenshot, recording, log, or shared terminal.

## More information

- [Full Vigil documentation](https://github.com/ogprotege/vigil#readme)
- [Provider support and activation](https://github.com/ogprotege/vigil/blob/main/docs/provider-spec.md)
- [Troubleshooting](https://github.com/ogprotege/vigil/blob/main/docs/troubleshooting.md)
- [Security policy](https://github.com/ogprotege/vigil/blob/main/SECURITY.md)
- [Threat model](https://github.com/ogprotege/vigil/blob/main/docs/threat-model.md)

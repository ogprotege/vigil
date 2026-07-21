<p align="center">
  <img src="docs/assets/icon-256.png" width="128" alt="Vigil app icon" />
</p>

<h1 align="center">Vigil</h1>

<p align="center"><b>Know exactly where you stand against your AI limits, spend, and balances — on your phone.</b><br/>
Claude and ChatGPT/Codex subscription windows (including per-model caps), plus opt-in gateway balances and spend from 11 more providers. On your iPhone, your Mac, and your terminal. No Vigil server.</p>

<p align="center">
  <a href="https://github.com/ogprotege/vigil/actions/workflows/cli.yml"><img src="https://github.com/ogprotege/vigil/actions/workflows/cli.yml/badge.svg" alt="cli CI" /></a>
  <a href="https://github.com/ogprotege/vigil/actions/workflows/apple.yml"><img src="https://github.com/ogprotege/vigil/actions/workflows/apple.yml/badge.svg" alt="apple CI" /></a>
  <a href="https://www.npmjs.com/package/vigil-link"><img src="https://img.shields.io/npm/v/vigil-link?label=vigil-link" alt="npm" /></a>
  <img src="https://img.shields.io/badge/platforms-iOS%2017%2B%20·%20macOS%2014%2B%20·%20CLI-blue" alt="platforms" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" /></a>
</p>

---

## What is Vigil?

Vigil is an on-device monitor for your AI subscription and API limits. It reads your usage **directly from each provider** — Claude's 5-hour and weekly windows, ChatGPT/Codex's session and weekly windows, the special per-model caps each platform enforces (Opus, Sonnet, and newer model-scoped weekly limits; Codex's per-model lanes), plus overage credits and gateway balances — and shows it on your iPhone with live reset countdowns.

There is **no Vigil server and no account**. Your credentials move from your computer to your phone once, over a QR code, and live only in your device's Keychain. Nothing phones home.

The great desktop token monitors already exist (see [Acknowledgments](#acknowledgments)). Vigil is the piece that was missing: the same trustworthy monitoring, **on your phone**, with the reset times and model-specific limits surfaced clearly.

Vigil is built around the three things that make a monitor trustworthy:

1. **Set up on the phone.** Sign in to Claude and ChatGPT/Codex right in the app (a browser approval and a short code), and add any API-key provider by pasting its key — no computer, no terminal. If you'd rather reuse a Claude Code or Codex sign-in already on a machine, `npx vigil-link` can hand it over by QR too.
2. **Honest freshness.** Provider endpoints rate-limit hard (Claude 429-jails anything polling faster than ~5 minutes). Every fetch draws from one shared polling ledger, and reset countdowns tick client-side so the UI stays live between fetches. When data is stale or a provider changes something, Vigil says so instead of quietly lying.
3. **On-device only.** Credentials live in your device's Keychain and nowhere else. No servers, no analytics. See [docs/privacy.md](docs/privacy.md).

<p align="center">
  <img src="docs/assets/screenshot-dashboard.png" width="280" alt="Vigil Limits dashboard: a Watchline highlighting the tightest quota across accounts, then per-account cards with stacked session and weekly meter bars, percent left, and live reset countdowns" />
  &nbsp;&nbsp;
  <img src="docs/assets/screenshot-models.png" width="280" alt="Vigil Models view: every provider's per-model cap gathered into one tightest-first list — Fable weekly, Opus weekly, GPT-5.6 Sol, and MiniMax video lanes — each with percent left and a reset countdown" />
</p>

## Getting started

You don't need to be a developer to use Vigil.

1. **Install the app.** Vigil is on TestFlight (internal testing today; public beta next). Home-screen and lock-screen widgets are included.
2. **Add an account — on the phone.** Open Vigil → **Add account**:
   - **Sign in with Claude.** Tap it, approve access in the browser that opens, and paste back the code Claude shows you. Vigil gets its own token that renews itself. No computer.
   - **Sign in with Codex.** Tap it, open the sign-in page, and enter the short code Vigil shows you. Vigil detects the approval and finishes — its own renewable token, no computer, no `codex login`.
   - **Add an API-key provider.** Choose **Add a provider directly**, pick the provider (OpenRouter, DeepSeek, OpenAI, GitHub Copilot, …), and paste its key. Vigil tells you exactly which field it needs.
   - **Reuse a computer sign-in (optional).** If you already run Claude Code or Codex on a machine, `npx vigil-link` hands those sign-ins to your phone by QR.
3. **Read your dashboard.** The **Watchline** shows the single tightest limit across all your accounts with a live countdown; each account card breaks out its windows — the overall session/weekly limits and the **model-specific limits** under "Model and special limits" — plus any balances or spend.

Want the full walkthrough, including where to get each provider's API key? See **[docs/getting-started.md](docs/getting-started.md)**.

Just want to see your usage in the terminal, no install?

```sh
npx vigil-link status   # your real usage with reset countdowns, right now
npx vigil-link doctor   # check what credentials Vigil can find
```

## Features

- **Live limit tracking** for Claude and ChatGPT/Codex, with the exact **percent left** and a **client-side reset countdown** that keeps ticking between fetches.
- **Per-model limits** surfaced distinctly — Claude Opus/Sonnet weekly caps and newer model-scoped weekly limits, Codex per-model lanes, MiniMax video quota — grouped under "Model and special limits."
- **Balances, spend, and overage credits** for gateway providers (OpenRouter, DeepSeek, Moonshot, OpenAI, GitHub Copilot, and more) and Claude extra-usage credits.
- **Home-screen and lock-screen widgets** that read the shared snapshot and tick countdowns locally.
- **Threshold notifications** at 80% and 95% of a window.
- **Biometric app lock** (Face ID / Touch ID) for the app.
- **macOS menu bar** readout (`C 42% left · X 71% left`) — build from source today.
- **Honest states**: stale, cooling down, re-link needed, provider changed, offline — never a silently wrong number.
- **On-device only**: credentials in the Keychain, no server, no analytics.

## Provider support

Thirteen providers ship in the registry. Claude and ChatGPT/Codex are enabled by default; the rest are opt-in and add themselves when you provide a key.

| Provider | Type | What you see | How to connect |
|---|---|---|---|
| **Claude** | default | Session, weekly, Sonnet, Opus + model-scoped weekly caps; overage credits | **Sign in on the phone** (browser OAuth), or hand over a Claude Code sign-in from a computer |
| **ChatGPT / Codex** | default | Session, weekly, and per-model additional windows | **Sign in on the phone** (device-code flow), or hand over a Codex CLI sign-in from a computer |
| OpenRouter | opt-in | Spend, credit limit, remaining credits | `OPENROUTER_API_KEY` |
| DeepSeek | opt-in | Balance by currency | `DEEPSEEK_API_KEY` |
| Moonshot (Kimi) | opt-in | Balance | `MOONSHOT_API_KEY` |
| Moonshot (Kimi) China | opt-in | Balance | `MOONSHOT_CN_API_KEY` |
| Kimi K3 (coding plan) | opt-in · experimental | Session + weekly coding-plan windows | `KIMI_CODE_API_KEY` |
| MiniMax Coding Plan | opt-in | Session + weekly windows (general and video models) | `MINIMAX_CODING_API_KEY` |
| MiniMax Coding Plan China | opt-in | Session + weekly windows (general and video models) | `MINIMAX_CN_CODING_API_KEY` |
| OpenAI API | opt-in | Month-to-date spend | `OPENAI_ADMIN_KEY` (Admin key) |
| GitHub Copilot | opt-in | AI-credit spend | `GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER` |
| xAI API | opt-in · experimental | Prepaid balance | `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID` |
| Z.ai / GLM Coding Plan | opt-in · experimental | Session + monthly windows | `ZAI_API_KEY` |
| Cursor | opt-in · experimental | Plan usage + on-demand spend | `CURSOR_SESSION_TOKEN` (web session cookie) |

"Experimental" marks a community-proven but undocumented endpoint; it's labeled everywhere it appears. CI does not call production provider APIs — opt-in providers are validated with sanitized fixtures, not vendor-certified. Full activation notes and the researched backlog live in the [support matrix](docs/provider-spec.md#support-and-stability-matrix).

The CLI never persists credentials or usage values. It does persist poll timestamps and 429 counters under your cache directory to prevent accidental rapid polling ([ADR-0004](docs/decisions/0004-stateless-cli.md)).

## FAQ

**What's the difference between a session, weekly, and model limit?** A *session* window (Claude's 5-hour, Codex's session) resets frequently; a *weekly* window is the longer cap; a *model limit* is a separate quota a platform enforces for a specific model (e.g. Claude Opus's own weekly cap). Vigil shows all of them, each with its own reset time.

**Why does a card say "stale" or "cooling down"?** Providers rate-limit checks, so Vigil polls no faster than every ~5 minutes and tells you when the data is older than expected rather than showing a stale number as if it were live.

**Are my tokens safe?** They only ever travel between your own devices and the providers you turn on, and they live in your device Keychain. There's no Vigil server. The QR code does contain your credentials, so show it only somewhere private. See [docs/threat-model.md](docs/threat-model.md).

**Do I have to use the terminal?** No. Claude and ChatGPT/Codex both sign in right in the app (a browser approval and a short code), and every API-key provider is added by pasting a key (**Add account → Add a provider directly**). The terminal (`npx vigil-link`) is only an optional shortcut for reusing a Claude Code or Codex sign-in already on a computer.

More answers — per-provider quirks, freshness details, and setup edge cases — are in **[docs/faq.md](docs/faq.md)**. Hitting a specific problem? See **[docs/troubleshooting.md](docs/troubleshooting.md)**.

## How it works

```
┌─────────────── computer ───────────────┐        ┌──────────── iPhone / Mac ────────────┐
│  ~/.claude/.credentials.json           │        │  Vigil app (SwiftUI)                 │
│  ~/.codex/auth.json                    │        │   ├─ VigilKit                        │
│  macOS Keychain                        │  QR /  │   │   ├─ ProviderRegistry ──────────┼──▶ provider usage endpoints
│        │                               │ paste  │   │   ├─ FetchScheduler (ledger)    │
│        ▼                               │ ─────▶ │   │   ├─ Vault (Keychain)           │
│  npx vigil-link  (guided wizard)       │        │   │   ├─ SnapshotStore (App Group)  │
│   ├─ discover / mint credentials       │        │   │   └─ ThresholdEngine → notifs   │
│   ├─ live-verify against provider      │        │   └─ Widgets (read snapshots,       │
│   └─ render vigil1 QR chunks           │        │       tick countdowns client-side)  │
└────────────────────────────────────────┘        └──────────────────────────────────────┘
```

There is no Vigil server. The phone talks directly to provider endpoints with credentials handed off from your computer. See [docs/architecture.md](docs/architecture.md) for the reliability mechanisms and [docs/qr-protocol.md](docs/qr-protocol.md) for the `vigil1` handoff format.

**Cross-language lockstep:** [`protocol/providers.json`](protocol/providers.json) is the machine-readable contract for endpoints, headers, poll policy, discovery metadata, and response mappings. TypeScript and Swift consume the contract differently, and the Swift runtime hand-mirrors its constants. Adding a provider also requires credential discovery or OAuth work, fixture coverage, Swift parity constants, UI review, and documentation. See the [provider contribution guide](docs/provider-contribution.md).

## Repo map

| Path | What it is |
|---|---|
| [`protocol/`](protocol/) | The provider contract (`providers.json`) + test fixtures and QR vectors shared by every implementation |
| [`cli/`](cli/) | [`vigil-link`](https://www.npmjs.com/package/vigil-link) — the guided setup wizard, credential discovery, OAuth mint, QR handoff, `status`/`doctor` (TypeScript, Node ≥ 20) |
| [`packages/VigilKit/`](packages/VigilKit/) | Swift core: models, provider clients, fetch scheduler + shared ledger, Keychain vault, QR decoder, threshold engine, token refresher |
| [`apps/apple/`](apps/apple/) | The SwiftUI app (iOS 17 / macOS 14) + widget extension, generated by XcodeGen from `project.yml` |
| [`docs/`](docs/) | Getting started, FAQ, architecture, provider support, troubleshooting, threat model, release runbook, and decision records |

## Development

```sh
# CLI
cd cli && npm install && npm run build && npm test

# Swift core
swift test --package-path packages/VigilKit

# App (needs Xcode 16+, brew install xcodegen)
cd apps/apple && xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO

# macOS app + menu bar (build then find Vigil.app in DerivedData, or run from Xcode)
xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# App reliability tests on the macOS host
xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

CI builds and tests the CLI, runs VigilKit tests, compiles the iOS Simulator app, and runs the app reliability suite against the macOS target. The final on-device and widget walk remains a release requirement. Releasing to TestFlight is documented in [docs/release.md](docs/release.md). Project conventions for AI-assisted development live in [CLAUDE.md](CLAUDE.md).

Read [CHANGELOG.md](CHANGELOG.md) before testing an existing installation. It records the account-key, widget, and CLI cache migration notes.

## Privacy

One sentence: **Vigil sends credentials and usage requests only between your devices and the providers you activate.** It has no collection server or analytics. The precise claim, including local caches and QR risks, is in [docs/privacy.md](docs/privacy.md) and [docs/threat-model.md](docs/threat-model.md).

## Acknowledgments

- **[token-monitor](https://github.com/Javis603/token-monitor)** by Javis603 — the desktop token/limit monitor that inspired Vigil. It covers the desktop beautifully; the gap it left on mobile is exactly why Vigil exists, and its approach to per-tool, per-model limit tracking shaped how Vigil surfaces the same information on the phone.
- [`qrcode-terminal`](https://github.com/gtanner/qrcode-terminal) — Vigil's only CLI runtime dependency, used to render the `vigil1` handoff codes.

## License

[MIT](LICENSE)

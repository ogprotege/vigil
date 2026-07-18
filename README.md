<p align="center">
  <img src="docs/assets/icon-256.png" width="128" alt="Vigil app icon" />
</p>

<h1 align="center">Vigil</h1>

<p align="center"><b>Know exactly where you stand against your AI subscription limits.</b><br/>
Claude and ChatGPT/Codex session &amp; weekly windows — on your phone, your Mac's menu bar, and your terminal. No servers, ever.</p>

<p align="center">
  <a href="https://github.com/ogprotege/vigil/actions/workflows/cli.yml"><img src="https://github.com/ogprotege/vigil/actions/workflows/cli.yml/badge.svg" alt="cli CI" /></a>
  <a href="https://github.com/ogprotege/vigil/actions/workflows/apple.yml"><img src="https://github.com/ogprotege/vigil/actions/workflows/apple.yml/badge.svg" alt="apple CI" /></a>
  <a href="https://www.npmjs.com/package/vigil-link"><img src="https://img.shields.io/npm/v/vigil-link?label=vigil-link" alt="npm" /></a>
  <img src="https://img.shields.io/badge/platforms-iOS%2017%2B%20·%20macOS%2014%2B%20·%20CLI-blue" alt="platforms" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" /></a>
</p>

---

Existing token monitors look nice but go stale, throttle themselves into uselessness, or make you dig OAuth tokens out of JSON files by hand. Vigil is built around the three things that actually make a monitor trustworthy:

1. **Setup in seconds.** Run `npx vigil-link` on your computer, scan a QR with your phone, done. No accounts, no cloud, no copy-pasting tokens (unless you want to — paste and manual entry work too).
2. **Honest freshness.** Provider endpoints rate-limit hard (Claude 429-jails anything polling faster than ~5 minutes). Every fetch — app, widget, menu bar, background — draws from one shared polling ledger, and reset countdowns tick client-side so the UI is live between fetches. When data is stale or a provider changes something, Vigil says so instead of silently lying.
3. **On-device only.** Credentials live in your device Keychain and nowhere else. No servers, no analytics, nothing phones home. See [docs/privacy.md](docs/privacy.md).

<p align="center">
  <img src="docs/assets/screenshot-dashboard.png" width="280" alt="Dashboard: session ring, weekly bar, model limits, staleness tint" />
  &nbsp;&nbsp;
  <img src="docs/assets/screenshot-empty.png" width="280" alt="Empty state before linking an account" />
</p>

## Get Vigil

| Surface | How |
|---|---|
| **iPhone** | TestFlight (internal testing today; public beta next). Home-screen and lock-screen widgets included. |
| **Terminal** | `npx vigil-link status` — your real usage with reset countdowns, right now, no install. |
| **macOS menu bar** | `C 42% · X 71%` always in view. Build from source today (the macOS `xcodebuild` line under [Development](#development)); distribution is on the roadmap. |

```sh
npx vigil-link status   # see your Claude / Codex usage in the terminal
npx vigil-link doctor   # check what credentials Vigil can find
npx vigil-link          # link your accounts to the app via QR
```

`vigil-link` finds the sign-ins your existing tools already created (Claude Code, Codex CLI), or mints Vigil its own token pair via browser OAuth so token refreshes never fight your other tools (ADR-0005). It is stateless: it never writes anything to disk (ADR-0004).

## How it works

```
┌─────────────── computer ───────────────┐        ┌──────────── iPhone / Mac ────────────┐
│  ~/.claude/.credentials.json           │        │  Vigil app (SwiftUI)                 │
│  ~/.codex/auth.json                    │        │   ├─ VigilKit                        │
│  macOS Keychain                        │  QR /  │   │   ├─ ProviderRegistry ──────────┼──▶ provider usage endpoints
│        │                               │ paste  │   │   ├─ FetchScheduler (ledger)    │
│        ▼                               │ ─────▶ │   │   ├─ Vault (Keychain)           │
│  npx vigil-link                        │        │   │   ├─ SnapshotStore (App Group)  │
│   ├─ discover / mint credentials       │        │   │   └─ ThresholdEngine → notifs   │
│   ├─ live-verify against provider      │        │   └─ Widgets (read snapshots,       │
│   └─ render vigil1 QR chunks           │        │       tick countdowns client-side)  │
└────────────────────────────────────────┘        └──────────────────────────────────────┘
```

There is no Vigil server. The phone talks directly to provider endpoints with credentials handed off from your computer — see [docs/architecture.md](docs/architecture.md) for the reliability mechanisms and [docs/qr-protocol.md](docs/qr-protocol.md) for the `vigil1` handoff format.

**Cross-language lockstep:** [`protocol/providers.json`](protocol/providers.json) is the single machine-readable contract — endpoints, headers, poll policy, response mappings. The TypeScript CLI and Swift VigilKit each implement a thin mapper over it, and CI holds both to the same fixtures and QR test vectors. Adding a provider is a registry entry, two fixtures, and two small mappers — see [docs/provider-spec.md](docs/provider-spec.md).

## Repo map

| Path | What it is |
|---|---|
| [`protocol/`](protocol/) | The provider contract (`providers.json`) + test fixtures and QR vectors shared by every implementation |
| [`cli/`](cli/) | [`vigil-link`](https://www.npmjs.com/package/vigil-link) — credential discovery, OAuth mint, QR handoff, `status`/`doctor` (TypeScript, Node ≥ 20) |
| [`packages/VigilKit/`](packages/VigilKit/) | Swift core: models, provider clients, fetch scheduler + shared ledger, Keychain vault, QR decoder, threshold engine, token refresher |
| [`apps/apple/`](apps/apple/) | The SwiftUI app (iOS 17 / macOS 14) + widget extension, generated by XcodeGen from `project.yml` |
| [`docs/`](docs/) | Architecture, provider spec, QR protocol, privacy, release runbook, decision records (ADRs) |

## Development

```sh
# CLI
cd cli && npm install && npm run build && npm test        # 60 tests

# Swift core
swift test --package-path packages/VigilKit               # 35 tests

# App (needs Xcode 16+, brew install xcodegen)
cd apps/apple && xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO

# macOS app + menu bar (build then find Vigil.app in DerivedData, or run from Xcode)
xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

CI runs all three on every push (`cli.yml`, `apple.yml`). Releasing to TestFlight is documented in [docs/release.md](docs/release.md). Project conventions for AI-assisted development live in [CLAUDE.md](CLAUDE.md).

## Status

| Milestone | State |
|---|---|
| M1–M3 · Provider contract, `vigil-link` CLI, VigilKit core | ✅ shipped (`vigil-link@0.1.1` on npm) |
| M4 · iOS app — onboarding, dashboard, settings | ✅ built, in TestFlight |
| M5 · Home-screen + lock-screen widgets | ✅ built, in TestFlight |
| M6 · 80/95% threshold notifications, background refresh, app icon | ✅ built, in TestFlight |
| M7 · macOS menu bar | ✅ built (source) |
| M8 · TestFlight | ✅ build 0.9.0 in internal testing |
| On-device validation walk | ⏳ [docs/mac-checklist.md](docs/mac-checklist.md) |
| v1.1 | Live Activity · encrypted QR (`vigil1e`) · Codex refresh · API-spend tier · more providers (Copilot, Kimi, Qwen, Hugging Face) — see the [expansion map](docs/provider-spec.md) |

## Privacy

One sentence: **your credentials and usage data never leave your devices.** The full model — and why the App Store privacy label is truthfully "Data Not Collected" — is in [docs/privacy.md](docs/privacy.md).

## License

[MIT](LICENSE)

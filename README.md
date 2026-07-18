# Vigil

**A reliable AI usage monitor.** Know exactly where you stand against your Claude and ChatGPT/Codex subscription limits — session and weekly windows, live reset countdowns — without maxing out mid-task and without a painful setup.

## Why

Existing token monitors look nice but go stale, throttle themselves into uselessness, or make you dig OAuth tokens out of JSON files by hand. Vigil is built around the three things that actually make a monitor trustworthy:

1. **Setup in seconds** — run `npx vigil-link` on your computer, scan a QR with your phone, done. No accounts, no cloud, no copy-pasting tokens (unless you want to).
2. **Honest freshness** — provider endpoints rate-limit hard (Claude 429-jails anything polling faster than ~5 minutes). Vigil respects that budget with a shared polling ledger, and keeps countdowns ticking client-side from known reset times so the UI is live even between fetches. When data is stale or a provider changes something, Vigil says so instead of silently lying.
3. **On-device only** — credentials live in your device Keychain and nowhere else. No servers, no analytics, nothing phones home. See [docs/privacy.md](docs/privacy.md).

## Repo map

| Path | What it is |
|---|---|
| `protocol/` | The machine-readable provider contract: endpoints, headers, poll policy, response mappings (`providers.json`), plus test fixtures and QR test vectors shared by every implementation |
| `cli/` | `vigil-link` — the companion CLI (TypeScript, Node ≥20): credential discovery, OAuth mint, QR handoff, `status`/`doctor` |
| `packages/VigilKit/` | Swift core shared by the iOS/macOS app: models, provider clients, fetch scheduler, Keychain vault, QR decoder |
| `apps/apple/` | The SwiftUI app + widgets (XcodeGen project; UI lands in the next milestone) |
| `docs/` | Architecture, provider spec, QR protocol, privacy, Mac build checklist, decision records |

## Status

Early. This pass ships the foundation: the provider contract, the fully-tested CLI, and the VigilKit Swift core with CI. The iOS app UI is the next milestone — see [docs/mac-checklist.md](docs/mac-checklist.md) for the build-and-smoke path.

Try the CLI today:

```sh
npx vigil-link status   # see your Claude / Codex usage in the terminal
npx vigil-link doctor   # check what credentials Vigil can find
npx vigil-link          # link your accounts to the app via QR
```

## Platform roadmap

iOS → macOS (menu bar) → Android → Windows/Linux. All clients implement the same `protocol/` contract.

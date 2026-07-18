# Mac-side build & smoke checklist

This session's work is authored on Linux; Swift is compile-checked by the macOS CI workflow but the real-credential smoke tests need your Mac. Work through these in order.

## After this pass (foundation smoke — no Xcode needed)

1. **CLI live test** — on your Mac (or any machine with Claude Code / Codex installed):
   ```sh
   cd cli && npm install && npm run build
   node dist/index.js doctor          # should find your ~/.claude / ~/.codex credentials
   node dist/index.js status          # should print your real session/weekly percentages
   ```
   `status` working proves the endpoint recipes (headers, User-Agent, response mapping) hold against production from a residential IP.
2. **QR scannability** — run `node dist/index.js --copy --no-clear`, and point your iPhone **stock camera** at each QR. The camera will offer the decoded text (no app exists yet — you just want to see it recognizes the code instantly). If codes don't lock on quickly, we shrink chunk size before the app milestone.
3. **Mint flow** — run `node dist/index.js --mint --provider claude`. Browser opens → approve → CLI should print "verified". This validates the redirect-URI/scope assumptions (ADR-0005 lists the fallbacks if it doesn't).
4. **npm publish (one-time)** — `cd cli && npm publish` (requires your npm login) to reserve the `vigil-link` name.

## M4 — App onboarding + dashboard (next session)

5. `brew install xcodegen`
6. `cd apps/apple && xcodegen generate && open Vigil.xcodeproj`
7. Set your signing team; run on device.
8. Add Account → "Scan from computer" → `npx vigil-link` on the Mac → scan → live verify succeeds → dashboard shows real percentages.
9. Kill/relaunch the app: percentages render instantly from the stored snapshot.
10. Airplane mode: staleness tint + "last updated" appear; countdown keeps ticking.
11. Remove account → re-add prompts fresh (Keychain actually cleared).

## M5 — Widgets

12. Add the small home-screen widget + circular lock-screen widget; confirm the countdown ticks with the app killed.
13. After a reset boundary passes, the widget shows the window at ~0% before the next fetch corrects it.
14. In Console.app, filter the Vigil subsystem: confirm app + widget never fetch inside the same min-poll window (shared ledger working).

## M6 — Notifications + background refresh

15. Debug menu → "simulate 79→81%" fires the 80% notification.
16. Overnight test: at least one background-refresh snapshot update lands without opening the app.

## M7 — macOS

17. Menu bar percentages update while the app has no windows open.

## Notes

- **CI minutes:** the `apple.yml` workflow uses macOS runners — free on public repos, billed at 10× minutes on private ones. If this repo stays private, keep an eye on the Actions usage page.
- If Anthropic/OpenAI change an endpoint, fixtures + `providers.json` are the only things to update — see docs/provider-spec.md "Adding a provider".

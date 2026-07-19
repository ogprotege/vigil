# Mac-side build & smoke checklist

> **Status (2026-07-18):** steps 1–4 below are ✅ done (foundation validated
> live, `vigil-link@0.1.1` published). M4–M7 are built and M8 shipped —
> build 0.9.0 (1) is in TestFlight internal testing (see
> [release.md](release.md)). **The remaining work is steps 5–17: the
> on-device walk**, starting by installing Vigil from the TestFlight app
> instead of a tethered Xcode run.

## After this pass (foundation smoke — no Xcode needed)

1. **CLI live test** — on your Mac (or any machine with Claude Code / Codex installed):
   ```sh
   cd cli && npm install && npm run build
   node dist/index.js doctor          # should find your ~/.claude / ~/.codex credentials
   node dist/index.js status          # should print your real session/weekly percentages
   ```
   `status` working proves the endpoint recipes (headers, User-Agent, response mapping) hold against production from a residential IP.
   A second immediate live command can be locally deferred. This is the CLI
   poll gate working, not a provider failure.
1a. **Optional gateway live test:** use dedicated, restricted keys:
   ```sh
   OPENROUTER_API_KEY='...' node dist/index.js doctor --provider openrouter --live
   OPENROUTER_API_KEY='...' node dist/index.js status --provider openrouter
   DEEPSEEK_API_KEY='...' node dist/index.js doctor --provider deepseek --live
   DEEPSEEK_API_KEY='...' node dist/index.js status --provider deepseek
   ```
   Confirm spend, limit, remaining credit, and currency balances are labeled
   as scalar values. Vigil must not fabricate utilization or reset times.
2. **QR scannability** — run `node dist/index.js --copy --no-clear`, and point your iPhone **stock camera** at each QR: it should lock on instantly. (Done 2026-07-18. Bonus discovered: single-chunk codes carry the registered `vigil1:` URL scheme, so with the app installed the stock camera deep-links straight into Vigil.)
3. **Mint flow** — run `node dist/index.js --mint --provider claude`. Browser opens → approve → CLI should print "verified". This validates the redirect-URI/scope assumptions (ADR-0005 lists the fallbacks if it doesn't).
4. **npm publish (one-time)** — `cd cli && npm publish` (requires your npm login) to reserve the `vigil-link` name.

## M4 — App onboarding + dashboard (the on-device walk)

5. Install **TestFlight** on your iPhone, sign in with the team Apple ID, and install Vigil from the Internal group (see [release.md](release.md)). *(A tethered Xcode run also works, but requires registering the device first — the team's signing is manual distribution because it has no registered devices; see release.md.)*
6. — merged into step 5 —
7. — merged into step 5 —
8. Add Account → "Scan from computer" → `npx vigil-link` on the Mac → scan → live verify succeeds → dashboard shows real percentages.
9. Kill/relaunch the app: percentages render instantly from the stored snapshot.
10. Airplane mode: staleness tint + "last updated" appear; countdown keeps ticking.
11. Remove account → re-add prompts fresh (Keychain actually cleared).

## M5 — Widgets

12. Add the small home-screen widget + circular lock-screen widget. Edit each
    widget and choose a linked account. Confirm two widgets can remain pinned
    to two different accounts and the countdown ticks with the app killed.
13. After a reset boundary passes, the widget shows the window at ~0% before the next fetch corrects it.
14. In Console.app, filter the Vigil subsystem: confirm app + widget never fetch inside the same min-poll window (shared ledger working).

## M6 — Notifications + background refresh

15. Debug menu → "simulate 79→81%" fires the 80% notification.
16. Overnight test: at least one background-refresh snapshot update lands without opening the app.

## M7 — macOS

17. Menu bar percentages update while the app has no windows open.

## Notes

- **CI minutes:** the `apple.yml` workflow uses macOS runners — free on public repos, billed at 10× minutes on private ones. If this repo stays private, keep an eye on the Actions usage page.
- The current Apple workflow tests VigilKit, builds the iOS Simulator app, and
  runs the dedicated app reliability suite against macOS. Device-only
  Keychain, camera, background-task, notification, and WidgetKit scheduling
  behavior still requires this checklist.
- If a provider changes an endpoint or response, follow
  [provider-contribution.md](provider-contribution.md). Registry data and
  fixtures may not be sufficient.

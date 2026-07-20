# Local next steps

> Historical note: this file began as the Mac-side runbook for validating the
> foundation. Everything in it through M8 was executed and is now history —
> kept below only as a status ledger. The living documents are
> [mac-checklist.md](mac-checklist.md) (on-device validation walk) and
> [release.md](release.md) (cutting TestFlight builds).

## Where things stand (2026-07-18)

| Phase | Outcome |
|---|---|
| Phase 0 · Mac setup | ✅ Xcode, XcodeGen, Node installed |
| Phase 1 · Foundation validation with real credentials | ✅ `doctor`/`status` verified against production; QR scannability confirmed with a stock iPhone camera; the Claude mint flow was live-debugged (undocumented `code=true` and verifier-as-`state` requirements, plus the full registered scope set — see docs/provider-spec.md) and verified end-to-end; `vigil-link@0.1.1` published to npm |
| Phase 2 · Swift core on the Mac | ✅ `swift test` green; project generation validated |
| Phase 3 · M4 app | ✅ built, adversarially reviewed, in TestFlight |
| Phase 4 · M5 widgets, M6 notifications/background/icon, M7 menu bar | ✅ built (menu bar ships with the macOS build from source) |
| M8 · TestFlight | ✅ build 0.9.0 (1) in internal testing — process captured in [release.md](release.md) |
| Reliability remediation | ✅ cross-process leases, CLI poll gate/timeouts, persistence alerts, account identity fix, future-link bound |
| Provider expansion | ✅ 13-provider registry shipped — the six stable opt-in gateways (OpenRouter, DeepSeek, Moonshot/CN, MiniMax/CN, OpenAI, GitHub) and three experimental (xAI, Z.ai, Cursor) alongside default Claude and Codex; live release validation still required |

## What actually remains

1. **The on-device walk** — [mac-checklist.md](mac-checklist.md) §M4 steps
   5–11 through §M7 step 17: install from TestFlight, then verify the on-phone
   **Sign in with Claude** and **Sign in with Codex** flows against a real
   account (browser / device-code approval → on-device mint → live verify with
   real percentages); the `npx vigil-link` + scan computer handoff is an
   optional secondary path. Then kill/relaunch, airplane mode, widget ledger
   verification in Console.app, the 79→81% debug notification, overnight
   background refresh, menu bar freshness.
2. **External TestFlight / App Store** — screenshots, listing copy, Beta App
   Review ([release.md](release.md) § Not yet wired).
3. **Provider release validation:** run every opt-in provider against dedicated
   test keys — the six stable gateways (OpenRouter, DeepSeek, Moonshot with its
   China region, MiniMax with its China region, OpenAI, GitHub) and the three
   experimental ones (xAI, Z.ai, Cursor) — confirm scalar rendering on every
   intended surface, and record the result in the support matrix.
4. **Release-only validation:** keep the dedicated iOS and macOS app
   reliability suite green, then complete the device-only Keychain, camera,
   background-task, notification, and WidgetKit checks before each release.
5. **Later product work:** Live Activity and the encrypted QR variant
   (`vigil1e`).

## Standing gotchas (unchanged)

- **Never poll Claude faster than 5 min.** Apple surfaces use locked leases
  and the CLI uses a timestamp-only safety cache. Don't
  "fix" slowness by lowering `minSeconds`. That 429 jail is what breaks the
  monitor apps this project replaces.
- **If a provider changes their response**: the app degrades to "provider
  changed" instead of lying. A fix may require registry, adapter, mapper,
  fixture, Swift parity, UI, and documentation changes. Follow
  [provider-contribution.md](provider-contribution.md).
- **Never copy-refresh another CLI's token** — only pairs marked
  `src:"mint"` in the link payload are refreshable (ADR-0005).
- **macOS CI minutes** are free only while the repo is public.

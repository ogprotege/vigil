# Local next steps

> Historical note: this file began as the Mac-side runbook for validating the
> foundation. Everything in it through M8 was executed and is now history —
> kept below only as a status ledger. The living documents are
> [mac-checklist.md](mac-checklist.md) (on-device validation walk) and
> [release.md](release.md) (cutting TestFlight builds).

## Where things stand (2026-07-22)

| Phase | Outcome |
|---|---|
| Phase 0 · Mac setup | ✅ Xcode, XcodeGen, Node installed |
| Phase 1 · Foundation validation with real credentials | ✅ `doctor`/`status` verified against production; QR scannability confirmed with a stock iPhone camera; the Claude mint flow was live-debugged (undocumented `code=true` and verifier-as-`state` requirements, plus the full registered scope set — see docs/provider-spec.md) and verified end-to-end; `vigil-link@0.1.1` published to npm |
| Phase 2 · Swift core on the Mac | ✅ `swift test` green; project generation validated |
| Phase 3 · M4 app | ✅ built, adversarially reviewed, in TestFlight |
| Phase 4 · M5 widgets, M6 notifications/background/icon, M7 menu bar | ✅ built (menu bar ships with the macOS build from source) |
| M8 · TestFlight | ✅ build 0.13.0 (13) uploaded successfully on 2026-07-22 and processing for the Internal group — process captured in [release.md](release.md) |
| Reliability remediation | ✅ cross-process leases, CLI poll gate/timeouts, persistence alerts, account identity fix, future-link bound |
| Provider expansion | ✅ 14-provider registry shipped. Claude and Codex use on-device sign-in. Vendor-documented opt-in providers and five experimental providers (MiniMax/CN, Z.ai, Cursor, Kimi K3) carry explicit fixture provenance and required-output drift checks. Live validation remains provider-specific. |

## What actually remains

1. **The remaining on-device walk** — Claude and Codex on-device sign-in were
   completed against real accounts on 2026-07-22. Repeat both sign-ins on
   build 13 to validate the corrected provider contracts, then continue
   [mac-checklist.md](mac-checklist.md) with persistence, airplane mode, widget
   ledger verification in Console.app, the 79→81% debug notification,
   overnight background refresh, and menu-bar freshness. The `npx vigil-link`
   QR handoff remains an optional secondary path.
2. **External TestFlight / App Store** — screenshots, listing copy, Beta App
   Review ([release.md](release.md) § Not yet wired).
3. **Provider release validation:** run each opt-in provider against a dedicated
   test credential when available. Confirm rendering on every intended surface
   and promote a fixture to `live_sanitized` only after preserving a sanitized
   production body in the provenance manifest. The experimental set is
   MiniMax/CN, Z.ai, Cursor, and Kimi K3. Moonshot global/China and xAI are
   vendor-documented.
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

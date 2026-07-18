# Local next steps (Mac terminal + Claude Code)

The foundation (provider contract, `vigil-link` CLI, VigilKit Swift core, CI) is merged and green. Everything that remains needs a real Mac: validating against real credentials from a residential IP, reserving the npm name, and building the app UI (M4+). Work through the phases in order — each is one sitting.

---

## Phase 0 — One-time Mac setup (~15 min, mostly downloads)

```sh
# 1. Xcode (App Store) — needed from M4 on; not for Phase 1
xcode-select --install                      # command-line tools if you don't have them

# 2. Homebrew + XcodeGen (generates the Xcode project from apps/apple/project.yml — ADR-0002)
brew install xcodegen

# 3. Node 20+ (check first: node --version)
brew install node

# 4. Clone
git clone https://github.com/ogprotege/vigil.git && cd vigil
```

## Phase 1 — Validate the foundation with REAL credentials (~10 min, no Xcode needed)

The highest-value session: it tests the four assumptions that could not be verified from a cloud container.

```sh
cd cli
npm install && npm run build && npm test    # expect 57/57 green locally

# 1. Credential discovery — should find your ~/.claude and ~/.codex sign-ins
node dist/index.js doctor

# 2. THE big validation — real usage from production endpoints, residential IP
node dist/index.js status
#    Success looks like: your actual session/weekly % with reset countdowns.
#    If Claude returns rateLimited: normal, wait 5 min (shared budget with Claude Code itself).

# 3. QR optical test — point your iPhone STOCK CAMERA at each QR
node dist/index.js --copy --no-verify --no-clear
#    You only need the camera to LOCK ON quickly and offer the decoded text
#    (no app exists yet). Sluggish lock-on => lower MAX_CHUNK in
#    cli/src/qr/payload.ts and regenerate vectors (npm run gen-vectors).

# 4. Mint flow — validates ADR-0005's OAuth assumptions (redirect URI, scope)
node dist/index.js --mint --provider claude --no-clear
#    Browser opens -> approve -> "verified". If it fails, NOTE THE ERROR —
#    the fix is a one-line change in protocol/providers.json (oauth.scopes or
#    loopback port). The manual-paste and --copy fallbacks should kick in.

# 5. Reserve the npm name (one-time, needs your npm account)
npm login
npm publish                                  # publishes vigil-link@0.1.0
#    After this, `npx vigil-link status` works for anyone, anywhere.
```

Feed anything that failed back to Claude Code locally — every failure in this phase is a small config/data fix (`protocol/providers.json` + fixtures), not an architecture change.

## Phase 2 — Prove the Swift core on your Mac (~5 min)

```sh
swift test --package-path packages/VigilKit  # same 29 tests CI ran; now local
cd apps/apple && xcodegen generate           # validates the manifest stub; creates Vigil.xcodeproj
```

## Phase 3 — M4: build the iOS app with local Claude Code

> **Status (2026-07-18):** M4–M7 code is implemented and building for iOS +
> macOS (`apps/apple/`), including widgets, threshold notifications,
> BGAppRefreshTask, app icon, menu bar, and 401→refresh for minted tokens.
> What remains is the on-device walk below (§M4 steps 5–11, §M5–M7 smoke) and
> M8.

Start a Claude Code session **at the repo root** and paste:

```
Read docs/architecture.md, docs/provider-spec.md, docs/qr-protocol.md,
docs/mac-checklist.md and apps/apple/project.yml. Implement milestone M4:

1. Fill in apps/apple/project.yml: a multiplatform SwiftUI app target "Vigil"
   (iOS 17 / macOS 14) depending on the local VigilKit package, with an App
   Group (group.app.vigil.shared), a shared Keychain access group, camera
   usage description (QR scanning), and Face ID usage description.
2. Onboarding: Add Account with three paths, easiest first — (a) "Scan from
   your computer" showing the copyable `npx vigil-link` command + camera sheet
   with chunk progress ("captured 2 of 3", any order, sid-validated) using
   VigilKit's QRDecoder; (b) paste-code field; (c) manual token entry form.
   On success: live verify via UsageClient, store in KeychainCredentialsStore,
   then show the dashboard.
3. Dashboard: one card per account — plan label, session gauge, weekly bar(s)
   (sonnet/opus behind a disclosure), reset countdown via
   Text(timerInterval:) so it ticks without network, last-updated staleness
   tint, and honest error states (rateLimited shows "next check at HH:MM"
   from FetchScheduler.nextAllowedFetch; authExpired shows a re-link CTA;
   schemaChanged says "provider changed, check for updates").
4. Refresh: all fetches go through FetchScheduler (App Group ledger dir) —
   on-appear, timer while frontmost, pull-to-refresh (ledger-gated).
5. Settings: manage/remove accounts (Keychain delete), Face ID app lock
   toggle, privacy page quoting docs/privacy.md. System light/dark only.
Keep VigilKit UI-free. Run swift test and build for iOS simulator to verify.
```

Then walk `docs/mac-checklist.md` §M4 (steps 5–11): run on your device, link via `npx vigil-link` + scan, kill/relaunch (snapshot persistence), airplane mode (staleness honesty), remove account.

**Git workflow on your Mac:** branch from latest `main` for each milestone (`git checkout -b m4-app-ui origin/main`), push, PR — CI (cli + apple workflows) gates every push.

## Phase 4 — Remaining milestones

| Milestone | What | Checklist |
|---|---|---|
| M5 | Home-screen + lock-screen widgets, shared-ledger verification in Console.app | §M5 (steps 12–14) |
| M6 | 80/95% threshold notifications (ThresholdEngine is ready), BGAppRefreshTask, Face ID polish, app icon | §M6 (steps 15–16) |
| M7 | macOS menu bar (MenuBarExtra "C 42% · X 71%"), timer-driven refresh — the always-fresh surface | §M7 (step 17) |
| M8 | TestFlight, "Data Not Collected" privacy label, vigil-link 1.0.0 | §M8 |
| v1.1 | Live Activity, encrypted QR (vigil1e), Codex refresh, API-spend Tier A (OpenRouter/DeepSeek/Fireworks/Moonshot), providers: Copilot, Kimi, Qwen, Hugging Face | docs/provider-spec.md expansion map |

## Standing gotchas

- **Never poll Claude faster than 5 min** — the scheduler enforces it; don't "fix" slowness by lowering `minSeconds`. That 429 jail is what breaks the monitor apps this project replaces.
- **Repo visibility**: macOS CI minutes are free only while the repo is public; private repos bill them at 10×.
- **If a provider changes their response**: the app degrades to "provider changed" instead of lying; the fix is `protocol/providers.json` + new fixtures + the two thin mappers — see "Adding a provider" in docs/provider-spec.md.
- **Never copy-refresh Claude Code's own token** — file-sourced creds intentionally don't auto-refresh (ADR-0005); mint is the path.

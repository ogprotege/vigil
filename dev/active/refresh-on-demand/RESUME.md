# RESUME: Fix refresh — on-demand pull, 60s floor, aggressive background

**Paste this into the fresh session to resume:**

> Resume the refresh fix. Read `dev/active/refresh-on-demand/RESUME.md` in full first — it has the root-cause analysis, the decisions I already made, and the step-by-step implementation plan. Continue from the "Next step" line in the Progress section.

## Task (user's words)

Refresh isn't on demand. Pull-to-refresh is refused by a strict built-in 5-minute limit, nothing refreshes unless the app is literally open, and accounts fall far behind. Fix the logic and build.

## Decisions ALREADY CONFIRMED with the user (do not re-ask)

1. **Manual pull = fully on-demand.** A pull always fetches live. Still refused ONLY while (a) another fetch is literally in flight (active lease, any process), or (b) a provider 429 backoff is still active (`consecutive429 > 0` and `now < nextAllowedAt`). Those two protections stay.
2. **Automatic interval = 60 seconds.** Change every provider `PollPolicy.minSeconds` from 300 → 60 (jitter stays 60). Applies to foreground timer, BG task, widget.
3. **Background = ask aggressively.** Widget staleness threshold 30 min → 5 min; BGAppRefreshTask `earliestBeginDate` 30 min → 15 min. Be candid in docs/summary that iOS still ultimately decides when background work runs — no app can force it.

## Root cause (investigation complete)

- Every fetch surface (pull, 60s foreground timer, bgtask, widget) funnels through `FetchScheduler.acquireLease(accountKey:policy:)`, which refuses until `entry.nextAllowedAt`. After each fetch, `recordResult` charges `nextAllowedAt = now + minSeconds + jitter(0..60)`.
- All provider specs set `minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600`:
  - `packages/VigilKit/Sources/VigilKit/Providers/ProviderSpec.swift` — 5 occurrences (lines ~684, 747, 835, 874, 894).
  - `protocol/providers.json` — 14 occurrences (`"minSeconds": 300`). SpecParityTests compares Swift specs against this JSON, so BOTH must change together.
- `packages/VigilKit/Tests/VigilKitTests/SpecParityTests.swift:522-530` hard-codes `claude.poll.minSeconds == 300` and asserts every `spec.poll.minSeconds >= 300` — must be updated to 60.
- Pull path: `apps/apple/Vigil/Dashboard/DashboardView.swift:203-214` `refresh()` → `AppModel.refreshAll(surface: "pull")` (`apps/apple/Vigil/AppModel.swift:1947`) → per-account `refresh(account:surface:)` (line 2004) → `UsageService.refresh(...)` (`apps/apple/Vigil/Support/UsageService.swift`) → `schedulerAcquire` (line 683) → guarded `acquireLease`.
- Widget only attempts a fetch when snapshot age > `staleAfter = 30 * 60` (`apps/apple/VigilWidgets/UsageTimelineProvider.swift:89`).
- BG task: `apps/apple/Vigil/Background/BackgroundRefresh.swift:27` `earliestBeginDate = now + 30*60`; scheduled on `.background` in `apps/apple/Vigil/VigilApp.swift:134`; handler re-chains via `schedule()`.
- Refusal UX copy lives in `AppModel.RefreshReport.userMessage` (`AppModel.swift:1920-1940`): "waiting on poll floor" / "Providers were checked recently. Next safe refresh …". Only DashboardView displays `userMessage`, and only after pulls — after the change, pull deferrals mean only backoff/in-flight, so adjust wording accordingly (check `apps/apple/VigilTests/SurfaceHonestyTests.swift` and `AppModelReliabilityTests.swift` for assertions on these strings/behaviors before editing copy).

## Implementation plan

1. **`FetchScheduler.swift`** (packages/VigilKit/Sources/VigilKit/Scheduler/): add `bypassingPollFloor: Bool = false` param to `acquireLease` (plain + lifecycle-guarded variant at ~line 382; also `acquire` if needed by callers). When true, inside the locked `store.update`: refuse only if an unexpired `leaseExpiresAt` exists, or `entry.consecutive429 > 0 && acquiredAt < entry.nextAllowedAt`; otherwise acquire. Default false keeps all existing call sites/behavior. Do NOT change leaseDuration (300) or `recordResult`/`chargeFloor` semantics — after a manual fetch the normal (now 60s) floor is charged, which is correct.
2. **`UsageService.refresh`**: add `bypassPollFloor: Bool = false` param, thread through to `schedulerAcquire` → guarded `acquireLease`.
3. **`AppModel`**: `refreshAll(surface:)` and private `refresh(account:surface:)` take `bypassPollFloor: Bool = false` and pass it down; **`DashboardView.refresh()`** passes `bypassPollFloor: true`. Timer ("timer"), bgtask, widget, verify paths keep false.
4. **Poll floor 300 → 60**: all 5 spots in `ProviderSpec.swift` + all 14 in `protocol/providers.json`. Keep jitter 60.
5. **Background hints**: `UsageTimelineProvider.staleAfter` → `5 * 60` (also fix the doc comment at lines 82-86 mentioning 30 minutes); `BackgroundRefresh.schedule()` earliestBeginDate → `15 * 60`.
6. **Copy**: update `RefreshReport.userMessage` deferred wording (deferral now means rate-limit backoff or in-flight fetch, not "checked recently") — but first grep VigilTests for the old strings and update tests in the same pass.
7. **Tests**: add SchedulerTests cases — manual acquire allowed on ordinary floor; refused on active lease; refused on active 429 backoff; allowed again after backoff expiry; floor still charged after manual fetch. Update `SpecParityTests` 300 → 60 (both the claude equality and the >= invariant).
8. **Docs** (project convention: keep docs accurate with behavior): `docs/product-contract.md:58` (five-minute floor sentence), `docs/providers/support-matrix.md:9` ("300-second minimum polling interval" — also mention manual refresh is on-demand), `docs/threat-model.md:135` ("same five-minute period"). NOTE `docs/threat-model.md:79` "Manual refresh cannot bypass an active lease or backoff" REMAINS TRUE — keep. Check `docs/architecture.md` for a fetch-triggers section (code comments reference it) and update if present. Add CHANGELOG.md entry per existing format.
9. **Verify**: `swift test` in `packages/VigilKit`; then build/test the iOS app (Xcode project via project.yml/XcodeGen — check how CI/scripts do it; `scripts/verify-ios-archive.sh` exists; user-scope skill `ios-debugger-agent` has the repo's XcodeBuildMCP workflow). Manual sanity: pull-to-refresh fetches live twice in a row; accounts update ~every 1–2 min with app open.

## Progress

- [x] Root-cause investigation
- [x] User decisions (3/3 confirmed above)
- [x] All implementation steps 1–8 complete (scheduler bypass, UsageService/AppModel/DashboardView threading, floor 300→60 in ProviderSpec + providers.json, widget 5-min staleness + timeline bound, BGTask 15-min hint, userMessage copy, SchedulerTests + SpecParityTests + RefreshReportTests + CLAUDE.md invariant, docs + CHANGELOG)
- [x] VigilKit `swift test` — 196 tests, 0 failures (2 skipped, pre-existing)
- [x] `scripts/check-docs.sh` — passed
- [x] iOS app build + simulator test run — BUILD SUCCEEDED, TEST SUCCEEDED (2026-07-28)
- [x] Final user summary

**COMPLETE.** No git commits were made; the diff is in the working tree for review.

## Cautions

- Do not touch git (no commits) unless the user asks.
- The ledger/`FetchScheduler` design is deliberate fail-closed, cross-process (app + widget share `fetch-ledger.json` in the App Group). Preserve: single-flight leases, 429 backoff ladder, ledger failure = fail closed + surface storage error. Only the min-interval floor becomes bypassable for user-initiated pulls.
- `leaseDuration` stays 300s; `crashRecoveryFloor = max(leaseDuration, minSeconds)` is unaffected by lowering minSeconds to 60.
- iOS background execution can only be requested, never guaranteed — keep all docs honest about that.

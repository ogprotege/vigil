# Vigil iOS implementation code review

> Superseded by `vigil-ios-release-0.15-code-review.md`, which reviews the
> completed history UI, full recovery reset, widget identity migration,
> notification delivery barrier, legacy network-cache cleanup, and build 16
> release gate.

Last updated: 2026-07-26

## Executive summary

Decision: **approve the current implementation as a release candidate**.

No unresolved code release blocker remains in the reviewed diff. The two original critical defects are fixed, all five important implementation findings are resolved, the dead Anthropic Admin surface is gone, the navigation and current user documentation match the iPhone product, and the committed unsigned iOS test gate passes.

Vigil now implements the narrower product truthfully:

- Home answers which linked AI limit needs attention next.
- Account detail owns full windows, balances, model caps, source notes, observed history, and official provider records.
- Every accepted current reading can enter normalized on-device history.
- OpenAI Admin import is limited to API completion tokens and organization costs. It is not labeled as ChatGPT or Codex subscription history.
- Subscription and plan labels provide context, but Vigil does not invent a token or message denominator when the provider returned only utilization and reset data.
- Diagnostic JSON is credential-free by construction rather than by a finite secret regex list.

This approval is based on static review, deterministic tests, simulator UI tests, and the current official OpenAI schema. It does not replace signed-device checks for App Group sharing, widgets, notifications, provider authentication, or opportunistic iOS background execution.

## Release blockers

**None found in the current diff.**

## Final finding matrix

| Finding | Final status | Evidence |
|---|---|---|
| CRIT-001, removal races with app and widget writers | Resolved | Shared lifecycle generations and tombstones guard credentials, snapshots, normalized history, pending events, and poll-ledger mutations. Deterministic app and second-store widget-style races pass. |
| CRIT-002, Re-link creates a second account | Resolved | Re-link now targets the selected account, preserves its Vigil key, verifies provider identity, rotates lifecycle generation, and replaces credentials transactionally. Claude, token-provider, Codex, mismatch, removal-race, and index-race tests pass. |
| IMP-001, optional OpenAI completion counters | Resolved | Optional additive counters decode as zero. Fixtures cover each omission and the newer token breakdown shape. |
| IMP-002, OpenAI import scope overstated | Resolved | Code, account detail, and README say completion token usage and organization costs, with an explicit exclusion for ChatGPT and Codex subscription activity. |
| IMP-003, backfill can evict observed history | Resolved | Observed and provider-backfill samples have independent retention budgets. High-cardinality and store-level isolation tests pass. |
| IMP-004, diagnostic export free-form secret risk | Resolved | Account, plan, provider-response, model, line-item, metric, window, quantity, and unit strings are omitted or replaced by trusted aliases. Tests inject opaque and supported-family markers into every former free-form surface. |
| IMP-005, legacy observations are write-only | Resolved | Startup performs a stable-ID, lifecycle-guarded, retry-safe migration into observed normalized history. The legacy file is deleted only after all imports succeed. No append API remains. |
| MIN-001, dead Anthropic Admin implementation | Resolved | No compiled Anthropic Admin client, model, or test remains. Documentation lists Anthropic Admin only as an excluded organization-only candidate without live validation. |
| MIN-002, stale Models navigation and user docs | Resolved | Shipping navigation and current user docs point to Home and account detail. Only one source-only historical comment still says `Models-tab identity`. |
| MIN-003, no automated UI target | Resolved | `VigilUITests` is in the generated scheme. Tests cover first-use actions, Home to account detail, targeted Re-link, removal confirmation, and diagnostics at default, XXXL, and accessibility XXXL. |

## Critical lifecycle and identity audit

### Account removal

The lifecycle authority in `apps/apple/Vigil/Support/SharedContainer.swift:303-569` gives each active account an opaque generation. Removal tombstones that generation before deleting any data at `apps/apple/Vigil/AppModel.swift:845-996`.

Every late persistence path must then present its captured generation. The reviewed guards cover:

- Keychain credential reads and rotated-credential writes;
- current snapshot writes;
- observed and imported normalized history;
- pending threshold events and acknowledgements;
- fetch-lease acquisition, release, cancellation charging, and result recording; and
- app and widget refreshes.

The widget captures and validates the same shared generation at `apps/apple/VigilWidgets/UsageTimelineProvider.swift:103-147`. Removal awaits poll-ledger cleanup before reporting success, then performs a final local sweep.

The decisive regressions are covered at `apps/apple/VigilTests/AppModelReliabilityTests.swift:1183-1311`. One test pauses an app refresh across removal. Another uses a second lifecycle-store instance to model a late widget process. Both assert that old work cannot recreate protected state.

### Targeted Re-link

Account detail passes the selected account into `AddAccountView` at `apps/apple/Vigil/Dashboard/AccountDetailView.swift:59-61`. The setup flow locks manual providers to the target provider and routes Claude and Codex to their provider-specific sign-in at `apps/apple/Vigil/Onboarding/AddAccountView.swift:23-30` and `apps/apple/Vigil/Onboarding/AddAccountView.swift:129-147`.

`replaceCredentials` at `apps/apple/Vigil/AppModel.swift:562-748` preserves the target's stable Vigil key, verifies provider and stable provider-account identity, rotates the lifecycle generation, rolls back Keychain state if account-index persistence fails, and keeps existing history attached.

Tests at `apps/apple/VigilTests/AppModelReliabilityTests.swift:38-359` cover Claude, a credential-derived token provider, Codex, provider mismatch, provider-account mismatch, removal during verification, and another account being removed during Re-link.

## Lock-ordering audit

No inverse lock order was found.

The current ledger order is:

1. Enter `FetchScheduler` actor isolation when a ledger mutation is needed.
2. Acquire and validate the account lifecycle generation synchronously.
3. Acquire the ledger file lock and complete one local mutation.
4. Release the ledger lock, then the lifecycle lock.

Other guarded persistence paths use lifecycle lock, then the specific Keychain or file-store lock. No path was found that takes one of those store locks and then requests the lifecycle lock.

`SchedulerLifecycleGuard` at `packages/VigilKit/Sources/VigilKit/Scheduler/FetchScheduler.swift:73-84` and the guarded scheduler methods at `FetchScheduler.swift:328-340`, `FetchScheduler.swift:368-377`, `FetchScheduler.swift:443-453`, and `FetchScheduler.swift:520-531` enter the actor before acquiring the lifecycle file lock. The removed async lifecycle helper no longer holds a blocking `flock` while waiting for actor admission.

System notification delivery also runs outside the lifecycle lock at `apps/apple/Vigil/AppModel.swift:1212-1237`. Only the durable acknowledgement is generation-guarded. No network request, browser work, notification-center call, or arbitrary async closure runs while the lifecycle lock is held.

Removal acquires and releases the lifecycle lock for the tombstone first. It then deletes account stores and clears the scheduler ledger. No deletion path holds a store lock and then requests the lifecycle lock.

## History and migration audit

`UsageHistoryStore` has separate observed and provider-backfill budgets at `packages/VigilKit/Sources/VigilKit/History/UsageHistoryStore.swift:7-37` and applies them independently at `packages/VigilKit/Sources/VigilKit/History/UsageHistoryRetention.swift:40-63`. A large official import cannot consume the space reserved for readings observed by Vigil.

Legacy migration at `apps/apple/Vigil/Support/UsageObservationStore.swift:4-155` is idempotent:

- each legacy UUID becomes the normalized history UUID;
- old money readings retain `.observed` provenance;
- only currently linked accounts are eligible;
- each import is protected by the active lifecycle generation;
- the old file is removed only after every eligible account imports; and
- a failed import leaves the original file intact for retry.

Startup registers account lifecycles, runs migration, and reloads normalized history in that order at `apps/apple/Vigil/AppModel.swift:164-199`. Tests at `apps/apple/VigilTests/LegacyUsageObservationMigrationTests.swift:8-133` cover a successful migration, a crash-equivalent retry after import but before deletion, byte-for-byte preservation on failure, and account-scoped cleanup.

## OpenAI import audit

The importer requests only:

- `/v1/organization/usage/completions`; and
- `/v1/organization/costs`.

That scope is now stated precisely in code and UI. Costs remain separate metrics rather than being attributed to token groups.

The current [OpenAI Administration Usage API reference](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage) marks the cost `amount`, `amount.value`, and `amount.currency` fields optional. The implementation now decodes those fields optionally at `apps/apple/Vigil/Support/OpenAIAdminHistoryModels.swift:120-132`. It skips cost rows without a finite numeric amount, preserves an amount without inventing a currency, and maps JSON decoding failures to `invalidResponse` at `apps/apple/Vigil/Support/OpenAIAdminHistoryClient.swift:138-225`.

Tests at `apps/apple/VigilTests/OpenAIAdminHistoryClientTests.swift:60-145` cover optional completion counters, the newer breakdown shape, omitted cost amount fields, absent currency, malformed JSON, and schema decoding failures.

## Diagnostic privacy audit

The export now has a narrow output schema at `apps/apple/Vigil/Support/DiagnosticExport.swift:117-289`:

- account and history IDs are generated aliases;
- provider IDs come only from the static provider registry;
- window, metric, and quantity IDs are generated positional aliases;
- arbitrary labels and units are omitted;
- app name is fixed to `Vigil`; and
- version and build strings must match numeric allow lists.

The export API never accepts credentials, headers, cookies, Keychain data, or raw provider bodies. The remaining strings are enums, registry-owned provider IDs, or generated aliases. This satisfies the credential-free claim by construction.

`apps/apple/VigilTests/DiagnosticExportTests.swift:10-110` injects credential-derived account keys, account labels, plan labels, Anthropic-shaped keys, GitHub-shaped markers, opaque Cursor-shaped values, provider-controlled IDs and labels, units, and app metadata. It verifies that none survive and that the emitted file has owner-only permissions.

## Product and UI audit

The implementation now follows one recurring job. First launch presents Claude, ChatGPT/Codex, and Other Provider. Connected Home ranks account summaries. Account detail owns complete quotas, source limitations, balances, model caps, local observations, and official imports.

The plan note at `apps/apple/Vigil/Dashboard/AccountDetailView.swift:64-111` makes the correct distinction: a subscription tier can identify allowance context, and the provider's live percentage already reflects that tier, but a plan name alone is not evidence for a fixed token or message denominator.

`VigilUITests` is declared in `apps/apple/project.yml:81-109`. The final smoke suite at `apps/apple/VigilUITests/VigilAccessibilityUITests.swift:16-129` acknowledges the expected unsigned App Group warning, then exercises first use, account detail, Re-link, and removal confirmation. It checks diagnostics at default, XXXL, and accessibility XXXL.

Current user documentation contains no route to a removed Models tab. A repository scan finds one stale source comment at `packages/VigilKit/Sources/VigilKit/Providers/UsageMapper.swift:978-980`. It has no runtime or user-facing effect and is not a release blocker.

## Residual non-blocking verification

These are release-process checks, not defects found in the current code:

1. Verify a signed device or TestFlight build can open the configured App Group and that the widget and app reconcile the same current snapshot, history, lifecycle registry, and fetch ledger.
2. Repeat removal while a real widget fetch is in flight. Confirm that the widget cannot recreate data and that the signed app does not show the unsigned-storage warning.
3. Exercise real Claude, Codex, and OpenAI Admin authentication with test accounts. Live provider schemas and credential policies can change independently of this repository.
4. Check Home, account detail, setup sheets, destructive confirmation, and diagnostics manually with VoiceOver, Reduce Motion, XXXL, and accessibility XXXL on a physical iPhone. The UI suite provides smoke coverage, not a complete assistive-technology audit.
5. Confirm local notifications on a physical device. A notification already being submitted to iOS when removal starts can still complete, although the removed account cannot recreate its durable pending-event queue.
6. Accept that iOS background execution is opportunistic. Vigil can preserve every successful observation, but it cannot promise five-minute sampling or complete activity history.

## Verification evidence

- `git diff --check`: passed.
- `swift test --package-path packages/VigilKit`: 168 tests executed, 2 live provider probes skipped, 0 failures.
- Exact CI-style unsigned full scheme on iPhone 15 Pro, iOS 17.5: 93 tests passed, 0 failed, 0 skipped.
- Standard-signing simulator UI suite on iPhone 17 Pro, iOS 26.5: 7 tests passed, 0 failed, 0 skipped. The removal check accepts both the iOS 17 action-sheet form and the iOS 26 popover form while requiring the named destructive confirmation.
- CI-style command: `xcodebuild -project apps/apple/Vigil.xcodeproj -scheme Vigil -destination 'platform=iOS Simulator,id=<available iPhone>' test CODE_SIGNING_ALLOWED=NO`.
- The unsigned first-use test confirms the expected App Group fallback warning can be acknowledged and all three setup actions remain hittable.
- Focused export and OpenAI import tests passed under the same unsigned simulator configuration.
- Static scans covered all lifecycle guards, scheduler mutations, app and widget writers, removal and Re-link paths, legacy storage symbols, Anthropic Admin symbols, Models navigation references, diagnostic string fields, and UI-test targets.
- No product code or GitHub state was changed by this final review. Only this review artifact was updated.

## Release decision

The current implementation passes the reviewed code and simulator gates. **No code change is required before creating the release candidate.** Complete the signed-device checks above before representing widget sharing, notification behavior, or live provider compatibility as verified for the release build.

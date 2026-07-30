# Settings Revamp (1.0.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Vigil the settings a mature app carries — appearance, alerts, refresh, accessibility, widget options, and Liquid Glass — per the approved spec, shipping as version 1.0.0 build 22.

**Architecture:** A single App Group-backed `VigilPreferences` store (dual target membership, same pattern as `UsageService.swift`) feeds every consumer: the adaptive `VigilPalette`, `UsageService`/`ThresholdEngine` alert resolution, the polling pause seams, `SnapshotFreshness`, widgets, and the rebuilt Settings page. Six PRs land in order: PR-0 (pre-existing SwiftUI sweep fixes) through PR-5 (Liquid Glass on iOS 26+ with fallback).

**Tech Stack:** SwiftUI (iOS 17 deployment target), `@Observable`, App Group `UserDefaults`, XCTest + XCUITest, XcodeGen, VigilKit (UI-free, unchanged except where noted).

**Spec:** `docs/superpowers/specs/2026-07-30-settings-revamp-design.md` — the authority for scope and invariants.

## Global Constraints

- No preference can shorten any polling interval; pause flags only subtract work. The 60-second floor and 429 backoff are untouchable.
- Retained or paused data always ages visibly; pausing never freezes the display of time.
- Status colors keep their meanings in both themes and status is never encoded by hue alone.
- VigilKit stays UI-free and preference-free; the app passes preference values into kit APIs.
- Behavioral defaults reproduce current shipped behavior except the three named 1.0.0 changes: system-following appearance, haptics default-on, unconditional status labels.
- Every new control carries a `vigil.settings.*` accessibility identifier and a pinned spoken surface.
- One PR per task group; each PR runs the full gate (docs, VigilKit, iOS scheme) before merge.
- iOS 26+ APIs are `#available`-gated with the current design as fallback; deployment target stays iOS 17.
- Version identity at the end: 1.0.0, build 22 (global monotonic counter).

## Canonical Interfaces

Every task builds against these exact signatures (defined in PR-1, consumed everywhere):

```swift
// apps/apple/Vigil/Support/VigilPreferences.swift — member of BOTH app and widget targets
@Observable final class VigilPreferences {
    enum Appearance: String { case system, light, dark }   // .colorScheme: system -> nil
    var appearance: Appearance                              // "prefs.appearance", default .system
    var alertLevels: [Int]                                  // "prefs.alertLevels", default [80, 95]; sorted unique 1-99, max 8
    var accountAlertOverrides: [String: [Int]]              // "prefs.accountAlertOverrides", default [:]
    var pauseAllPolling: Bool                               // "prefs.pauseAllPolling", default false
    var pausedAccountKeys: Set<String>                      // "prefs.pausedAccountKeys", default []
    var staleAfterMinutes: Int                              // "prefs.staleAfterMinutes", default 30, allowed {15, 30, 60}
    var reduceProminentAnimations: Bool                     // "prefs.reduceProminentAnimations", default false
    var hapticsEnabled: Bool                                // "prefs.hapticsEnabled", default true
    var widgetRedactedWhenLocked: Bool                      // "prefs.widgetRedactedWhenLocked", default false
    var widgetsFollowThemeOverride: Bool                    // "prefs.widgetsFollowThemeOverride", default true
    init(defaults: UserDefaults)
    func isPollingPaused(forAccountKey key: String) -> Bool
    func effectiveAlertLevels(forAccountKey key: String) -> [Int]   // override if present (empty = muted) else alertLevels
    func removeOverrides(forAccountKey key: String)
    static func addingValidatedLevel(_ level: Int, to levels: [Int]) -> [Int]?
}
// VigilPalette color NAMES are unchanged; each becomes adaptive (dark half bit-for-bit today's values).
// Test hooks: VigilPalette.resolvedRGBA(_:for:) and VigilPalette.contrastRatio(_:_:).
```

---



## PR-0

### Task 1: Cancel the Codex sign-in retry with the view (a cancelled sign-in must never link)

**PR:** PR-0 — SwiftUI sweep fixes

**Files:**
- Create: `apps/apple/Vigil/Onboarding/SignInAttempt.swift`
- Create: `apps/apple/VigilTests/SignInAttemptTests.swift`
- Modify: `apps/apple/Vigil/Onboarding/CodexSignInView.swift` (state block at line 15, `.task` at line 43, "Try again" at line 135, `complete(authorizationCode:codeVerifier:)` at lines 203-227)

**Interfaces:**
- Produces:
  ```swift
  @MainActor @Observable final class SignInAttempt {
      nonisolated init()
      var isRunning: Bool { get }
      func start(_ operation: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void)
      func cancel()
  }
  ```
- Consumes: `ProviderUsageSession.shared.data(for:)` (`apps/apple/Vigil/Support/UsageService.swift:5-16`), `CodexAuth` (VigilKit) — both unchanged.

Background for the engineer: `CodexSignInView` line 135 is `Button("Try again") { Task { await run() } }`. That unstructured `Task` is never stored and never cancelled, and `run()` → `poll(device:)` loops for up to 15 minutes before `complete(...)` calls `onComplete(credentials)` unconditionally. Dismiss the sheet after tapping "Try again" and the poll keeps running; if the user later approves the code in the browser, the account links even though they cancelled. The initial `.task { await run() }` at line 43 is structured (SwiftUI cancels it on disappear) — only the retry leaks.

- [ ] **Step 1: Create the working branch**
  ```sh
  git -C /Users/biscuit/Vigil checkout -b fix/pr0-swiftui-sweep main
  ```

- [ ] **Step 2: Write the failing test** — create `apps/apple/VigilTests/SignInAttemptTests.swift`:
  ```swift
  import XCTest
  @testable import Vigil

  /// SignInAttempt owns the lifecycle of one restartable, cancellable sign-in
  /// attempt. It exists because the SwiftUI sweep found an unstructured retry
  /// Task in CodexSignInView that survived view dismissal: a cancelled
  /// sign-in could still link an account up to 15 minutes later.
  @MainActor
  final class SignInAttemptTests: XCTestCase {
      func testCancelPreventsALateCompletionFromPublishing() async throws {
          let attempt = SignInAttempt()
          var linked = false
          let operationStarted = expectation(description: "operation started")
          let operationFinished = expectation(description: "operation finished")

          attempt.start { isCurrent in
              operationStarted.fulfill()
              // Simulate the device-code poll: a wait that ends — like a
              // network callback — whether or not anyone still cares.
              try? await Task.sleep(nanoseconds: 200_000_000)
              if isCurrent(), !Task.isCancelled {
                  linked = true
              }
              operationFinished.fulfill()
          }

          await fulfillment(of: [operationStarted], timeout: 2)
          XCTAssertTrue(attempt.isRunning)
          attempt.cancel()
          XCTAssertFalse(attempt.isRunning)
          await fulfillment(of: [operationFinished], timeout: 2)
          XCTAssertFalse(linked, "A cancelled sign-in must never link an account")
      }

      func testStartWhileRunningCancelsThePreviousAttempt() async throws {
          let attempt = SignInAttempt()
          var firstSawCancellation = false
          let firstFinished = expectation(description: "first attempt finished")

          attempt.start { _ in
              while !Task.isCancelled {
                  try? await Task.sleep(nanoseconds: 20_000_000)
              }
              firstSawCancellation = true
              firstFinished.fulfill()
          }
          attempt.start { _ in }

          await fulfillment(of: [firstFinished], timeout: 2)
          XCTAssertTrue(firstSawCancellation, "Retry must cancel the previous attempt")
          attempt.cancel()
      }
  }
  ```

- [ ] **Step 3: Run test to verify it fails**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/SignInAttemptTests
  ```
  Expected failure: the test target does not compile — `cannot find 'SignInAttempt' in scope`. A compile failure is the red state for a new type.

- [ ] **Step 4: Minimal implementation** — create `apps/apple/Vigil/Onboarding/SignInAttempt.swift`. Deliberately minimal: the post-operation cleanup is UNGUARDED (it mirrors the defer race ClaudeSignInView ships today; Task 2 turns that exact race red and then fixes it here):
  ```swift
  import Foundation
  import Observation

  /// One restartable, cancellable sign-in attempt owned by a view. Exists
  /// because the SwiftUI sweep found two failure modes in the guided sign-in
  /// views: an unstructured retry Task that survived view dismissal (a
  /// cancelled sign-in could still link an account minutes later), and the
  /// cancel/retry race AddAccountView.run documents.
  @MainActor
  @Observable
  final class SignInAttempt {
      @ObservationIgnored private var task: Task<Void, Never>?
      private var activeAttemptID: UUID?

      nonisolated init() {}

      var isRunning: Bool { activeAttemptID != nil }

      /// Cancels any in-flight attempt and starts a new one. Every completion
      /// path in `operation` must consult `isCurrent()` (alongside
      /// `Task.isCancelled`) before publishing results.
      func start(
          _ operation: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
      ) {
          let superseded = task
          task = nil
          activeAttemptID = nil
          superseded?.cancel()

          let attemptID = UUID()
          activeAttemptID = attemptID
          task = Task { [weak self] in
              await operation { [weak self] in self?.activeAttemptID == attemptID }
              self?.activeAttemptID = nil
              self?.task = nil
          }
      }

      /// Invalidate the attempt identity before cancelling its Task, mirroring
      /// AddAccountView.cancelLinking: asynchronous unwinding then observes a
      /// stale identity and publishes nothing.
      func cancel() {
          activeAttemptID = nil
          let running = task
          task = nil
          running?.cancel()
      }
  }
  ```

- [ ] **Step 5: Run test to verify it passes** — same command as Step 3 (rerun `xcodegen generate` first; the new source file must enter the project). Expected: `Test Suite 'SignInAttemptTests' passed`, both tests PASS.

- [ ] **Step 6: Wire CodexSignInView** — four edits in `apps/apple/Vigil/Onboarding/CodexSignInView.swift`:

  At line 15, add the attempt owner below the phase state:
  ```swift
      @State private var phase: Phase = .requesting
      @State private var retryAttempt = SignInAttempt()
  ```
  At lines 42-43, cancel with the view (the initial `.task` is already structured and self-cancelling; `.onDisappear` covers the retry attempt):
  ```swift
          .preferredColorScheme(.dark)
          .task { await run() }
          .onDisappear { retryAttempt.cancel() }
  ```
  At line 135, tie retry to the stored attempt instead of a leaked Task:
  ```swift
                  Button("Try again") { retryAttempt.start { _ in await run() } }
  ```
  In `complete(authorizationCode:codeVerifier:)`, immediately after `let (data, response) = try await ProviderUsageSession.shared.data(for: request)` (line 209), close the last race window between cancellation and delivery:
  ```swift
              let (data, response) = try await ProviderUsageSession.shared.data(for: request)
              // A dismissed or superseded sign-in must never link an account:
              // the user was told nothing happened.
              guard !Task.isCancelled else { return }
  ```

- [ ] **Step 7: Verify the wiring builds and the suite stays green**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/SignInAttemptTests
  ```
  Expected: build succeeds (proving the CodexSignInView wiring compiles) and both tests PASS.

- [ ] **Step 8: Commit**
  ```sh
  git -C /Users/biscuit/Vigil add \
    apps/apple/Vigil/Onboarding/SignInAttempt.swift \
    apps/apple/VigilTests/SignInAttemptTests.swift \
    apps/apple/Vigil/Onboarding/CodexSignInView.swift
  git -C /Users/biscuit/Vigil commit \
    -m "Tie the Codex sign-in retry to the view so a cancelled sign-in cannot link" \
    -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 2: Guard the Claude code exchange with attempt identity and cancel it with the view

**PR:** PR-0 — SwiftUI sweep fixes

**Files:**
- Modify: `apps/apple/Vigil/Onboarding/SignInAttempt.swift` (post-operation cleanup inside `start`)
- Modify: `apps/apple/VigilTests/SignInAttemptTests.swift` (add one test)
- Modify: `apps/apple/Vigil/Onboarding/ClaudeSignInView.swift` (state at lines 18-19, `canLink` at line 33, overlay at line 59, Cancel at lines 134-138, `link()` at lines 148-190)

**Interfaces:**
- Consumes: `SignInAttempt` (Task 1), `ClaudeAuth.parsePastedCode(_:expectedState:)`, `ClaudeAuth.exchangeRequest(oauth:code:redirectURI:verifier:state:)`, `ClaudeAuth.credentials(fromExchange:)`, `ClaudeAuth.generatePKCE()` (all VigilKit, unchanged).
- Produces: `SignInAttempt.start` cleanup becomes attempt-identity guarded (public signature unchanged).

Background: `ClaudeSignInView.link()` (line 154) does `exchangeTask?.cancel()` then starts a new Task whose `defer` (lines 157-160) unconditionally clears `isExchanging` and `exchangeTask`. When attempt A is cancelled and attempt B starts, A's defer unwinds later and clears B's overlay and task handle — the exact race `AddAccountView.swift:270-279` guards against with `activeLinkAttemptID`. The view also never cancels `exchangeTask` on dismissal (no `.onDisappear`), so a dismissed exchange can still call `onComplete`.

- [ ] **Step 1: Write the failing test** — append to `SignInAttemptTests` in `apps/apple/VigilTests/SignInAttemptTests.swift`:
  ```swift
      func testASupersededAttemptsCleanupDoesNotClearTheNewerAttempt() async throws {
          let attempt = SignInAttempt()
          let firstFinished = expectation(description: "first attempt unwound")
          let secondStarted = expectation(description: "second attempt started")
          var secondIsCurrent: (@MainActor () -> Bool)?

          attempt.start { _ in
              // Unwinds shortly after being cancelled — its cleanup then
              // races the second attempt, exactly like ClaudeSignInView's
              // defer cleared a newer attempt's isExchanging/exchangeTask.
              while !Task.isCancelled {
                  try? await Task.sleep(nanoseconds: 10_000_000)
              }
              firstFinished.fulfill()
          }
          attempt.start { isCurrent in
              secondIsCurrent = isCurrent
              secondStarted.fulfill()
              // Stay in flight while the first attempt's cleanup unwinds.
              try? await Task.sleep(nanoseconds: 60_000_000_000)
          }

          await fulfillment(of: [firstFinished, secondStarted], timeout: 2)
          // Give the first attempt's post-operation cleanup time to run.
          try await Task.sleep(nanoseconds: 50_000_000)

          XCTAssertTrue(
              attempt.isRunning,
              "The first attempt's cleanup cleared the second attempt's running state"
          )
          XCTAssertEqual(
              secondIsCurrent?(), true,
              "The second attempt must still be the active one"
          )
          attempt.cancel()
      }
  ```

- [ ] **Step 2: Run test to verify it fails**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/SignInAttemptTests/testASupersededAttemptsCleanupDoesNotClearTheNewerAttempt
  ```
  Expected failure: `XCTAssertTrue failed - The first attempt's cleanup cleared the second attempt's running state` (Task 1's unguarded cleanup nils the identity that now belongs to attempt B).

- [ ] **Step 3: Minimal implementation** — in `apps/apple/Vigil/Onboarding/SignInAttempt.swift`, replace the unguarded cleanup inside `start`:
  ```swift
          task = Task { [weak self] in
              await operation { [weak self] in self?.activeAttemptID == attemptID }
              self?.activeAttemptID = nil
              self?.task = nil
          }
  ```
  with the identity-guarded cleanup:
  ```swift
          task = Task { [weak self] in
              await operation { [weak self] in self?.activeAttemptID == attemptID }
              // A superseded attempt may unwind after the user has already
              // started another one. It must not clear the newer attempt's
              // running state or task handle (the AddAccountView.run race).
              guard let self, self.activeAttemptID == attemptID else { return }
              self.activeAttemptID = nil
              self.task = nil
          }
  ```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2, then the whole class:
  ```sh
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/SignInAttemptTests
  ```
  Expected: all three tests PASS (the guard must not regress Task 1's two tests).

- [ ] **Step 5: Wire ClaudeSignInView** — edits in `apps/apple/Vigil/Onboarding/ClaudeSignInView.swift`:

  Replace the state at lines 18-19 (`isExchanging` and `exchangeTask` are deleted; the attempt owns both):
  ```swift
      @State private var didOpen = false
      @State private var exchangeAttempt = SignInAttempt()
      @State private var errorMessage: String?
  ```
  Replace `canLink` (line 32-34):
  ```swift
      private var canLink: Bool {
          !pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && !exchangeAttempt.isRunning
      }
  ```
  Replace the overlay line (59) and add `.onDisappear` after `.preferredColorScheme(.dark)` (line 60):
  ```swift
          .overlay { if exchangeAttempt.isRunning { exchangingOverlay } }
          .preferredColorScheme(.dark)
          .onDisappear { exchangeAttempt.cancel() }
  ```
  Replace the Cancel button body in `exchangingOverlay` (lines 134-138):
  ```swift
                  Button("Cancel") {
                      exchangeAttempt.cancel()
                  }
                  .buttonStyle(.bordered)
                  .tint(VigilPalette.inkMuted)
                  .padding(.top, 4)
  ```
  Replace `link()` (lines 148-190) in full:
  ```swift
      private func link() {
          errorMessage = nil
          guard let code = ClaudeAuth.parsePastedCode(pastedCode, expectedState: pkce.state) else {
              errorMessage = "That code didn't look right. Copy the whole code Claude showed you and try again."
              return
          }
          exchangeAttempt.start { isCurrent in
              let request = ClaudeAuth.exchangeRequest(
                  oauth: oauth,
                  code: code,
                  redirectURI: redirectURI,
                  verifier: pkce.verifier,
                  state: pkce.state
              )
              do {
                  let (data, response) = try await ProviderUsageSession.shared.data(for: request)
                  // A cancelled or superseded exchange publishes nothing: not
                  // credentials, not an error, not a fresh PKCE.
                  guard isCurrent(), !Task.isCancelled else { return }
                  guard let http = response as? HTTPURLResponse,
                        (200..<300).contains(http.statusCode),
                        let credentials = ClaudeAuth.credentials(fromExchange: data)
                  else {
                      // A fresh PKCE for the next attempt: a used/expired code can't be retried.
                      pkce = ClaudeAuth.generatePKCE()
                      pastedCode = ""
                      errorMessage = "Claude didn't accept that code — it may have expired. Tap “Reopen Claude sign-in” to start over."
                      return
                  }
                  onComplete(credentials)
                  dismiss()
              } catch is CancellationError {
                  // User cancelled or the view went away.
              } catch {
                  guard isCurrent(), !Task.isCancelled else { return }
                  errorMessage = "Couldn't reach Claude to finish signing in. Check your connection and try again."
              }
          }
      }
  ```

- [ ] **Step 6: Verify the wiring builds and existing UI coverage stays green** (the accessibility suite drives "Sign in with Claude" from first-run setup):
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/SignInAttemptTests \
    -only-testing:VigilUITests/VigilAccessibilityUITests/testCriticalActionsAtDefaultContentSize
  ```
  Expected: PASS.

- [ ] **Step 7: Commit**
  ```sh
  git -C /Users/biscuit/Vigil add \
    apps/apple/Vigil/Onboarding/SignInAttempt.swift \
    apps/apple/VigilTests/SignInAttemptTests.swift \
    apps/apple/Vigil/Onboarding/ClaudeSignInView.swift
  git -C /Users/biscuit/Vigil commit \
    -m "Guard the Claude code exchange with attempt identity and cancel it with the view" \
    -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 3: Make the history disclosure row speak the reading it summarizes

**PR:** PR-0 — SwiftUI sweep fixes

**Files:**
- Modify: `apps/apple/Vigil/Support/DemoData.swift` (add two members after `historyRecoveryRequested`, line 36)
- Modify: `apps/apple/Vigil/AppModel.swift` (`seedDemoDataIfRequested()`, lines 211-214)
- Modify: `apps/apple/VigilUITests/VigilAccessibilityUITests.swift` (`launch(...)` helper at lines 193-217; one new test method)
- Modify: `apps/apple/Vigil/Dashboard/ObservedHistorySection.swift` (line 308)

**Interfaces:**
- Produces:
  ```swift
  // DemoData
  static func historySeedRequested(in environment: [String: String]) -> Bool   // "VIGIL_DEMO_HISTORY" == "1"
  static func historySamples(now: Date = Date()) -> [String: [UsageHistorySample]]
  ```
- Consumes: `UsageHistorySample` / `UsageHistoryWindow` public inits (`packages/VigilKit/Sources/VigilKit/History/UsageHistoryModels.swift:30-57,143-171`), `AppModel.recentHistorySamples` (`private(set)`, AppModel.swift:70 — assigned from inside AppModel).

Background: `ObservedHistorySection.swift:308` puts `.accessibilityLabel("History reading details")` on the disclosure Button, which REPLACES the visible reading (`primaryValue`, e.g. "58% left · 5-hour limit") for VoiceOver. A VoiceOver user hears only a generic phrase for every row — the actual reading is unreachable. Demo mode seeds no history (`DemoData.seed` returns accounts and snapshots only), so the test infrastructure below seeds one deterministic observed reading first, then the red test asserts the spoken label.

- [ ] **Step 1: Test infrastructure — seed deterministic demo history.** In `apps/apple/Vigil/Support/DemoData.swift`, after `historyRecoveryRequested` (line 36), add:
  ```swift
      /// UI-test and screenshot hook: seeds one retained observed reading for
      /// the demo Claude account so history rows render without any polling.
      /// It has no effect unless demo mode is also enabled by the caller.
      static func historySeedRequested(in environment: [String: String]) -> Bool {
          environment["VIGIL_DEMO_HISTORY"] == "1"
      }

      /// One observed Claude reading whose row summary is deterministic:
      /// "58% left · 5-hour limit". Keyed by account key for direct
      /// assignment to AppModel.recentHistorySamples.
      static func historySamples(now: Date = Date()) -> [String: [UsageHistorySample]] {
          let sample = UsageHistorySample(
              source: .observed,
              accountKey: "claude:demo",
              providerId: "claude",
              recordedAt: now.addingTimeInterval(-3_600),
              retrievedAt: now.addingTimeInterval(-3_600),
              status: .ok,
              windows: [
                  UsageHistoryWindow(
                      providerId: "claude",
                      id: "session",
                      utilization: 42,
                      resetAt: now.addingTimeInterval(2 * 3_600),
                      windowSeconds: 18_000
                  )
              ]
          )
          return ["claude:demo": [sample]]
      }
  ```
  In `apps/apple/Vigil/AppModel.swift`, `seedDemoDataIfRequested()` — replace lines 211-214:
  ```swift
          let demo = DemoData.seed(claudeStatus: claudeStatus)
          accounts = demo.accounts
          snapshots = demo.snapshots
          demoHistoryDamageActive = DemoData.historyRecoveryRequested(in: environment)
  ```
  with:
  ```swift
          let demo = DemoData.seed(claudeStatus: claudeStatus)
          accounts = demo.accounts
          snapshots = demo.snapshots
          if DemoData.historySeedRequested(in: environment) {
              recentHistorySamples = DemoData.historySamples()
          }
          demoHistoryDamageActive = DemoData.historyRecoveryRequested(in: environment)
      ```
  (Demo mode never calls `loadFromDisk()`/`queueHistoryReload()` — `ensureLoadedFromDisk` guards on `!isDemo` at AppModel.swift:240 — so the seed cannot be clobbered.)

- [ ] **Step 2: Write the failing test.** In `apps/apple/VigilTests/../VigilUITests/VigilAccessibilityUITests.swift` — first extend the private `launch` helper (lines 193-217) with a `demoHistory` parameter; replace it in full with:
  ```swift
      private func launch(
          tab: String,
          demo: Bool,
          contentSizeCategory: UIContentSizeCategory? = nil,
          claudeAuthExpired: Bool = false,
          claudeProviderChanged: Bool = false,
          demoHistory: Bool = false
      ) {
          if app?.state != .notRunning {
              app?.terminate()
          }
          app = XCUIApplication()
          app.launchEnvironment["VIGIL_TAB"] = tab
          app.launchEnvironment["VIGIL_DEMO"] = demo ? "1" : "0"
          app.launchEnvironment["VIGIL_DEMO_CLAUDE_AUTH_EXPIRED"] = claudeAuthExpired ? "1" : "0"
          app.launchEnvironment["VIGIL_DEMO_CLAUDE_PROVIDER_CHANGED"] = claudeProviderChanged ? "1" : "0"
          app.launchEnvironment["VIGIL_DEMO_HISTORY"] = demoHistory ? "1" : "0"
          app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
          app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
          if let contentSizeCategory {
              app.launchArguments += [
                  "-UIPreferredContentSizeCategoryName",
                  contentSizeCategory.rawValue,
              ]
          }
          app.launch()
      }
  ```
  Then add the test method (place it after `testDegradedHomeCardSpeaksDataAgeNotACheckTime`, line 74):
  ```swift
      func testHistoryRowSpeaksTheReadingItDiscloses() {
          launch(tab: "home", demo: true, demoHistory: true)

          tapVisiblePortion(of: reachableElement("vigil.home.account.claude"))
          XCTAssertTrue(
              app.navigationBars["Claude"].waitForExistence(timeout: 5),
              "The Claude Home card must open account detail."
          )

          // Scroll until the observed-history disclosure row is on screen,
          // matched by either spoken label so the failure names the bug.
          let readingRow = app.buttons["58% left · 5-hour limit"]
          let genericRow = app.buttons["History reading details"]
          let scrollView = app.scrollViews.firstMatch
          for _ in 0..<10 where !(readingRow.exists || genericRow.exists) {
              scrollView.swipeUp()
          }

          XCTAssertTrue(
              readingRow.exists,
              "The history disclosure must speak the reading it summarizes, not a generic phrase."
          )
          XCTAssertFalse(
              genericRow.exists,
              "A generic spoken label hides the reading from VoiceOver users."
          )
      }
  ```

- [ ] **Step 3: Run test to verify it fails**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilUITests/VigilAccessibilityUITests/testHistoryRowSpeaksTheReadingItDiscloses
  ```
  Expected failure: `XCTAssertTrue failed - The history disclosure must speak the reading it summarizes, not a generic phrase.` — the scroll loop stops because the generic-labeled row exists (proving the seeded row rendered), and the reading-labeled row does not.

- [ ] **Step 4: Minimal implementation** — in `apps/apple/Vigil/Dashboard/ObservedHistorySection.swift`, line 308, replace:
  ```swift
              .accessibilityLabel("History reading details")
  ```
  with:
  ```swift
              .accessibilityLabel(primaryValue)
  ```
  Lines 309-310 (`.accessibilityValue(isExpanded ? "Expanded" : "Collapsed")` and the hint) stay exactly as they are — state and behavior remain spoken; only the label now carries the reading.

- [ ] **Step 5: Run test to verify it passes** — same command as Step 3. Expected: PASS.

- [ ] **Step 6: Commit**
  ```sh
  git -C /Users/biscuit/Vigil add \
    apps/apple/Vigil/Support/DemoData.swift \
    apps/apple/Vigil/AppModel.swift \
    apps/apple/VigilUITests/VigilAccessibilityUITests.swift \
    apps/apple/Vigil/Dashboard/ObservedHistorySection.swift
  git -C /Users/biscuit/Vigil commit \
    -m "Speak the history reading in the disclosure row's VoiceOver label" \
    -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 4: Restore the linking overlay's spoken copy, focusable Cancel, and modal containment

**PR:** PR-0 — SwiftUI sweep fixes

**Files:**
- Modify: `apps/apple/Vigil/Support/DemoData.swift` (add one member after `historySamples` from Task 3)
- Modify: `apps/apple/Vigil/Onboarding/AddAccountView.swift` (body lines 82-84, `run(...)` Task body at lines 268-282, `linkingOverlay` at lines 202-225)
- Modify: `apps/apple/VigilUITests/VigilAccessibilityUITests.swift` (`launch(...)` helper; one new test method)

**Interfaces:**
- Produces:
  ```swift
  // DemoData
  static func linkHoldRequested(in environment: [String: String]) -> Bool   // "VIGIL_UI_TEST_LINK_HOLD" == "1"
  ```
- Consumes: `AddAccountView.cancelLinking()` (lines 320-327, unchanged), `VigilPalette`, `VigilSpacing` (unchanged).

Background: `AddAccountView.swift:223-224` puts `.accessibilityElement(children: .combine)` plus `.accessibilityLabel("Verifying account with the provider")` on the whole overlay ZStack. The explicit label replaces the combined children, so VoiceOver never hears "Nothing is saved until verification finishes." (line 210), the Cancel button (line 214) is flattened into a rotor-only custom action, and nothing removes the covered form from the VoiceOver order — swiping right walks into controls the overlay visually blocks.

- [ ] **Step 1: Test infrastructure — a deterministic way to hold the overlay open.** In `apps/apple/Vigil/Support/DemoData.swift`, after `historySamples` (added in Task 3), add:
  ```swift
      /// UI-test-only hook: holds a link attempt open instead of contacting a
      /// provider, so tests can assert the linking overlay's accessibility
      /// structure deterministically. Cancellation ends the hold.
      static func linkHoldRequested(in environment: [String: String]) -> Bool {
          environment["VIGIL_UI_TEST_LINK_HOLD"] == "1"
      }
  ```
  In `apps/apple/Vigil/Onboarding/AddAccountView.swift`, inside `run(...)`'s Task, immediately after the two guards at lines 281-282:
  ```swift
                  try Task.checkCancellation()
                  guard activeLinkAttemptID == attemptID else { return }
  ```
  insert:
  ```swift
                  if DemoData.linkHoldRequested(in: ProcessInfo.processInfo.environment) {
                      // UI-test-only: keep the overlay visible so its spoken
                      // surface can be asserted; no provider is contacted.
                      // cancelLinking() cancels the sleep (CancellationError).
                      try await Task.sleep(nanoseconds: 300_000_000_000)
                  }
  ```
  In `apps/apple/VigilUITests/VigilAccessibilityUITests.swift`, extend the `launch` helper's signature (which after Task 3 ends with `demoHistory: Bool = false`) by adding a final parameter `linkHold: Bool = false`, and add this line next to the other `launchEnvironment` assignments:
  ```swift
          app.launchEnvironment["VIGIL_UI_TEST_LINK_HOLD"] = linkHold ? "1" : "0"
  ```

- [ ] **Step 2: Write the failing test** — add to `VigilAccessibilityUITests`:
  ```swift
      func testLinkingOverlaySpeaksItsCopyAndKeepsCancelFocusable() {
          launch(tab: "home", demo: false, linkHold: true)

          tapVisiblePortion(of: reachableElement("vigil.setup.other"))
          XCTAssertTrue(app.navigationBars["Other provider"].waitForExistence(timeout: 5))

          let providerRow = app.descendants(matching: .any).matching(
              NSPredicate(format: "label CONTAINS %@", "OpenRouter")
          ).firstMatch
          let catalogScroll = app.scrollViews.firstMatch
          for _ in 0..<10 where !providerRow.isHittable {
              catalogScroll.swipeUp()
          }
          providerRow.tap()
          XCTAssertTrue(app.navigationBars["Direct setup"].waitForExistence(timeout: 5))

          let keyField = app.secureTextFields.firstMatch
          XCTAssertTrue(keyField.waitForExistence(timeout: 5))
          keyField.tap()
          keyField.typeText("sk-or-ui-test\n")

          let submit = app.buttons["Verify and add account"]
          if !submit.isHittable { app.swipeUp() }
          submit.tap()

          // VIGIL_UI_TEST_LINK_HOLD keeps the overlay up without networking.
          let spokenCopy = app.descendants(matching: .any).matching(
              NSPredicate(
                  format: "label CONTAINS %@",
                  "Nothing is saved until verification finishes."
              )
          ).firstMatch
          XCTAssertTrue(
              spokenCopy.waitForExistence(timeout: 5),
              "The overlay must speak its nothing-is-saved promise, not a replacement label."
          )
          let cancel = app.buttons["vigil.addAccount.cancelLinking"]
          XCTAssertTrue(
              cancel.waitForExistence(timeout: 3),
              "Cancel must be a focusable button, not a rotor-only action."
          )
          XCTAssertFalse(
              app.buttons["vigil.addAccount.close"].exists,
              "The covered form must leave the accessibility order while the overlay shows."
          )
          cancel.tap()
          XCTAssertTrue(
              app.buttons["vigil.addAccount.close"].waitForExistence(timeout: 5),
              "Cancel must dismiss the overlay and restore the form."
          )
      }
  ```

- [ ] **Step 3: Run test to verify it fails**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilUITests/VigilAccessibilityUITests/testLinkingOverlaySpeaksItsCopyAndKeepsCancelFocusable
  ```
  Expected failure: `XCTAssertTrue failed - The overlay must speak its nothing-is-saved promise, not a replacement label.` — the combined overlay's only label is "Verifying account with the provider".

- [ ] **Step 4: Minimal implementation** — two edits in `apps/apple/Vigil/Onboarding/AddAccountView.swift`:

  In `body`, replace lines 82-84:
  ```swift
          .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
          .toolbarBackground(.visible, for: .navigationBar)
          .overlay { if isLinking { linkingOverlay } }
  ```
  with (the base stack leaves the accessibility order while linking; `.accessibilityHidden` is applied before `.overlay`, so the overlay itself stays exposed):
  ```swift
          .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
          .toolbarBackground(.visible, for: .navigationBar)
          .accessibilityHidden(isLinking)
          .overlay { if isLinking { linkingOverlay } }
  ```
  Replace `linkingOverlay` (lines 202-225) in full:
  ```swift
      private var linkingOverlay: some View {
          ZStack {
              Color.black.opacity(0.58).ignoresSafeArea()
              VStack(spacing: 12) {
                  VStack(spacing: 12) {
                      ProgressView().controlSize(.large).tint(VigilPalette.signal)
                      Text("Checking with the provider")
                          .font(.headline)
                          .foregroundStyle(VigilPalette.ink)
                      Text("Nothing is saved until verification finishes.")
                          .font(.caption)
                          .foregroundStyle(VigilPalette.inkMuted)
                          .multilineTextAlignment(.center)
                  }
                  // One spoken summary for the progress state. Cancel stays a
                  // separately focusable sibling, not a rotor-only action.
                  .accessibilityElement(children: .combine)
                  Button("Cancel") {
                      cancelLinking()
                  }
                  .buttonStyle(.bordered)
                  .tint(VigilPalette.inkMuted)
                  .accessibilityIdentifier("vigil.addAccount.cancelLinking")
              }
              .padding(24)
              .vigilCard(padding: VigilSpacing.large)
          }
          // VoiceOver must not wander into the covered form; the base
          // NavigationStack is also accessibility-hidden while isLinking.
          .accessibilityAddTraits(.isModal)
      }
  ```

- [ ] **Step 5: Run test to verify it passes** — same command as Step 3. Expected: PASS. Also rerun the untouched overlay-adjacent coverage:
  ```sh
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/AddAccountLinkFlowTests
  ```
  Expected: PASS (resolution mapping untouched).

- [ ] **Step 6: Commit**
  ```sh
  git -C /Users/biscuit/Vigil add \
    apps/apple/Vigil/Support/DemoData.swift \
    apps/apple/Vigil/Onboarding/AddAccountView.swift \
    apps/apple/VigilUITests/VigilAccessibilityUITests.swift
  git -C /Users/biscuit/Vigil commit \
    -m "Restore the linking overlay's spoken copy, focusable Cancel, and modal containment" \
    -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 5: Label the circular widget's fallback ring instead of announcing "V, 0%"

**PR:** PR-0 — SwiftUI sweep fixes

**Files:**
- Modify: `apps/apple/Vigil/Support/UsagePresentation.swift` (add one function after `exactAmountsMatchUtilization`, lines 15-20; this file is compiled into BOTH the app target and VigilWidgets per `apps/apple/project.yml:130`)
- Create: `apps/apple/VigilTests/WidgetFallbackAccessibilityTests.swift`
- Modify: `apps/apple/VigilWidgets/VigilWidgets.swift` (fallback branch of `CircularUsageView`, lines 302-309)

**Interfaces:**
- Produces:
  ```swift
  // UsagePresentation
  static func circularFallbackAccessibilityLabel(accountDisplayName: String?) -> String
  ```
- Consumes: `AccountRef.displayName` (`apps/apple/Vigil/Support/SharedContainer.swift:243-245`), `UsageEntry.account: AccountRef?` (`apps/apple/VigilWidgets/UsageTimelineProvider.swift:76-80`).

Background: `VigilWidgets.swift:302-309` — the circular widget's fallback (no confirmed window, no metric) is a `Gauge(value: 0)` whose label is `Text("V")`, so VoiceOver announces "V, 0%": a meaningless glyph plus a percentage that is not a reading. Its three sibling branches all speak "\<display name\>, \<state\>" (lines 259-266, 277-280, 299-301). The label logic goes in `UsagePresentation` because that file is the only presentation code shared by the app target (where VigilTests runs) and the widget target — the widget extension itself cannot be imported by the unit-test bundle.

- [ ] **Step 1: Write the failing test** — create `apps/apple/VigilTests/WidgetFallbackAccessibilityTests.swift`:
  ```swift
  import XCTest
  @testable import Vigil

  /// The circular widget's fallback ring previously spoke its decorative
  /// glyph and empty gauge as "V, 0%". Its spoken surface lives in
  /// UsagePresentation, which both the widget target and this app-hosted
  /// test bundle compile, so the exact strings are provable here.
  final class WidgetFallbackAccessibilityTests: XCTestCase {
      func testCircularFallbackSpeaksUnlinkedState() {
          XCTAssertEqual(
              UsagePresentation.circularFallbackAccessibilityLabel(accountDisplayName: nil),
              "Vigil, no account linked"
          )
      }

      func testCircularFallbackSpeaksWaitingStateForALinkedAccount() {
          XCTAssertEqual(
              UsagePresentation.circularFallbackAccessibilityLabel(accountDisplayName: "Claude"),
              "Claude, waiting for first fetch"
          )
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/WidgetFallbackAccessibilityTests
  ```
  Expected failure: the test target does not compile — `type 'UsagePresentation' has no member 'circularFallbackAccessibilityLabel'`.

- [ ] **Step 3: Minimal implementation** — in `apps/apple/Vigil/Support/UsagePresentation.swift`, insert after `exactAmountsMatchUtilization` (line 20), before `title(for:)`:
  ```swift
      /// Spoken surface for the circular widget's fallback ring (no confirmed
      /// window, no metric to show). Mirrors SmallUsageView's visible copy so
      /// both families describe the state with the same words, in the
      /// "<display name>, <state>" shape of the circular family's siblings.
      static func circularFallbackAccessibilityLabel(accountDisplayName: String?) -> String {
          guard let accountDisplayName else { return "Vigil, no account linked" }
          return "\(accountDisplayName), waiting for first fetch"
      }
  ```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: both tests PASS.

- [ ] **Step 5: Wire the widget** — in `apps/apple/VigilWidgets/VigilWidgets.swift`, replace the fallback branch (lines 302-309):
  ```swift
          } else {
              Gauge(value: 0, in: 0...100) {
                  Text("V")
              } currentValueLabel: {
                  Image(systemName: "link")
              }
              .gaugeStyle(.accessoryCircularCapacity)
          }
  ```
  with (children ignored so the empty gauge's "0%" is not spoken, matching the `.accessibilityElement(children: .ignore)` pattern of the sibling branches at lines 277 and 299):
  ```swift
          } else {
              Gauge(value: 0, in: 0...100) {
                  Text("V")
              } currentValueLabel: {
                  Image(systemName: "link")
              }
              .gaugeStyle(.accessoryCircularCapacity)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                  Text(
                      UsagePresentation.circularFallbackAccessibilityLabel(
                          accountDisplayName: entry.account?.displayName
                      )
                  )
              )
          }
  ```

- [ ] **Step 6: Verify the widget target compiles**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination 'generic/platform=iOS Simulator' \
    build CODE_SIGNING_ALLOWED=NO
  ```
  Expected: BUILD SUCCEEDED (the Vigil scheme builds VigilWidgets as an embedded dependency).

- [ ] **Step 7: PR-0 exit gate — full scheme and docs check** (matches CI: docs, both app test targets):
  ```sh
  cd /Users/biscuit/Vigil && scripts/check-docs.sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
  DEVICE_UDID=$(xcrun simctl list devices available \
    | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO
  ```
  Expected: docs check passes untouched (none of the five fixes changes a documented claim — verified by grep: no doc describes the sign-in cancellation flows, the overlay copy, history-row VoiceOver labels, or widget accessibility), and the complete VigilTests + VigilUITests scheme passes.

- [ ] **Step 8: Commit**
  ```sh
  git -C /Users/biscuit/Vigil add \
    apps/apple/Vigil/Support/UsagePresentation.swift \
    apps/apple/VigilTests/WidgetFallbackAccessibilityTests.swift \
    apps/apple/VigilWidgets/VigilWidgets.swift
  git -C /Users/biscuit/Vigil commit \
    -m "Label the circular widget's unlinked fallback for VoiceOver" \
    -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```


## PR-1

### Task 6: VigilPreferences store with App Group persistence and dual-target membership
**PR:** PR-1 — preferences store + appearance system
**Files:**
- Create: `apps/apple/Vigil/Support/VigilPreferences.swift`
- Create: `apps/apple/VigilTests/VigilPreferencesTests.swift`
- Modify: `apps/apple/project.yml` (VigilWidgets `sources:` list, after line 130 `- path: Vigil/Support/UsagePresentation.swift` — mirrors the dual-membership entries for `Vigil/Support/UsageService.swift` at lines 127-130)
**Interfaces:**
- Consumes: `UserDefaults` (callers pass the App Group suite; the store never resolves a suite itself).
- Produces (canonical, fixed):
  - `@Observable final class VigilPreferences` with `enum Appearance: String { case system, light, dark; var colorScheme: ColorScheme? }`
  - `init(defaults: UserDefaults)`
  - `var appearance: Appearance`, `var alertLevels: [Int]`, `var accountAlertOverrides: [String: [Int]]`, `var pauseAllPolling: Bool`, `var pausedAccountKeys: Set<String>`, `var staleAfterMinutes: Int`, `var reduceProminentAnimations: Bool`, `var hapticsEnabled: Bool`, `var widgetRedactedWhenLocked: Bool`, `var widgetsFollowThemeOverride: Bool`
  - `func isPollingPaused(forAccountKey key: String) -> Bool`
  - `func effectiveAlertLevels(forAccountKey key: String) -> [Int]`
  - `func removeOverrides(forAccountKey key: String)`
  - `static func addingValidatedLevel(_ level: Int, to levels: [Int]) -> [Int]?`

Background for the implementer: Vigil is dark-only today and has no preferences store. This class is the foundation for the 1.0.0 Settings revamp (`docs/superpowers/specs/2026-07-30-settings-revamp-design.md` §1). It must live in BOTH the app and widget targets because the widget reads theme/redaction flags and the shared polling machinery reads pause flags. Every default reproduces current shipped behavior. The repo's `@Observable`-with-`didSet` persistence pattern already exists at `apps/apple/Vigil/AppModel.swift:95-97` (`lockEnabled`); Swift never fires `didSet` during `init`, so reads in `init` are sanitize-on-read and writes only happen on later mutation.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/VigilPreferencesTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import Vigil

final class VigilPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "vigil-preferences-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testDefaultsReproduceShippedBehavior() {
        let preferences = VigilPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.alertLevels, [80, 95])
        XCTAssertEqual(preferences.accountAlertOverrides, [:])
        XCTAssertFalse(preferences.pauseAllPolling)
        XCTAssertEqual(preferences.pausedAccountKeys, [])
        XCTAssertEqual(preferences.staleAfterMinutes, 30)
        XCTAssertFalse(preferences.reduceProminentAnimations)
        XCTAssertTrue(preferences.hapticsEnabled)
        XCTAssertFalse(preferences.widgetRedactedWhenLocked)
        XCTAssertTrue(preferences.widgetsFollowThemeOverride)
    }

    func testAppearanceMapsToColorScheme() {
        XCTAssertNil(VigilPreferences.Appearance.system.colorScheme)
        XCTAssertEqual(VigilPreferences.Appearance.light.colorScheme, .light)
        XCTAssertEqual(VigilPreferences.Appearance.dark.colorScheme, .dark)
    }

    func testCorruptStoredValuesFallBackToDefaults() {
        defaults.set("neon", forKey: "prefs.appearance")
        defaults.set("not-an-array", forKey: "prefs.alertLevels")
        defaults.set(["claude:1": "loud"], forKey: "prefs.accountAlertOverrides")
        defaults.set("yes", forKey: "prefs.pauseAllPolling")
        defaults.set(42, forKey: "prefs.pausedAccountKeys")
        defaults.set(45, forKey: "prefs.staleAfterMinutes")
        defaults.set("dim", forKey: "prefs.reduceProminentAnimations")
        defaults.set("buzz", forKey: "prefs.hapticsEnabled")
        defaults.set("hide", forKey: "prefs.widgetRedactedWhenLocked")
        defaults.set("follow", forKey: "prefs.widgetsFollowThemeOverride")

        let preferences = VigilPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.alertLevels, [80, 95])
        XCTAssertEqual(preferences.accountAlertOverrides, [:])
        XCTAssertFalse(preferences.pauseAllPolling)
        XCTAssertEqual(preferences.pausedAccountKeys, [])
        XCTAssertEqual(preferences.staleAfterMinutes, 30)
        XCTAssertFalse(preferences.reduceProminentAnimations)
        XCTAssertTrue(preferences.hapticsEnabled)
        XCTAssertFalse(preferences.widgetRedactedWhenLocked)
        XCTAssertTrue(preferences.widgetsFollowThemeOverride)
    }

    func testStoredAlertLevelsAreSanitizedOnRead() {
        defaults.set([95, 80, 80, 0, 100, 150], forKey: "prefs.alertLevels")
        let preferences = VigilPreferences(defaults: defaults)
        XCTAssertEqual(preferences.alertLevels, [80, 95])
    }

    func testAssignedValuesAreSanitized() {
        let preferences = VigilPreferences(defaults: defaults)
        preferences.alertLevels = [95, 80, 80, 0, 100]
        XCTAssertEqual(preferences.alertLevels, [80, 95])
        preferences.staleAfterMinutes = 45
        XCTAssertEqual(preferences.staleAfterMinutes, 30)
    }

    func testValuesRoundTripThroughASecondInstance() {
        let first = VigilPreferences(defaults: defaults)
        first.appearance = .dark
        first.alertLevels = [50, 90]
        first.accountAlertOverrides = ["claude:credential:abc": [70], "codex:acct-1": []]
        first.pauseAllPolling = true
        first.pausedAccountKeys = ["claude:credential:abc"]
        first.staleAfterMinutes = 60
        first.reduceProminentAnimations = true
        first.hapticsEnabled = false
        first.widgetRedactedWhenLocked = true
        first.widgetsFollowThemeOverride = false

        let second = VigilPreferences(defaults: defaults)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertEqual(second.alertLevels, [50, 90])
        XCTAssertEqual(
            second.accountAlertOverrides,
            ["claude:credential:abc": [70], "codex:acct-1": []]
        )
        XCTAssertTrue(second.pauseAllPolling)
        XCTAssertEqual(second.pausedAccountKeys, ["claude:credential:abc"])
        XCTAssertEqual(second.staleAfterMinutes, 60)
        XCTAssertTrue(second.reduceProminentAnimations)
        XCTAssertFalse(second.hapticsEnabled)
        XCTAssertTrue(second.widgetRedactedWhenLocked)
        XCTAssertFalse(second.widgetsFollowThemeOverride)
    }

    func testAddingValidatedLevelEnforcesBoundsDuplicatesAndCap() {
        XCTAssertEqual(VigilPreferences.addingValidatedLevel(50, to: [80, 95]), [50, 80, 95])
        XCTAssertNil(VigilPreferences.addingValidatedLevel(0, to: [80, 95]))
        XCTAssertNil(VigilPreferences.addingValidatedLevel(100, to: [80, 95]))
        XCTAssertNil(VigilPreferences.addingValidatedLevel(80, to: [80, 95]))
        XCTAssertNil(
            VigilPreferences.addingValidatedLevel(90, to: [10, 20, 30, 40, 50, 60, 70, 80])
        )
        XCTAssertEqual(
            VigilPreferences.addingValidatedLevel(90, to: [10, 20, 30, 40, 50, 60, 70]),
            [10, 20, 30, 40, 50, 60, 70, 90]
        )
    }

    func testEffectiveAlertLevelsPrecedence() {
        let preferences = VigilPreferences(defaults: defaults)
        XCTAssertEqual(preferences.effectiveAlertLevels(forAccountKey: "claude:a"), [80, 95])
        preferences.accountAlertOverrides["claude:a"] = [50]
        XCTAssertEqual(preferences.effectiveAlertLevels(forAccountKey: "claude:a"), [50])
        preferences.accountAlertOverrides["codex:b"] = []
        XCTAssertEqual(preferences.effectiveAlertLevels(forAccountKey: "codex:b"), [])
        XCTAssertEqual(preferences.effectiveAlertLevels(forAccountKey: "minimax:c"), [80, 95])
    }

    func testRemoveOverridesClearsOverrideAndPauseForThatAccountOnly() {
        let preferences = VigilPreferences(defaults: defaults)
        preferences.accountAlertOverrides = ["claude:a": [50], "codex:b": []]
        preferences.pausedAccountKeys = ["claude:a", "codex:b"]

        preferences.removeOverrides(forAccountKey: "claude:a")

        XCTAssertEqual(preferences.accountAlertOverrides, ["codex:b": []])
        XCTAssertEqual(preferences.pausedAccountKeys, ["codex:b"])
        let reloaded = VigilPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.accountAlertOverrides, ["codex:b": []])
        XCTAssertEqual(reloaded.pausedAccountKeys, ["codex:b"])
    }

    func testPollingPauseCombinesGlobalAndPerAccountFlags() {
        let preferences = VigilPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isPollingPaused(forAccountKey: "claude:a"))
        preferences.pausedAccountKeys = ["claude:a"]
        XCTAssertTrue(preferences.isPollingPaused(forAccountKey: "claude:a"))
        XCTAssertFalse(preferences.isPollingPaused(forAccountKey: "codex:b"))
        preferences.pauseAllPolling = true
        XCTAssertTrue(preferences.isPollingPaused(forAccountKey: "codex:b"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.** New files require regenerating the project (XcodeGen globs directories at generation time):

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/VigilPreferencesTests
```

Expected: `** TEST FAILED **` with a compile error in `VigilPreferencesTests.swift`: `cannot find 'VigilPreferences' in scope`.

- [ ] **Step 3: Minimal implementation.** Create `apps/apple/Vigil/Support/VigilPreferences.swift`:

```swift
import Foundation
import Observation
import SwiftUI

/// User-adjustable behavior preferences for the 1.0.0 Settings revamp,
/// persisted in the shared App Group defaults suite so the widget process
/// (theme, redaction) and the shared polling machinery (pause flags) read the
/// same values the app writes. Callers pass the suite; this type never
/// resolves storage itself and VigilKit never reads it.
///
/// Every default reproduces shipped behavior. Unknown or corrupt stored
/// values fall back to defaults — they never fail.
@Observable
final class VigilPreferences {
    enum Appearance: String {
        case system, light, dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    private enum Keys {
        static let appearance = "prefs.appearance"
        static let alertLevels = "prefs.alertLevels"
        static let accountAlertOverrides = "prefs.accountAlertOverrides"
        static let pauseAllPolling = "prefs.pauseAllPolling"
        static let pausedAccountKeys = "prefs.pausedAccountKeys"
        static let staleAfterMinutes = "prefs.staleAfterMinutes"
        static let reduceProminentAnimations = "prefs.reduceProminentAnimations"
        static let hapticsEnabled = "prefs.hapticsEnabled"
        static let widgetRedactedWhenLocked = "prefs.widgetRedactedWhenLocked"
        static let widgetsFollowThemeOverride = "prefs.widgetsFollowThemeOverride"
    }

    static let maximumAlertLevels = 8
    static let allowedStaleMinutes: Set<Int> = [15, 30, 60]
    private static let defaultAlertLevels = [80, 95]
    private static let defaultStaleAfterMinutes = 30

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Sorted, unique, each 1-99, at most 8. Assigning an invalid array
    /// stores its sanitized form (didSet re-enters once at the fixed point).
    var alertLevels: [Int] {
        didSet {
            let sanitized = Self.sanitizedLevels(alertLevels)
            if sanitized != alertLevels {
                alertLevels = sanitized
                return
            }
            defaults.set(alertLevels, forKey: Keys.alertLevels)
        }
    }

    /// Per-account level sets. A missing entry means "use the global levels";
    /// an empty entry means the account is muted.
    var accountAlertOverrides: [String: [Int]] {
        didSet {
            let sanitized = accountAlertOverrides.mapValues(Self.sanitizedLevels)
            if sanitized != accountAlertOverrides {
                accountAlertOverrides = sanitized
                return
            }
            defaults.set(accountAlertOverrides, forKey: Keys.accountAlertOverrides)
        }
    }

    var pauseAllPolling: Bool {
        didSet { defaults.set(pauseAllPolling, forKey: Keys.pauseAllPolling) }
    }

    var pausedAccountKeys: Set<String> {
        didSet {
            defaults.set(Array(pausedAccountKeys).sorted(), forKey: Keys.pausedAccountKeys)
        }
    }

    /// Presentation-only staleness threshold in minutes: 15, 30, or 60.
    /// Polling cadence is untouched by this value.
    var staleAfterMinutes: Int {
        didSet {
            if !Self.allowedStaleMinutes.contains(staleAfterMinutes) {
                staleAfterMinutes = Self.defaultStaleAfterMinutes
                return
            }
            defaults.set(staleAfterMinutes, forKey: Keys.staleAfterMinutes)
        }
    }

    var reduceProminentAnimations: Bool {
        didSet {
            defaults.set(reduceProminentAnimations, forKey: Keys.reduceProminentAnimations)
        }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }

    var widgetRedactedWhenLocked: Bool {
        didSet {
            defaults.set(widgetRedactedWhenLocked, forKey: Keys.widgetRedactedWhenLocked)
        }
    }

    var widgetsFollowThemeOverride: Bool {
        didSet {
            defaults.set(widgetsFollowThemeOverride, forKey: Keys.widgetsFollowThemeOverride)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.appearance = Appearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        if let storedLevels = defaults.array(forKey: Keys.alertLevels) as? [Int] {
            self.alertLevels = Self.sanitizedLevels(storedLevels)
        } else {
            self.alertLevels = Self.defaultAlertLevels
        }
        if let storedOverrides = defaults.dictionary(forKey: Keys.accountAlertOverrides) {
            self.accountAlertOverrides = storedOverrides.compactMapValues {
                ($0 as? [Int]).map(Self.sanitizedLevels)
            }
        } else {
            self.accountAlertOverrides = [:]
        }
        self.pauseAllPolling =
            defaults.object(forKey: Keys.pauseAllPolling) as? Bool ?? false
        self.pausedAccountKeys = Set(
            defaults.array(forKey: Keys.pausedAccountKeys) as? [String] ?? []
        )
        let storedStale = defaults.object(forKey: Keys.staleAfterMinutes) as? Int
            ?? Self.defaultStaleAfterMinutes
        self.staleAfterMinutes = Self.allowedStaleMinutes.contains(storedStale)
            ? storedStale
            : Self.defaultStaleAfterMinutes
        self.reduceProminentAnimations =
            defaults.object(forKey: Keys.reduceProminentAnimations) as? Bool ?? false
        self.hapticsEnabled =
            defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        self.widgetRedactedWhenLocked =
            defaults.object(forKey: Keys.widgetRedactedWhenLocked) as? Bool ?? false
        self.widgetsFollowThemeOverride =
            defaults.object(forKey: Keys.widgetsFollowThemeOverride) as? Bool ?? true
    }

    func isPollingPaused(forAccountKey key: String) -> Bool {
        pauseAllPolling || pausedAccountKeys.contains(key)
    }

    func effectiveAlertLevels(forAccountKey key: String) -> [Int] {
        accountAlertOverrides[key] ?? alertLevels
    }

    func removeOverrides(forAccountKey key: String) {
        accountAlertOverrides.removeValue(forKey: key)
        pausedAccountKeys.remove(key)
    }

    /// Validation gate for user-entered custom levels: nil when the level is
    /// outside 1...99, already present, or would exceed the 8-level cap.
    static func addingValidatedLevel(_ level: Int, to levels: [Int]) -> [Int]? {
        guard (1...99).contains(level),
              !levels.contains(level),
              levels.count < maximumAlertLevels
        else { return nil }
        return (levels + [level]).sorted()
    }

    private static func sanitizedLevels(_ levels: [Int]) -> [Int] {
        var seen = Set<Int>()
        return levels
            .filter { (1...99).contains($0) && seen.insert($0).inserted }
            .sorted()
            .prefix(maximumAlertLevels)
            .map { $0 }
    }
}
```

Then add the widget-target membership in `apps/apple/project.yml`. After line 130 (`      - path: Vigil/Support/UsagePresentation.swift` in the `VigilWidgets` target's `sources:`), add:

```yaml
      - path: Vigil/Support/VigilPreferences.swift
```

- [ ] **Step 4: Run the test to verify it passes.**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/VigilPreferencesTests
```

Expected: `** TEST SUCCEEDED **`, 10 tests passing. The build itself proves the widget target compiles `VigilPreferences.swift` (the app target embeds VigilWidgets, so the scheme builds both).

- [ ] **Step 5: Commit.**

```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/VigilPreferences.swift apps/apple/VigilTests/VigilPreferencesTests.swift apps/apple/project.yml && git commit -m "Add the VigilPreferences App Group store shared by app and widget"
```

### Task 7: Expose preferences on AppModel and clear an account's overrides on removal
**PR:** PR-1 — preferences store + appearance system
**Files:**
- Modify: `apps/apple/Vigil/AppModel.swift` (property block near line 73-84; init signature lines 148-155; init body after line 175 `self.lockEnabled = ...`; `removeAccount` in-memory clears at lines 1681-1684)
- Modify: `apps/apple/Vigil/VigilApp.swift` (add a launch-configuration enum after line 68, the close of `AppStorageNoticeLaunchConfiguration`)
- Create: `apps/apple/VigilTests/VigilPreferencesWiringTests.swift`
**Interfaces:**
- Consumes: `VigilPreferences` (Task 6), `SharedContainer.appGroupID` (`apps/apple/Vigil/Support/SharedContainer.swift:13`), `AppModel.removeAccount(_ account: AccountRef) async throws`, `InMemoryCredentialsStore` (VigilKit), `NotificationManaging`.
- Produces:
  - `AppModel.preferences: VigilPreferences` (a `let`, exposed like `lockEnabled`, constructed with the App Group defaults suite)
  - `AppModel.init` gains `preferences: VigilPreferences? = nil` (test injection, mirroring the existing `vault:` pattern)
  - `enum AppPreferencesLaunchConfiguration { static func usesEphemeralPreferencesForUITesting(environment: [String: String]) -> Bool }` (DEBUG-only UI-test hook, mirroring `AppLockLaunchConfiguration` at `VigilApp.swift:25-37`; Task 9's UI test depends on it for deterministic launches)

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/VigilPreferencesWiringTests.swift`:

```swift
import Foundation
import VigilKit
import XCTest
@testable import Vigil

final class VigilPreferencesWiringTests: XCTestCase {
    func testRemoveAccountClearsThatAccountsPreferenceOverridesOnly() async throws {
        let directory = try makeTemporaryDirectory()
        let suiteName = "vigil-prefs-wiring-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VigilPreferences(defaults: defaults)

        let removed = Credentials(providerId: "claude", accessToken: "removed-secret")
        let kept = Credentials(providerId: "deepseek", accessToken: "kept-secret")
        let removedKey = AppModel.accountKey(for: removed)
        let keptKey = AppModel.accountKey(for: kept)
        preferences.accountAlertOverrides = [removedKey: [50], keptKey: []]
        preferences.pausedAccountKeys = [removedKey, keptKey]

        let removedAccount = AccountRef(
            key: removedKey, providerId: "claude", label: nil, plan: nil
        )
        let keptAccount = AccountRef(
            key: keptKey, providerId: "deepseek", label: nil, plan: nil
        )
        try AccountIndex.save(
            [removedAccount, keptAccount],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(removed, accountKey: removedKey)
        try vault.save(kept, accountKey: keptKey)
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: WiringNoopNotificationManager(),
            preferences: preferences
        )
        model.ensureLoadedFromDisk()

        try await model.removeAccount(removedAccount)

        XCTAssertEqual(preferences.accountAlertOverrides, [keptKey: []])
        XCTAssertEqual(preferences.pausedAccountKeys, [keptKey])
        let reloaded = VigilPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.accountAlertOverrides, [keptKey: []])
        XCTAssertEqual(reloaded.pausedAccountKeys, [keptKey])
    }

    func testEphemeralPreferencesUITestHookRequiresExactOptIn() {
        XCTAssertTrue(
            AppPreferencesLaunchConfiguration.usesEphemeralPreferencesForUITesting(
                environment: ["VIGIL_UI_TEST_EPHEMERAL_PREFS": "1"]
            )
        )
        XCTAssertFalse(
            AppPreferencesLaunchConfiguration.usesEphemeralPreferencesForUITesting(
                environment: ["VIGIL_UI_TEST_EPHEMERAL_PREFS": "true"]
            )
        )
        XCTAssertFalse(
            AppPreferencesLaunchConfiguration.usesEphemeralPreferencesForUITesting(
                environment: [:]
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-prefs-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class WiringNoopNotificationManager: NotificationManaging, Sendable {
    func requestAuthorizationIfNeeded() async {}
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] { [] }
    func removeNotifications(accountKey: String) async {}
    func removeNotifications(identifiers: [String]) async {}
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/VigilPreferencesWiringTests
```

Expected: `** TEST FAILED **` with compile errors: `extra argument 'preferences' in call` (AppModel has no such parameter) and `cannot find 'AppPreferencesLaunchConfiguration' in scope`.

- [ ] **Step 3: Minimal implementation.** Three edits.

(1) In `apps/apple/Vigil/VigilApp.swift`, after line 68 (the closing brace of `AppStorageNoticeLaunchConfiguration`), add:

```swift
enum AppPreferencesLaunchConfiguration {
    /// UI automation must launch with preferences at their defaults instead
    /// of whatever an earlier run persisted to the App Group suite. Release
    /// builds never honor this override.
    static func usesEphemeralPreferencesForUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        environment["VIGIL_UI_TEST_EPHEMERAL_PREFS"] == "1"
        #else
        false
        #endif
    }
}
```

(2) In `apps/apple/Vigil/AppModel.swift`:
- After line 79 (`let notifications: any NotificationManaging`), add:

```swift
    /// User preferences (appearance, alert levels, pause flags), persisted in
    /// the shared App Group defaults suite so widgets read the same values.
    let preferences: VigilPreferences
```

- In the init signature (lines 148-155), after `scheduler: FetchScheduler? = nil,` add a new parameter line:

```swift
        preferences: VigilPreferences? = nil,
```

- In the init body, immediately after line 175 (`self.lockEnabled = UserDefaults.standard.bool(forKey: "app.vigil.lockEnabled")`), add:

```swift
        if let preferences {
            self.preferences = preferences
        } else if AppPreferencesLaunchConfiguration.usesEphemeralPreferencesForUITesting() {
            // Deterministic UI-test launches: start from defaults every time.
            let uiTestSuiteName = "app.vigil.uitest.prefs"
            let uiTestSuite = UserDefaults(suiteName: uiTestSuiteName) ?? .standard
            uiTestSuite.removePersistentDomain(forName: uiTestSuiteName)
            self.preferences = VigilPreferences(defaults: uiTestSuite)
        } else {
            self.preferences = VigilPreferences(
                defaults: UserDefaults(suiteName: SharedContainer.appGroupID) ?? .standard
            )
        }
```

(3) In `removeAccount`, after line 1684 (`officialHistoryImports[account.key] = nil`) and before the `sweepRemovedLocalState(for: account.key)` call, add:

```swift
        // A removed account's alert override and pause flag must not survive
        // to silently configure a future re-link of the same key.
        preferences.removeOverrides(forAccountKey: account.key)
```

Do NOT touch the demo-mode early return at lines 1506-1516: demo mode never persists, and `removeOverrides` writes to defaults.

- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: `** TEST SUCCEEDED **`, 2 tests passing.

- [ ] **Step 5: Guard against regressions in the existing removal suite** (the edit sits inside the most-protected method in the codebase):

```sh
cd /Users/biscuit/Vigil/apps/apple
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/AppModelReliabilityTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/AppModel.swift apps/apple/Vigil/VigilApp.swift apps/apple/VigilTests/VigilPreferencesWiringTests.swift && git commit -m "Expose VigilPreferences on AppModel and clear overrides on account removal"
```

### Task 8: Adaptive VigilPalette with WCAG-verified light theme
**PR:** PR-1 — preferences store + appearance system
**Files:**
- Modify: `apps/apple/Vigil/DesignSystem/VigilTheme.swift` (palette constants at lines 7-23; add the test hooks as an extension at the end of the file)
- Create: `apps/apple/VigilTests/VigilThemeContrastTests.swift`
**Interfaces:**
- Consumes: `UIColor(dynamicProvider:)`, `UITraitCollection(userInterfaceStyle:)`.
- Produces:
  - `VigilPalette` keeps every existing color NAME exactly (`canvas, canvasLift, surface, surfaceRaised, surfaceInset, border, borderStrong, ink, inkMuted, inkFaint, signal, safe, caution, critical`) — zero call-site churn across the 20 files that use them. Each becomes an adaptive `Color` (dark = today's values bit-for-bit, light = the values below).
  - Test hooks (app target): `extension VigilPalette { static func resolvedRGBA(_ color: Color, for scheme: ColorScheme) -> (r: Double, g: Double, b: Double, a: Double); static func contrastRatio(_ a: (r: Double, g: Double, b: Double, a: Double), _ b: (r: Double, g: Double, b: Double, a: Double)) -> Double }`

Light palette (proposed at design time, WCAG AA pre-computed — all four status colors clear 4.5:1 on both `surface` and `canvas`):

| Name | Light RGB | Name | Light RGB |
|---|---|---|---|
| canvas | (0.965, 0.969, 0.976) | ink | (0.090, 0.106, 0.133) |
| canvasLift | (0.929, 0.937, 0.949) | inkMuted | (0.345, 0.376, 0.427) |
| surface | (1.000, 1.000, 1.000) | inkFaint | (0.494, 0.525, 0.573) |
| surfaceRaised | (0.976, 0.980, 0.988) | signal | (0.345, 0.263, 0.780) |
| surfaceInset | (0.937, 0.945, 0.957) | safe | (0.043, 0.416, 0.318) |
| border | (0.827, 0.843, 0.867) | caution | (0.573, 0.380, 0.020) |
| borderStrong | (0.663, 0.690, 0.729) | critical | (0.753, 0.161, 0.208) |

Computed ratios (light): signal 6.9/6.4, safe 6.6/6.1, caution 5.3/5.0, critical 5.8/5.4 on surface/canvas. Dark keeps today's values (ratios 5.9-11.3). The tests below enforce this, not eyeballs.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/VigilThemeContrastTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import Vigil

final class VigilThemeContrastTests: XCTestCase {
    private static let statusColors: [(name: String, color: Color)] = [
        ("safe", VigilPalette.safe),
        ("caution", VigilPalette.caution),
        ("critical", VigilPalette.critical),
        ("signal", VigilPalette.signal),
    ]
    private static let backgrounds: [(name: String, color: Color)] = [
        ("surface", VigilPalette.surface),
        ("canvas", VigilPalette.canvas),
    ]

    func testDarkSchemeKeepsShippedPaletteBitForBit() {
        let expected: [(name: String, color: Color, rgb: (Double, Double, Double))] = [
            ("canvas", VigilPalette.canvas, (0.043, 0.051, 0.063)),
            ("canvasLift", VigilPalette.canvasLift, (0.075, 0.086, 0.106)),
            ("surface", VigilPalette.surface, (0.086, 0.102, 0.125)),
            ("surfaceRaised", VigilPalette.surfaceRaised, (0.125, 0.145, 0.176)),
            ("surfaceInset", VigilPalette.surfaceInset, (0.055, 0.067, 0.082)),
            ("border", VigilPalette.border, (0.180, 0.204, 0.239)),
            ("borderStrong", VigilPalette.borderStrong, (0.286, 0.318, 0.365)),
            ("ink", VigilPalette.ink, (0.957, 0.965, 0.976)),
            ("inkMuted", VigilPalette.inkMuted, (0.667, 0.698, 0.745)),
            ("inkFaint", VigilPalette.inkFaint, (0.486, 0.522, 0.584)),
            ("signal", VigilPalette.signal, (0.616, 0.549, 1.000)),
            ("safe", VigilPalette.safe, (0.396, 0.839, 0.706)),
            ("caution", VigilPalette.caution, (0.949, 0.737, 0.400)),
            ("critical", VigilPalette.critical, (0.941, 0.424, 0.451)),
        ]
        for entry in expected {
            let resolved = VigilPalette.resolvedRGBA(entry.color, for: .dark)
            XCTAssertEqual(resolved.r, entry.rgb.0, accuracy: 0.001, entry.name)
            XCTAssertEqual(resolved.g, entry.rgb.1, accuracy: 0.001, entry.name)
            XCTAssertEqual(resolved.b, entry.rgb.2, accuracy: 0.001, entry.name)
            XCTAssertEqual(resolved.a, 1.0, accuracy: 0.001, entry.name)
        }
    }

    func testLightSchemeResolvesToTheLightPalette() {
        let canvas = VigilPalette.resolvedRGBA(VigilPalette.canvas, for: .light)
        XCTAssertEqual(canvas.r, 0.965, accuracy: 0.001)
        XCTAssertEqual(canvas.g, 0.969, accuracy: 0.001)
        XCTAssertEqual(canvas.b, 0.976, accuracy: 0.001)
        let ink = VigilPalette.resolvedRGBA(VigilPalette.ink, for: .light)
        XCTAssertEqual(ink.r, 0.090, accuracy: 0.001)
        XCTAssertEqual(ink.g, 0.106, accuracy: 0.001)
        XCTAssertEqual(ink.b, 0.133, accuracy: 0.001)
    }

    func testStatusColorsHoldWCAGAAOnSurfaceAndCanvasInBothSchemes() {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for status in Self.statusColors {
                for background in Self.backgrounds {
                    let ratio = VigilPalette.contrastRatio(
                        VigilPalette.resolvedRGBA(status.color, for: scheme),
                        VigilPalette.resolvedRGBA(background.color, for: scheme)
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "\(status.name) on \(background.name) must hold WCAG AA in \(scheme)"
                    )
                }
            }
        }
    }

    func testContrastRatioMatchesKnownAnchors() {
        let black = (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        let white = (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
        XCTAssertEqual(VigilPalette.contrastRatio(black, white), 21.0, accuracy: 0.01)
        XCTAssertEqual(VigilPalette.contrastRatio(white, white), 1.0, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (compile red).**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/VigilThemeContrastTests
```

Expected: `** TEST FAILED **` — compile error `type 'VigilPalette' has no member 'resolvedRGBA'`.

- [ ] **Step 3: Add only the test hooks, and verify a behavioral red.** At the end of `apps/apple/Vigil/DesignSystem/VigilTheme.swift`, add (and add `import UIKit` under line 1's `import SwiftUI`):

```swift
// MARK: - Palette test hooks

extension VigilPalette {
    /// Resolves any palette color to concrete sRGB components for one scheme.
    /// Test-facing: contrast is enforced by computation, not eyeballs.
    static func resolvedRGBA(
        _ color: Color,
        for scheme: ColorScheme
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    /// WCAG 2.1 contrast ratio from relative luminance (sRGB linearization).
    static func contrastRatio(
        _ a: (r: Double, g: Double, b: Double, a: Double),
        _ b: (r: Double, g: Double, b: Double, a: Double)
    ) -> Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.03928
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        func luminance(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Double {
            0.2126 * linearized(c.r)
                + 0.7152 * linearized(c.g)
                + 0.0722 * linearized(c.b)
        }
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
```

Re-run the Step 2 command. Expected: `** TEST FAILED **` — now a genuine behavioral red: `testLightSchemeResolvesToTheLightPalette` fails (the palette is still single-valued dark, so light `canvas.r` resolves to 0.043, not 0.965). `testContrastRatioMatchesKnownAnchors` and `testDarkSchemeKeepsShippedPaletteBitForBit` already pass, proving the hooks.

- [ ] **Step 4: Make the palette adaptive.** In `apps/apple/Vigil/DesignSystem/VigilTheme.swift`, replace the fourteen constant declarations (current lines 8-23) inside `enum VigilPalette` with:

```swift
    /// One adaptive pair per palette name, resolved through the trait
    /// environment. Dark is the shipped palette bit-for-bit; light is the
    /// 1.0.0 light theme. Names never change, so call sites do not churn.
    private static func adaptive(
        light: (r: Double, g: Double, b: Double),
        dark: (r: Double, g: Double, b: Double)
    ) -> Color {
        Color(UIColor { traits in
            let values = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: values.r, green: values.g, blue: values.b, alpha: 1)
        })
    }

    static let canvas = adaptive(
        light: (0.965, 0.969, 0.976), dark: (0.043, 0.051, 0.063)
    )
    static let canvasLift = adaptive(
        light: (0.929, 0.937, 0.949), dark: (0.075, 0.086, 0.106)
    )
    static let surface = adaptive(
        light: (1.000, 1.000, 1.000), dark: (0.086, 0.102, 0.125)
    )
    static let surfaceRaised = adaptive(
        light: (0.976, 0.980, 0.988), dark: (0.125, 0.145, 0.176)
    )
    static let surfaceInset = adaptive(
        light: (0.937, 0.945, 0.957), dark: (0.055, 0.067, 0.082)
    )
    static let border = adaptive(
        light: (0.827, 0.843, 0.867), dark: (0.180, 0.204, 0.239)
    )
    static let borderStrong = adaptive(
        light: (0.663, 0.690, 0.729), dark: (0.286, 0.318, 0.365)
    )

    static let ink = adaptive(
        light: (0.090, 0.106, 0.133), dark: (0.957, 0.965, 0.976)
    )
    static let inkMuted = adaptive(
        light: (0.345, 0.376, 0.427), dark: (0.667, 0.698, 0.745)
    )
    static let inkFaint = adaptive(
        light: (0.494, 0.525, 0.573), dark: (0.486, 0.522, 0.584)
    )

    static let signal = adaptive(
        light: (0.345, 0.263, 0.780), dark: (0.616, 0.549, 1.000)
    )
    static let safe = adaptive(
        light: (0.043, 0.416, 0.318), dark: (0.396, 0.839, 0.706)
    )
    static let caution = adaptive(
        light: (0.573, 0.380, 0.020), dark: (0.949, 0.737, 0.400)
    )
    static let critical = adaptive(
        light: (0.753, 0.161, 0.208), dark: (0.941, 0.424, 0.451)
    )
```

Leave `limitColor(utilization:)` and `statusColor(_:)` (lines 25-38) untouched — they return the adaptive colors by name.

- [ ] **Step 5: Run the test to verify it passes.** Same command as Step 2. Expected: `** TEST SUCCEEDED **`, 4 tests. Then run the full unit bundle once (`-only-testing:VigilTests`) to confirm no other test asserted on palette values. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/DesignSystem/VigilTheme.swift apps/apple/VigilTests/VigilThemeContrastTests.swift && git commit -m "Make VigilPalette adaptive with a WCAG-AA-verified light theme"
```

### Task 9: Root color-scheme swap and the Settings Appearance control
**PR:** PR-1 — preferences store + appearance system
**Files:**
- Modify: `apps/apple/Vigil/VigilApp.swift:135` (`.preferredColorScheme(.dark)`)
- Modify: `apps/apple/Vigil/RootView.swift:23` (`.preferredColorScheme(.dark)`) and add the model environment at line 10
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (insert an Appearance section before the `settingsSection("Security")` block at line 24; add a private control builder near `adaptiveToggle` at line 237)
- Create: `apps/apple/VigilUITests/VigilSettingsAppearanceUITests.swift`
- Modify: `docs/product-contract.md:17` (Settings controls sentence) — docs land with the behavior per the repo maintenance rule
**Interfaces:**
- Consumes: `AppModel.preferences` (Task 7), `VigilPreferences.Appearance.colorScheme` (Task 6), `AppPreferencesLaunchConfiguration` env hook `VIGIL_UI_TEST_EPHEMERAL_PREFS` (Task 7), UI-test launch conventions from `apps/apple/VigilUITests/VigilAccessibilityUITests.swift:193-217` (`VIGIL_TAB`, `VIGIL_DEMO`, `VIGIL_UI_TEST_FORCE_ACTIVE`, `VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE`).
- Produces: root scenes render `.preferredColorScheme(model.preferences.appearance.colorScheme)` (nil = follow system — this is the one deliberate default change named in the spec §Non-negotiable invariants); a segmented System/Light/Dark control with accessibility identifier `vigil.settings.appearance`.

- [ ] **Step 1: Write the failing UI test.** Create `apps/apple/VigilUITests/VigilSettingsAppearanceUITests.swift`:

```swift
import XCTest

final class VigilSettingsAppearanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = nil
    }

    func testAppearanceControlOffersSpokenSystemLightDarkChoices() {
        launchSettings()

        let picker = app.descendants(matching: .any)["vigil.settings.appearance"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            "Settings must expose the appearance control."
        )
        for choice in ["System", "Light", "Dark"] {
            XCTAssertTrue(
                picker.buttons[choice].exists,
                "The appearance control must speak the \(choice) choice."
            )
        }
        XCTAssertTrue(
            picker.buttons["System"].isSelected,
            "A fresh launch must default to following the system appearance."
        )

        picker.buttons["Light"].tap()
        XCTAssertTrue(
            picker.buttons["Light"].isSelected,
            "Choosing Light must select the Light segment."
        )
    }

    private func launchSettings() {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_TAB"] = "settings"
        app.launchEnvironment["VIGIL_DEMO"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_EPHEMERAL_PREFS"] = "1"
        app.launch()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilUITests/VigilSettingsAppearanceUITests
```

Expected: `** TEST FAILED **` — assertion "Settings must expose the appearance control." (the identifier does not exist yet).

- [ ] **Step 3: Minimal implementation.** Three edits.

(1) `apps/apple/Vigil/VigilApp.swift:135` — replace:

```swift
            .preferredColorScheme(.dark)
```

with:

```swift
            .preferredColorScheme(model.preferences.appearance.colorScheme)
```

(2) `apps/apple/Vigil/RootView.swift` — after line 9 (`struct RootView: View {`) add:

```swift
    @Environment(AppModel.self) private var model
```

and replace line 23 (`.preferredColorScheme(.dark)`) with:

```swift
        .preferredColorScheme(model.preferences.appearance.colorScheme)
```

(3) `apps/apple/Vigil/Settings/SettingsView.swift` — inside the `VStack` at line 23, BEFORE the `settingsSection("Security")` block (line 24), insert:

```swift
                    settingsSection("Appearance") {
                        appearanceControl
                    }

```

and after the `adaptiveToggle` helper (after line 261's closing brace), add:

```swift
    private var appearanceControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "Appearance",
                selection: Binding(
                    get: { model.preferences.appearance },
                    set: { model.preferences.appearance = $0 }
                )
            ) {
                Text("System").tag(VigilPreferences.Appearance.system)
                Text("Light").tag(VigilPreferences.Appearance.light)
                Text("Dark").tag(VigilPreferences.Appearance.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Appearance")
            .accessibilityIdentifier("vigil.settings.appearance")

            Text("System follows this iPhone's appearance. Light and Dark pin Vigil's theme.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .vigilInsetSurface()
    }
```

- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: `** TEST SUCCEEDED **`, 1 test. Also run `-only-testing:VigilUITests/VigilAccessibilityUITests` to confirm the inserted section did not break scroll-reachability of `vigil.settings.exportDiagnostics` at accessibility sizes. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Docs in the same change.** In `docs/product-contract.md`, replace line 17:

```
5. Accounts and Settings contain setup, removal, security, and diagnostics controls.
```

with:

```
5. Accounts and Settings contain setup, removal, security, appearance, and diagnostics controls. Appearance follows the system by default, with Light and Dark overrides.
```

Bump line 7's `> Last reviewed: 2026-07-26` to `> Last reviewed: 2026-07-30`. Then verify:

```sh
cd /Users/biscuit/Vigil && scripts/check-docs.sh
```

Expected: exit 0.

- [ ] **Step 6: Commit.**

```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/VigilApp.swift apps/apple/Vigil/RootView.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilUITests/VigilSettingsAppearanceUITests.swift docs/product-contract.md && git commit -m "Replace the pinned dark scheme with the user's appearance preference"
```

### Task 10: Widget rendering honors the appearance override
**PR:** PR-1 — preferences store + appearance system
**Files:**
- Modify: `apps/apple/Vigil/Support/VigilPreferences.swift` (add the shared `WidgetThemeResolution` decision enum — this file is a member of both targets, so the logic is unit-testable from VigilTests and callable from the widget)
- Modify: `apps/apple/VigilWidgets/VigilWidgets.swift` (the `UsageWidget` configuration closure at lines 12-26)
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (reload widget timelines when appearance changes)
- Create: `apps/apple/VigilTests/WidgetThemeResolutionTests.swift`
- Modify: `docs/user-guide/privacy-deletion-notifications.md` (§App lock and widgets, after line 61)
**Interfaces:**
- Consumes: `VigilPreferences(defaults:)`, `VigilPreferences.Appearance.colorScheme`, `widgetsFollowThemeOverride` (default true), `SharedContainer.appGroupID`, `WidgetCenter.shared.reloadAllTimelines()` (same call AppModel's private `reloadWidgets()` makes at `AppModel.swift:2393`).
- Produces: `enum WidgetThemeResolution { static func forcedColorScheme(appearance: VigilPreferences.Appearance, followsThemeOverride: Bool) -> ColorScheme? }` — nil means "follow the system". Widget content (both families use semantic and environment-resolved colors, verified by reading `VigilWidgets.swift`: `.orange`, `.secondary`, `.primary`, `.fill.tertiary`) renders under the forced scheme via `.environment(\.colorScheme, ...)`.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/WidgetThemeResolutionTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import Vigil

final class WidgetThemeResolutionTests: XCTestCase {
    func testWidgetsFollowTheAppearanceOverrideOnlyWhenAllowed() {
        XCTAssertNil(
            WidgetThemeResolution.forcedColorScheme(
                appearance: .system,
                followsThemeOverride: true
            ),
            "System appearance never forces a widget scheme."
        )
        XCTAssertEqual(
            WidgetThemeResolution.forcedColorScheme(
                appearance: .light,
                followsThemeOverride: true
            ),
            .light
        )
        XCTAssertEqual(
            WidgetThemeResolution.forcedColorScheme(
                appearance: .dark,
                followsThemeOverride: true
            ),
            .dark
        )
        XCTAssertNil(
            WidgetThemeResolution.forcedColorScheme(
                appearance: .dark,
                followsThemeOverride: false
            ),
            "Opting out pins widgets to the system appearance."
        )
        XCTAssertNil(
            WidgetThemeResolution.forcedColorScheme(
                appearance: .light,
                followsThemeOverride: false
            )
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/WidgetThemeResolutionTests
```

Expected: `** TEST FAILED **` — compile error `cannot find 'WidgetThemeResolution' in scope`.

- [ ] **Step 3: Minimal implementation of the decision.** At the end of `apps/apple/Vigil/Support/VigilPreferences.swift`, add:

```swift
/// Widget-facing theme decision, shared by the app and widget targets.
/// Kept beside VigilPreferences so both processes agree on one rule.
enum WidgetThemeResolution {
    /// The color scheme a widget must force, or nil to follow the system.
    /// Widgets follow the in-app override only while the user keeps
    /// "Widgets follow theme override" on (the default).
    static func forcedColorScheme(
        appearance: VigilPreferences.Appearance,
        followsThemeOverride: Bool
    ) -> ColorScheme? {
        guard followsThemeOverride else { return nil }
        return appearance.colorScheme
    }
}
```

- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: `** TEST SUCCEEDED **`, 1 test.

- [ ] **Step 5: Apply the decision in the widget.** In `apps/apple/VigilWidgets/VigilWidgets.swift`, replace the `UsageWidget` struct (lines 12-26) with:

```swift
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "app.vigil.usage",
            intent: SelectUsageAccountIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            ThemedUsageWidgetRoot(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("Monitor a selected account's limits, spend, or balance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Applies the app's Appearance choice to widget rendering while the user
/// keeps "Widgets follow theme override" on (the default). Reads the same
/// App Group preferences the app writes. A System appearance, a disabled
/// override, or an unavailable suite leaves the widget on the system scheme.
private struct ThemedUsageWidgetRoot: View {
    @Environment(\.colorScheme) private var systemScheme
    let entry: UsageEntry

    private var forcedScheme: ColorScheme? {
        let preferences = VigilPreferences(
            defaults: UserDefaults(suiteName: SharedContainer.appGroupID) ?? .standard
        )
        return WidgetThemeResolution.forcedColorScheme(
            appearance: preferences.appearance,
            followsThemeOverride: preferences.widgetsFollowThemeOverride
        )
    }

    var body: some View {
        UsageWidgetEntryView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
            .environment(\.colorScheme, forcedScheme ?? systemScheme)
    }
}
```

Then make the app re-render widgets when the choice changes. In `apps/apple/Vigil/Settings/SettingsView.swift`, add under line 3 (`import UniformTypeIdentifiers`):

```swift
#if canImport(WidgetKit)
import WidgetKit
#endif
```

and attach to the `ZStack` modifier chain, directly after the `.toolbarBackground(.visible, for: .navigationBar)` line:

```swift
        .onChange(of: model.preferences.appearance) {
            #if canImport(WidgetKit)
            // Widgets read the App Group preference at render time; ask
            // WidgetKit for a re-render so the theme change is not deferred
            // to the next scheduled timeline.
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
```

- [ ] **Step 6: Verify both targets build and the whole suite is green** (widget views have no host test bundle — the build is the compile-level check, and CI runs exactly this):

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **` for the complete scheme (VigilTests + VigilUITests). Visual widget rendering in both schemes cannot be asserted from XCTest; per the spec §9 it is checked during the physical-device release walk — note it in the walk checklist when PR-1 merges.

- [ ] **Step 7: Docs in the same change.** In `docs/user-guide/privacy-deletion-notifications.md`, after line 61 ("The lock protects the app surface. ... Remove the widget if quota information should not remain visible outside the app."), add a new paragraph:

```
Widgets render in Vigil's chosen appearance (System, Light, or Dark) by default. This affects colors only; it never changes what data a widget shows.
```

Bump line 5's `> Last reviewed: 2026-07-26` to `> Last reviewed: 2026-07-30`, then run `cd /Users/biscuit/Vigil && scripts/check-docs.sh`. Expected: exit 0.

- [ ] **Step 8: Commit.**

```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/VigilPreferences.swift apps/apple/VigilWidgets/VigilWidgets.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/WidgetThemeResolutionTests.swift docs/user-guide/privacy-deletion-notifications.md && git commit -m "Render widgets under the appearance override when widgets follow the theme"
```


## PR-2

### Task 11: UsageService resolves per-account effective alert levels into ThresholdEngine

**PR:** PR-2 — alerts + refresh/pause/staleness

**Files:**
- Modify: `apps/apple/Vigil/Support/UsageService.swift` (parameter list at line 107, crossings call at lines 456–458)
- Modify: `apps/apple/Vigil/AppModel.swift` (the `UsageService.refresh` call inside `private func refresh(account:surface:bypassPollFloor:)`, lines 2128–2141)
- Modify: `apps/apple/VigilWidgets/UsageTimelineProvider.swift` (`timeline(for:in:)`, preferences construction near line 123, refresh call at lines 151–162)
- Test: `apps/apple/VigilTests/UsageServiceAlertLevelTests.swift` (new)

**Interfaces:**
- Consumes: `VigilPreferences.effectiveAlertLevels(forAccountKey:) -> [Int]` and `init(defaults: UserDefaults)` (PR-1 store, member of both targets), `AppModel.preferences: VigilPreferences` (PR-1), `ThresholdEngine.crossings(previous:current:thresholds:)` (VigilKit, parameter already exists — VigilKit does not change), `SharedContainer.appGroupID`.
- Produces: `UsageService.refresh(...)` gains `preferences: VigilPreferences? = nil` (inserted after `bypassPollFloor`); `nil` preserves today's `ThresholdEngine.defaultThresholds` behavior for the verify path and all existing tests.

Line anchors are from the current tree; re-verify with a quick read before editing.

- [ ] **Step 1: Write the failing tests** — create `apps/apple/VigilTests/UsageServiceAlertLevelTests.swift`. Three scenarios: default levels reproduce shipped behavior, a per-account override replaces the global set, and an empty override mutes the account. Events are asserted through the `PendingEventStore` that `UsageService.refresh` parks crossings into.

```swift
import Foundation
import XCTest
import VigilKit
@testable import Vigil

@MainActor
final class UsageServiceAlertLevelTests: XCTestCase {
    func testDefaultLevelsReproduceShippedBehavior() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        AlertLevelStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 85).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        try seedPreviousSnapshot(utilization: 79, account: account, directory: directory)
        let pending = PendingEventStore(directory: directory)

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "alert-default-test",
            session: session,
            preferences: prefs,
            pendingEvents: pending
        )

        XCTAssertEqual(result.snapshot?.status, .ok)
        XCTAssertEqual(
            try pending.load(accountKey: account.key).map(\.threshold),
            [80],
            "Default preferences [80, 95] must fire exactly the shipped crossing"
        )
    }

    func testAccountOverrideLevelsReplaceTheGlobalSet() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        AlertLevelStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 92).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        // Global carries a custom 86 level; the override carries only 90.
        // 85 -> 92 crosses both, so the fired set proves which one applied.
        prefs.alertLevels = [86]
        prefs.accountAlertOverrides = [account.key: [90]]
        try seedPreviousSnapshot(utilization: 85, account: account, directory: directory)
        let pending = PendingEventStore(directory: directory)

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "alert-override-test",
            session: session,
            preferences: prefs,
            pendingEvents: pending
        )

        XCTAssertEqual(result.snapshot?.status, .ok)
        XCTAssertEqual(
            try pending.load(accountKey: account.key).map(\.threshold),
            [90],
            "An account override must fully replace the global levels"
        )
    }

    func testMutedOverrideFiresNothing() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        AlertLevelStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 96).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        prefs.accountAlertOverrides = [account.key: []]
        try seedPreviousSnapshot(utilization: 79, account: account, directory: directory)
        let pending = PendingEventStore(directory: directory)

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "alert-muted-test",
            session: session,
            preferences: prefs,
            pendingEvents: pending
        )

        XCTAssertEqual(result.snapshot?.status, .ok, "Muting alerts must not stop the fetch itself")
        XCTAssertTrue(
            try pending.load(accountKey: account.key).isEmpty,
            "An empty override means muted: 79 -> 96 crosses 80 and 95 but must fire nothing"
        )
    }

    // MARK: - Fixture

    private static func makeCodexFixture() -> (AccountRef, Credentials, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlertLevelStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = Credentials(
            providerId: "codex",
            accessToken: "alert-level-access",
            accountId: "acct-alert-levels"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "codex",
            label: nil,
            plan: nil
        )
        return (account, credentials, session)
    }

    /// The codex mapper produces one "session" window from `used_percent`
    /// with `reset_at` as its boundary. The previous snapshot must reuse the
    /// same reset second or ThresholdEngine treats it as a new cycle.
    private static func codexBody(usedPercent: Double) -> String {
        """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": \(usedPercent),
              "reset_at": 1785268800,
              "limit_window_seconds": 18000
            },
            "secondary_window": null
          },
          "spend_control": {
            "reached": false,
            "individual_limit": null
          },
          "code_review_rate_limit": null
        }
        """
    }

    private func seedPreviousSnapshot(
        utilization: Double,
        account: AccountRef,
        directory: URL
    ) throws {
        let previous = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: Date().addingTimeInterval(-120),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: utilization,
                    resetsAt: Date(timeIntervalSince1970: 1_785_268_800),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
        try SnapshotStore(directory: directory).save(previous, accountKey: account.key)
    }

    private func makeScratchPreferences() throws -> VigilPreferences {
        let suiteName = "vigil-alert-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return VigilPreferences(defaults: defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilAlertLevelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class AlertLevelStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedStatus = 200
    private static var storedBody = Data()
    private static var storedCount = 0

    static var requestCount: Int { lock.withLock { storedCount } }

    static func reset(statusCode: Int, body: Data) {
        lock.withLock {
            storedStatus = statusCode
            storedBody = body
            storedCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.storedCount += 1
            return (Self.storedStatus, Self.storedBody)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/UsageServiceAlertLevelTests
```

Expected: **BUILD FAILED** with `extra argument 'preferences' in call` at each `UsageService.refresh(` call in the new test — the parameter does not exist yet.

- [ ] **Step 3: Minimal implementation** — three edits.

(a) `apps/apple/Vigil/Support/UsageService.swift`, in the `refresh` parameter list after line 107 (`bypassPollFloor: Bool = false,`), insert:

```swift
        /// App/widget preference surface. When present, the account's
        /// effective alert levels feed ThresholdEngine (and the pause task
        /// consults the pause flags before any ledger or network work). nil —
        /// link verification and existing tests — keeps
        /// ThresholdEngine.defaultThresholds and never pauses.
        preferences: VigilPreferences? = nil,
```

Then replace the crossings call at lines 456–458:

```swift
        let events = emitThresholdEvents
            ? ThresholdEngine.crossings(previous: previous, current: snapshot)
            : []
```

with:

```swift
        let events = emitThresholdEvents
            ? ThresholdEngine.crossings(
                previous: previous,
                current: snapshot,
                thresholds: preferences?.effectiveAlertLevels(forAccountKey: account.key)
                    ?? ThresholdEngine.defaultThresholds
            )
            : []
```

(b) `apps/apple/Vigil/AppModel.swift`, in the `UsageService.refresh` call inside `private func refresh(account:surface:bypassPollFloor:)` (lines 2128–2141), insert after `bypassPollFloor: bypassPollFloor,`:

```swift
                bypassPollFloor: bypassPollFloor,
                preferences: preferences,
```

Deliberately do **not** touch `AppModel.verify` (line 1480): link verification passes `emitThresholdEvents: false` and must never be pause-gated, so it keeps `preferences: nil`.

(c) `apps/apple/VigilWidgets/UsageTimelineProvider.swift`, in `timeline(for:in:)` after `let now = Date()` (line 123), insert:

```swift
        // The widget is an automatic surface: it must respect the same
        // per-account alert levels (and, from the pause task, pause flags)
        // as the app's timer and background paths.
        let preferences = VigilPreferences(
            defaults: UserDefaults(suiteName: SharedContainer.appGroupID) ?? .standard
        )
```

and add to the `UsageService.refresh` call (lines 151–162), after `surface: "widget",`:

```swift
                        surface: "widget",
                        preferences: preferences,
```

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expected: **TEST SUCCEEDED**, all three `UsageServiceAlertLevelTests` pass. Also run the neighboring suite to prove no regression in existing `UsageService.refresh` callers: rerun with `-only-testing:VigilTests/AppModelReliabilityTests`; expected pass.

- [ ] **Step 5: Commit**

```sh
cd /Users/biscuit/Vigil
git add apps/apple/Vigil/Support/UsageService.swift \
  apps/apple/Vigil/AppModel.swift \
  apps/apple/VigilWidgets/UsageTimelineProvider.swift \
  apps/apple/VigilTests/UsageServiceAlertLevelTests.swift
git commit -m "Resolve per-account effective alert levels into threshold crossings" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Global alert-level management UI (presets, custom entry, cap and bounds messaging)

**PR:** PR-2 — alerts + refresh/pause/staleness

**Files:**
- Create: `apps/apple/Vigil/Settings/AlertLevelsView.swift`
- Create: `apps/apple/VigilUITests/VigilAlertSettingsUITests.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (insert an Alerts section between the "Privacy" section closing at line 92 and the "Refresh" section starting at line 94)
- Modify: `apps/apple/Vigil/AppModel.swift` (UI-test preference reset hook in `init`, after `seedDemoDataIfRequested()` at line 193)
- Test: `apps/apple/VigilTests/AlertLevelEntryTests.swift` (new)

**Interfaces:**
- Consumes: `VigilPreferences.alertLevels: [Int]`, `static func addingValidatedLevel(_ level: Int, to levels: [Int]) -> [Int]?` (PR-1 store — the single validator; this task never re-implements the bounds/dedup/sort/cap rules), `AppModel.preferences`.
- Produces: `enum AlertLevelEntry { static let presets: [Int]; enum Outcome: Equatable { case added([Int]); case rejected(String) }; static func adding(_ text: String, to levels: [Int]) -> Outcome }`, `struct AlertLevelListEditor: View` (reused by Task 13), `struct AlertLevelsView: View`, launch-env hook `VIGIL_UI_TEST_RESET_PREFS`.

- [ ] **Step 1: Write the failing unit tests for the entry messaging** — create `apps/apple/VigilTests/AlertLevelEntryTests.swift`:

```swift
import XCTest
@testable import Vigil

final class AlertLevelEntryTests: XCTestCase {
    func testRejectsNonNumericAndOutOfRangeEntriesWithBoundsMessage() {
        let message = "Enter a whole percentage from 1 to 99."
        for text in ["", "abc", "0", "100", "-5", "12.5"] {
            XCTAssertEqual(
                AlertLevelEntry.adding(text, to: [80, 95]),
                .rejected(message),
                "\"\(text)\" must be rejected with the 1-99 bounds message"
            )
        }
    }

    func testRejectsDuplicateWithSpecificMessage() {
        XCTAssertEqual(
            AlertLevelEntry.adding("80", to: [80, 95]),
            .rejected("80% is already an alert level.")
        )
        XCTAssertEqual(
            AlertLevelEntry.adding(" 95 ", to: [80, 95]),
            .rejected("95% is already an alert level."),
            "Whitespace must be trimmed before validation"
        )
    }

    func testRejectsNinthLevelWithCapMessage() {
        let eight = [10, 20, 30, 40, 50, 60, 70, 80]
        XCTAssertEqual(
            AlertLevelEntry.adding("45", to: eight),
            .rejected("At most 8 alert levels can be active. Remove one first.")
        )
    }

    func testAddsValidLevelSortedAndUnique() {
        XCTAssertEqual(
            AlertLevelEntry.adding("66", to: [80, 95]),
            .added([66, 80, 95]),
            "The store validator sorts, so 66 lands before 80"
        )
        XCTAssertEqual(AlertLevelEntry.adding("1", to: []), .added([1]))
        XCTAssertEqual(AlertLevelEntry.adding("99", to: [50]), .added([50, 99]))
    }

    func testPresetsMatchTheSpec() {
        XCTAssertEqual(AlertLevelEntry.presets, [50, 80, 90, 95])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/AlertLevelEntryTests
```

Expected: **BUILD FAILED** with `cannot find 'AlertLevelEntry' in scope`.

- [ ] **Step 3: Minimal implementation of the pure logic** — create `apps/apple/Vigil/Settings/AlertLevelsView.swift` starting with only the entry logic (the view arrives in Step 7):

```swift
import SwiftUI
import VigilKit

/// Pure entry validation for typed custom alert levels. The store's
/// `addingValidatedLevel` is the single validator (bounds, dedup, sort, cap);
/// this wrapper only maps each rejection to its user-facing message so the
/// copy is unit-testable without SwiftUI.
enum AlertLevelEntry {
    /// The four familiar presets shown as toggles (spec section 3).
    static let presets = [50, 80, 90, 95]

    enum Outcome: Equatable {
        case added([Int])
        case rejected(String)
    }

    static func adding(_ text: String, to levels: [Int]) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let level = Int(trimmed), (1...99).contains(level) else {
            return .rejected("Enter a whole percentage from 1 to 99.")
        }
        if levels.contains(level) {
            return .rejected("\(level)% is already an alert level.")
        }
        guard let updated = VigilPreferences.addingValidatedLevel(level, to: levels) else {
            // Bounds and duplicates were pre-checked, so the only remaining
            // rejection from the store validator is the 8-level cap.
            return .rejected("At most 8 alert levels can be active. Remove one first.")
        }
        return .added(updated)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expected: **TEST SUCCEEDED**, all five `AlertLevelEntryTests` pass.

- [ ] **Step 5: Write the failing UI walk** — create `apps/apple/VigilUITests/VigilAlertSettingsUITests.swift` (repo conventions: `VIGIL_TAB`, `VIGIL_DEMO`, force-active, storage-notice suppression — see `VigilAccessibilityUITests.launch`):

```swift
import XCTest

final class VigilAlertSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = nil
    }

    func testPresetTogglesAndPlainMutedLabel() {
        launchAlertSettings()

        let preset80 = app.switches["vigil.settings.alerts.preset.80"]
        let preset95 = app.switches["vigil.settings.alerts.preset.95"]
        XCTAssertTrue(preset80.waitForExistence(timeout: 5))
        XCTAssertTrue(preset95.exists)

        preset80.tap()
        preset95.tap()
        XCTAssertTrue(
            app.staticTexts["vigil.settings.alerts.none"].waitForExistence(timeout: 5),
            "All levels off must be labeled plainly: No usage alerts will fire."
        )

        let preset50 = app.switches["vigil.settings.alerts.preset.50"]
        preset50.tap()
        XCTAssertFalse(
            app.staticTexts["vigil.settings.alerts.none"].waitForExistence(timeout: 2),
            "Re-enabling any level must clear the muted label"
        )
    }

    func testAddDuplicateAndDeleteCustomLevel() {
        launchAlertSettings()

        let field = app.textFields["vigil.settings.alerts.custom.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("66")
        app.buttons["vigil.settings.alerts.custom.add"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["vigil.settings.alerts.custom.66"]
                .waitForExistence(timeout: 5),
            "A valid custom level must appear as a deletable row"
        )

        field.tap()
        field.typeText("66")
        app.buttons["vigil.settings.alerts.custom.add"].tap()
        XCTAssertTrue(
            app.staticTexts["66% is already an alert level."].waitForExistence(timeout: 5),
            "A duplicate entry must show the duplicate message"
        )

        app.buttons["vigil.settings.alerts.custom.66.delete"].tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["vigil.settings.alerts.custom.66"]
                .waitForExistence(timeout: 2),
            "Deleting a custom level must remove its row"
        )
    }

    private func launchAlertSettings() {
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_TAB"] = "settings"
        app.launchEnvironment["VIGIL_DEMO"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
        // Preference writes persist in the App Group suite; reset so every
        // walk starts from the shipped defaults.
        app.launchEnvironment["VIGIL_UI_TEST_RESET_PREFS"] = "1"
        app.launch()

        let alerts = app.descendants(matching: .any)["vigil.settings.alerts"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 8), "Settings must link to the Alerts screen")
        alerts.tap()
        XCTAssertTrue(app.navigationBars["Usage Alerts"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 6: Run the UI test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilUITests/VigilAlertSettingsUITests
```

Expected: **TEST FAILED** — `Settings must link to the Alerts screen` (`vigil.settings.alerts` does not exist yet).

- [ ] **Step 7: Minimal implementation of the views and hooks** — three edits.

(a) Append to `apps/apple/Vigil/Settings/AlertLevelsView.swift` (below `AlertLevelEntry`):

```swift
/// Reusable level list + typed-entry editor. Task 13 rebinds it to a
/// per-account override array; here it edits the global set.
struct AlertLevelListEditor: View {
    @Binding var levels: [Int]
    let identifierPrefix: String
    /// Levels rendered elsewhere (the preset toggles) so they are not shown
    /// twice. Deleting a preset happens through its toggle.
    var hiddenLevels: [Int] = []

    @State private var entryText = ""
    @State private var entryMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            ForEach(levels.filter { !hiddenLevels.contains($0) }, id: \.self) { level in
                HStack {
                    Text("\(level)%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                    Spacer()
                    Button {
                        levels.removeAll { $0 == level }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(VigilPalette.critical)
                    }
                    .accessibilityLabel("Delete the \(level) percent alert level")
                    .accessibilityIdentifier("\(identifierPrefix).\(level).delete")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityIdentifier("\(identifierPrefix).\(level)")
            }

            HStack(spacing: 10) {
                TextField("1–99", text: $entryText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .accessibilityLabel("New alert level percentage")
                    .accessibilityIdentifier("\(identifierPrefix).field")
                Button("Add custom level") { add() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.signal)
                    .accessibilityIdentifier("\(identifierPrefix).add")
            }
            .padding(.horizontal, 14)

            if let entryMessage {
                Text(entryMessage)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .accessibilityIdentifier("\(identifierPrefix).message")
            }
        }
        .padding(.vertical, 10)
        .vigilInsetSurface()
    }

    private func add() {
        switch AlertLevelEntry.adding(entryText, to: levels) {
        case .added(let updated):
            levels = updated
            entryText = ""
            entryMessage = nil
        case .rejected(let message):
            entryMessage = message
        }
    }
}

struct AlertLevelsView: View {
    @Environment(AppModel.self) private var model
    @State private var presetCapMessage: String?

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    VStack(alignment: .leading, spacing: VigilSpacing.small) {
                        Text("Global levels")
                            .font(.headline)
                            .foregroundStyle(VigilPalette.ink)

                        VStack(spacing: 0) {
                            ForEach(AlertLevelEntry.presets, id: \.self) { preset in
                                Toggle("\(preset)%", isOn: presetBinding(preset))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(VigilPalette.ink)
                                    .padding(14)
                                    .accessibilityIdentifier("vigil.settings.alerts.preset.\(preset)")
                                if preset != AlertLevelEntry.presets.last {
                                    Divider().overlay(VigilPalette.border.opacity(0.7))
                                }
                            }
                        }
                        .vigilInsetSurface()

                        if let presetCapMessage {
                            Text(presetCapMessage)
                                .font(.caption)
                                .foregroundStyle(VigilPalette.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        AlertLevelListEditor(
                            levels: Binding(
                                get: { model.preferences.alertLevels },
                                set: { model.preferences.alertLevels = $0 }
                            ),
                            identifierPrefix: "vigil.settings.alerts.custom",
                            hiddenLevels: AlertLevelEntry.presets
                        )

                        if model.preferences.alertLevels.isEmpty {
                            Text("No usage alerts will fire.")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VigilPalette.caution)
                                .accessibilityIdentifier("vigil.settings.alerts.none")
                        }

                        Text("Vigil alerts locally when a usage window crosses a level between two checks. Changing levels never fires retroactively and never retracts a delivered notification.")
                            .font(.caption)
                            .foregroundStyle(VigilPalette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Task 13 inserts AccountAlertOverridesSection() here.
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Usage Alerts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func presetBinding(_ level: Int) -> Binding<Bool> {
        Binding(
            get: { model.preferences.alertLevels.contains(level) },
            set: { enabled in
                if enabled {
                    if let updated = VigilPreferences.addingValidatedLevel(
                        level,
                        to: model.preferences.alertLevels
                    ) {
                        model.preferences.alertLevels = updated
                        presetCapMessage = nil
                    } else {
                        presetCapMessage = "At most 8 alert levels can be active. Remove one first."
                    }
                } else {
                    model.preferences.alertLevels.removeAll { $0 == level }
                }
            }
        )
    }
}
```

(b) `apps/apple/Vigil/Settings/SettingsView.swift`: insert a new section between the closing brace of the "Privacy" `settingsSection` (line 92) and `settingsSection("Refresh")` (line 94):

```swift
                    settingsSection("Alerts") {
                        NavigationLink {
                            AlertLevelsView()
                        } label: {
                            SettingsNavigationRow(
                                symbol: "bell.badge",
                                title: "Usage alert levels",
                                detail: "Presets, custom levels, and per-account overrides"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("vigil.settings.alerts")
                    }
```

(c) `apps/apple/Vigil/AppModel.swift`: in `init`, after `seedDemoDataIfRequested()` (line 193), add `resetPreferencesForUITestsIfRequested()`, and add the method next to `seedDemoDataIfRequested()`:

```swift
    /// UI tests persist real preference writes into the App Group suite.
    /// This launch-scoped hook restores the defaults so alert and pause
    /// walks start from a known state (same pattern as `VIGIL_DEMO`
    /// seeding — never a production path).
    private func resetPreferencesForUITestsIfRequested() {
        guard ProcessInfo.processInfo.environment["VIGIL_UI_TEST_RESET_PREFS"] == "1" else {
            return
        }
        preferences.alertLevels = [80, 95]
        preferences.accountAlertOverrides = [:]
        preferences.pauseAllPolling = false
        preferences.pausedAccountKeys = []
        preferences.staleAfterMinutes = 30
    }
```

- [ ] **Step 8: Run the UI test to verify it passes** — same command as Step 6. Expected: **TEST SUCCEEDED** for both `VigilAlertSettingsUITests` methods. Also rerun `-only-testing:VigilTests/AlertLevelEntryTests` (still green).

- [ ] **Step 9: Commit**

```sh
cd /Users/biscuit/Vigil
git add apps/apple/Vigil/Settings/AlertLevelsView.swift \
  apps/apple/Vigil/Settings/SettingsView.swift \
  apps/apple/Vigil/AppModel.swift \
  apps/apple/VigilTests/AlertLevelEntryTests.swift \
  apps/apple/VigilUITests/VigilAlertSettingsUITests.swift
git commit -m "Add global alert-level management with validated custom levels" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Per-account alert overrides (use global / custom / muted) and removed-account cleanup

**PR:** PR-2 — alerts + refresh/pause/staleness

**Files:**
- Create: `apps/apple/Vigil/Settings/AccountAlertOverridesSection.swift`
- Modify: `apps/apple/Vigil/Settings/AlertLevelsView.swift` (replace the `// Task 13 inserts AccountAlertOverridesSection() here.` comment)
- Modify: `apps/apple/Vigil/AppModel.swift` (`removeAccount`, in-memory cleanup block at lines 1681–1684)
- Modify: `apps/apple/VigilUITests/VigilAlertSettingsUITests.swift` (add the override walk)
- Modify: `docs/user-guide/privacy-deletion-notifications.md` (line 44, threshold wording)
- Test: `apps/apple/VigilTests/AccountAlertOverrideTests.swift` (new)

**Interfaces:**
- Consumes: `VigilPreferences.accountAlertOverrides: [String: [Int]]`, `VigilPreferences.alertLevels`, `VigilPreferences.removeOverrides(forAccountKey:)` (also clears the paused set — PR-1 store), `AlertLevelListEditor` (Task 12), `AppModel.preferences`.
- Produces: `enum AccountAlertOverride { enum Mode: Hashable { case useGlobal, custom, muted }; static func mode(for override: [Int]?) -> Mode; static func overrides(_ overrides: [String: [Int]], settingMode mode: Mode, forAccountKey key: String, seedingCustomFrom globalLevels: [Int]) -> [String: [Int]] }`, `struct AccountAlertOverridesSection: View`, `AppModel.removeAccount` calls `preferences.removeOverrides(forAccountKey:)`.

- [ ] **Step 1: Write the failing pure-logic tests** — create `apps/apple/VigilTests/AccountAlertOverrideTests.swift`:

```swift
import XCTest
@testable import Vigil

final class AccountAlertOverrideTests: XCTestCase {
    func testModeMapping() {
        XCTAssertEqual(AccountAlertOverride.mode(for: nil), .useGlobal,
                       "A missing entry means use global")
        XCTAssertEqual(AccountAlertOverride.mode(for: []), .muted,
                       "An empty override means muted")
        XCTAssertEqual(AccountAlertOverride.mode(for: [50]), .custom)
    }

    func testSettingMutedStoresAnEmptyOverride() {
        let updated = AccountAlertOverride.overrides(
            [:],
            settingMode: .muted,
            forAccountKey: "claude:a",
            seedingCustomFrom: [80, 95]
        )
        XCTAssertEqual(updated["claude:a"], [])
    }

    func testSettingUseGlobalRemovesTheEntry() {
        let updated = AccountAlertOverride.overrides(
            ["claude:a": [50], "codex:b": []],
            settingMode: .useGlobal,
            forAccountKey: "claude:a",
            seedingCustomFrom: [80, 95]
        )
        XCTAssertNil(updated["claude:a"])
        XCTAssertEqual(updated["codex:b"], [], "Other accounts' overrides are untouched")
    }

    func testSettingCustomSeedsFromGlobalLevels() {
        let updated = AccountAlertOverride.overrides(
            [:],
            settingMode: .custom,
            forAccountKey: "claude:a",
            seedingCustomFrom: [50, 90]
        )
        XCTAssertEqual(updated["claude:a"], [50, 90])
    }

    func testSettingCustomKeepsAnExistingCustomSet() {
        let updated = AccountAlertOverride.overrides(
            ["claude:a": [33]],
            settingMode: .custom,
            forAccountKey: "claude:a",
            seedingCustomFrom: [80, 95]
        )
        XCTAssertEqual(updated["claude:a"], [33])
    }

    func testSettingCustomWithEmptyGlobalSeedsShippedDefaults() {
        let updated = AccountAlertOverride.overrides(
            [:],
            settingMode: .custom,
            forAccountKey: "claude:a",
            seedingCustomFrom: []
        )
        XCTAssertEqual(
            updated["claude:a"], [80, 95],
            "Custom must never silently store [] (that would read back as muted)"
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/AccountAlertOverrideTests
```

Expected: **BUILD FAILED** with `cannot find 'AccountAlertOverride' in scope`.

- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/AccountAlertOverridesSection.swift` with only the pure logic for now:

```swift
import SwiftUI
import VigilKit

/// Pure mapping between the stored override dictionary and the three-way
/// per-account mode. The dictionary encoding is fixed by the store contract:
/// missing entry = use global, [] = muted, non-empty = custom.
enum AccountAlertOverride {
    enum Mode: Hashable {
        case useGlobal
        case custom
        case muted
    }

    static func mode(for override: [Int]?) -> Mode {
        guard let override else { return .useGlobal }
        return override.isEmpty ? .muted : .custom
    }

    static func overrides(
        _ overrides: [String: [Int]],
        settingMode mode: Mode,
        forAccountKey key: String,
        seedingCustomFrom globalLevels: [Int]
    ) -> [String: [Int]] {
        var updated = overrides
        switch mode {
        case .useGlobal:
            updated[key] = nil
        case .muted:
            updated[key] = []
        case .custom:
            if let existing = updated[key], !existing.isEmpty {
                break // keep the account's current custom set
            }
            // Seed from global; an empty global would store [] and read back
            // as muted, so fall back to the shipped defaults instead.
            updated[key] = globalLevels.isEmpty ? [80, 95] : globalLevels
        }
        return updated
    }
}
```

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expected: **TEST SUCCEEDED** (6 tests).

- [ ] **Step 5: Write the failing removed-account cleanup test** — append to `apps/apple/VigilTests/AccountAlertOverrideTests.swift`:

```swift
@MainActor
final class AccountAlertOverrideRemovalTests: XCTestCase {
    func testRemovingAnAccountRemovesItsOverrideAndPauseFlag() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilOverrideRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = Credentials(providerId: "claude", accessToken: "override-cleanup")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "claude",
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let model = AppModel(vault: vault, directory: directory)
        model.ensureLoadedFromDisk()
        model.preferences.accountAlertOverrides[account.key] = [50]
        model.preferences.pausedAccountKeys.insert(account.key)
        addTeardownBlock { @MainActor in
            model.preferences.accountAlertOverrides = [:]
            model.preferences.pausedAccountKeys = []
        }

        try await model.removeAccount(account)

        XCTAssertNil(
            model.preferences.accountAlertOverrides[account.key],
            "Removing an account removes its alert override (spec section 3)"
        )
        XCTAssertFalse(
            model.preferences.pausedAccountKeys.contains(account.key),
            "removeOverrides(forAccountKey:) also clears the paused set"
        )
    }
}
```

Add `import Foundation` and `import VigilKit` to the file's imports if not already present.

- [ ] **Step 6: Run the test to verify it fails** — same command as Step 2 but `-only-testing:VigilTests/AccountAlertOverrideRemovalTests`. Expected: **TEST FAILED** on the first assertion — the override survives removal because `removeAccount` never calls `removeOverrides`.

- [ ] **Step 7: Minimal implementation** — `apps/apple/Vigil/AppModel.swift`, in `removeAccount` immediately after the in-memory cleanup block (lines 1681–1684):

```swift
        accounts = updatedAccounts
        snapshots[account.key] = nil
        nextAllowed[account.key] = nil
        officialHistoryImports[account.key] = nil
        // Spec section 3: removing an account removes its alert override, and
        // the store method also drops its per-account pause flag. The demo
        // removal path above is exempt — demo identities are memory-only.
        preferences.removeOverrides(forAccountKey: account.key)
```

- [ ] **Step 8: Run the test to verify it passes** — same command as Step 6. Expected: **TEST SUCCEEDED**.

- [ ] **Step 9: Add the override UI and its failing walk** — first append the walk to `apps/apple/VigilUITests/VigilAlertSettingsUITests.swift`:

```swift
    func testAccountOverridePickerMutesOneAccountPlainly() {
        launchAlertSettings()

        let picker = app.descendants(matching: .any)["vigil.settings.alerts.override.claude:demo"]
        scrollTo(picker)
        XCTAssertTrue(picker.exists, "Each linked account must show an override mode picker")

        picker.buttons["Muted"].tap()
        let mutedLabel = app.staticTexts["vigil.settings.alerts.override.claude:demo.muted"]
        scrollTo(mutedLabel)
        XCTAssertTrue(
            mutedLabel.waitForExistence(timeout: 5),
            "A muted account must be labeled: No usage alerts will fire for this account."
        )

        picker.buttons["Use global"].tap()
        XCTAssertFalse(
            mutedLabel.waitForExistence(timeout: 2),
            "Returning to Use global must clear the muted label"
        )
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists, element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }
```

Run it (same command as Task 12 Step 6, `-only-testing:VigilUITests/VigilAlertSettingsUITests/testAccountOverridePickerMutesOneAccountPlainly`). Expected: **TEST FAILED** — the picker identifier does not exist. Then append the view to `apps/apple/Vigil/Settings/AccountAlertOverridesSection.swift`:

```swift
struct AccountAlertOverridesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text("Per-account alerts")
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)

            if model.accounts.isEmpty {
                Text("Link an account to set per-account alert levels.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }

            ForEach(model.accounts) { account in
                accountRow(account)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: AccountRef) -> some View {
        let mode = AccountAlertOverride.mode(
            for: model.preferences.accountAlertOverrides[account.key]
        )
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text(account.label.map { "\(account.displayName) (\($0))" } ?? account.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)

            Picker("Alert levels for \(account.displayName)", selection: modeBinding(for: account)) {
                Text("Use global").tag(AccountAlertOverride.Mode.useGlobal)
                Text("Custom").tag(AccountAlertOverride.Mode.custom)
                Text("Muted").tag(AccountAlertOverride.Mode.muted)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vigil.settings.alerts.override.\(account.key)")

            if mode == .custom {
                AlertLevelListEditor(
                    levels: Binding(
                        get: { model.preferences.accountAlertOverrides[account.key] ?? [] },
                        set: { model.preferences.accountAlertOverrides[account.key] = $0 }
                    ),
                    identifierPrefix: "vigil.settings.alerts.override.\(account.key)"
                )
            }
            if mode == .muted {
                Text("No usage alerts will fire for this account.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VigilPalette.caution)
                    .accessibilityIdentifier("vigil.settings.alerts.override.\(account.key).muted")
            }
        }
        .padding(14)
        .vigilInsetSurface()
    }

    private func modeBinding(for account: AccountRef) -> Binding<AccountAlertOverride.Mode> {
        Binding(
            get: {
                AccountAlertOverride.mode(
                    for: model.preferences.accountAlertOverrides[account.key]
                )
            },
            set: { mode in
                model.preferences.accountAlertOverrides = AccountAlertOverride.overrides(
                    model.preferences.accountAlertOverrides,
                    settingMode: mode,
                    forAccountKey: account.key,
                    seedingCustomFrom: model.preferences.alertLevels
                )
            }
        )
    }
}
```

and in `apps/apple/Vigil/Settings/AlertLevelsView.swift` replace the placeholder comment `// Task 13 inserts AccountAlertOverridesSection() here.` with:

```swift
                    AccountAlertOverridesSection()
```

Re-run the walk. Expected: **TEST SUCCEEDED**.

- [ ] **Step 10: Docs (maintenance rule — same PR as the behavior)** — `docs/user-guide/privacy-deletion-notifications.md` line 44. Replace:

> It detects crossings at 80% and 95% utilization.

with:

> It detects crossings at your configured alert levels — 80% and 95% unless you change them in Settings → Alerts, where each linked account can also carry its own levels or be muted entirely.

Then verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected pass.

- [ ] **Step 11: Commit**

```sh
cd /Users/biscuit/Vigil
git add apps/apple/Vigil/Settings/AccountAlertOverridesSection.swift \
  apps/apple/Vigil/Settings/AlertLevelsView.swift \
  apps/apple/Vigil/AppModel.swift \
  apps/apple/VigilTests/AccountAlertOverrideTests.swift \
  apps/apple/VigilUITests/VigilAlertSettingsUITests.swift \
  docs/user-guide/privacy-deletion-notifications.md
git commit -m "Add per-account alert overrides with removal cleanup" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 14: Pause plumbing — automatic fetches skip paused accounts, manual pull unaffected, no interval ever shortens

**PR:** PR-2 — alerts + refresh/pause/staleness

**Files:**
- Modify: `apps/apple/Vigil/Support/UsageService.swift` (pause gate inserted after the lifecycle-argument guard at lines 123–125, before the lease acquire at line 127)
- Modify: `docs/user-guide/troubleshooting.md` (Common states table, after the **Stale** row at line 19)
- Test: `apps/apple/VigilTests/UsageServicePauseTests.swift` (new)

**Interfaces:**
- Consumes: `VigilPreferences.isPollingPaused(forAccountKey:) -> Bool` (PR-1 store: `pauseAllPolling || pausedAccountKeys.contains(key)`), the `preferences: VigilPreferences?` parameter added in Task 11 (already threaded through AppModel's timer/bgtask/pull paths and the widget timeline — no new caller wiring is needed; the seam read: every automatic surface funnels through `UsageService.refresh` with `bypassPollFloor == false`, and the ONLY `bypassPollFloor: true` caller is the user pull in `DashboardView.refresh()` → `refreshAll(surface: "pull", bypassPollFloor: true)`; `FetchScheduler` itself is untouched — the skip happens before any ledger call so a paused account can never charge, extend, or shorten a poll clock).
- Produces: the pause gate inside `UsageService.refresh` (subtract-work-only, per the spec invariant).

- [ ] **Step 1: Write the failing tests** — create `apps/apple/VigilTests/UsageServicePauseTests.swift`:

```swift
import Foundation
import XCTest
import VigilKit
@testable import Vigil

@MainActor
final class UsageServicePauseTests: XCTestCase {
    func testPausedAccountSkipsAutomaticFetchWithoutTouchingTheLedger() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        PauseStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 30).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        prefs.pausedAccountKeys = [account.key]
        let scheduler = FetchScheduler(
            store: FileLedgerStore(directory: directory),
            jitter: { _ in 0 }
        )

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pause-test",
            session: session,
            preferences: prefs
        )

        XCTAssertNil(result.snapshot, "A paused automatic fetch must not fabricate a snapshot")
        XCTAssertNil(result.persistenceIssue)
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 0, "No request may reach the provider")
        let ledger = try FileLedgerStore(directory: directory).load()
        XCTAssertNil(ledger[account.key], "The skip must never write a ledger row")
    }

    func testPauseAllPollingSkipsAutomaticFetch() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        PauseStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 30).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        prefs.pauseAllPolling = true

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pause-all-test",
            session: session,
            preferences: prefs
        )

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 0)
    }

    func testManualPullStillFetchesWhilePaused() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        PauseStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 30).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        prefs.pauseAllPolling = true
        prefs.pausedAccountKeys = [account.key]

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pull",
            session: session,
            bypassPollFloor: true,
            preferences: prefs
        )

        XCTAssertEqual(result.snapshot?.status, .ok, "A user-initiated pull always fetches")
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 1)
    }

    func testPauseAndResumeNeverShortenThePollClock() async throws {
        let directory = try makeTemporaryDirectory()
        let prefs = try makeScratchPreferences()
        PauseStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 30).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        let scheduler = FetchScheduler(
            store: FileLedgerStore(directory: directory),
            jitter: { _ in 0 }
        )

        // 1. An unpaused automatic fetch succeeds and charges the floor.
        let first = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pause-interval-test",
            session: session,
            preferences: prefs
        )
        XCTAssertEqual(first.snapshot?.status, .ok)
        let chargedUntil = try XCTUnwrap(await scheduler.nextAllowedFetch(accountKey: account.key))
        XCTAssertTrue(chargedUntil > Date(), "The success must charge the poll floor")

        // 2. Pausing skips and leaves the clock exactly where it was.
        prefs.pausedAccountKeys = [account.key]
        let paused = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pause-interval-test",
            session: session,
            preferences: prefs
        )
        XCTAssertNil(paused.snapshot)
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 1)
        let afterPause = try XCTUnwrap(await scheduler.nextAllowedFetch(accountKey: account.key))
        XCTAssertEqual(
            afterPause.timeIntervalSince1970,
            chargedUntil.timeIntervalSince1970,
            accuracy: 0.001,
            "Pausing must not move the poll clock in either direction"
        )

        // 3. Unpausing must not grant an early fetch: the charged floor holds.
        prefs.pausedAccountKeys = []
        let resumed = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "pause-interval-test",
            session: session,
            preferences: prefs
        )
        XCTAssertNil(resumed.snapshot, "The ledger must refuse the early resume")
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 1, "No interval ever shortens")
        XCTAssertEqual(
            try XCTUnwrap(resumed.nextAllowed).timeIntervalSince1970,
            chargedUntil.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testTimerSurfaceSkipsPausedAccountButManualPullFetches() async throws {
        let directory = try makeTemporaryDirectory()
        PauseStubURLProtocol.reset(
            statusCode: 200,
            body: Data(Self.codexBody(usedPercent: 30).utf8)
        )
        let (account, credentials, session) = Self.makeCodexFixture()
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let model = AppModel(vault: vault, directory: directory, usageSession: session)
        model.ensureLoadedFromDisk()
        model.preferences.pausedAccountKeys = [account.key]
        addTeardownBlock { @MainActor in
            model.preferences.pausedAccountKeys = []
        }

        let timerReport = await model.refreshAll(surface: "timer")
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 0, "The timer surface must skip a paused account")
        XCTAssertEqual(timerReport.fetched, 0)
        XCTAssertEqual(timerReport.deferred, 1, "A paused skip reports deferred, never failed")

        let pullReport = await model.refreshAll(surface: "pull", bypassPollFloor: true)
        XCTAssertEqual(PauseStubURLProtocol.requestCount, 1, "The user pull must still fetch")
        XCTAssertEqual(pullReport.fetched, 1)
    }

    // MARK: - Fixture

    private static func makeCodexFixture() -> (AccountRef, Credentials, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PauseStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = Credentials(
            providerId: "codex",
            accessToken: "pause-test-access",
            accountId: "acct-pause-tests"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "codex",
            label: nil,
            plan: nil
        )
        return (account, credentials, session)
    }

    private static func codexBody(usedPercent: Double) -> String {
        """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": \(usedPercent),
              "reset_at": 1785268800,
              "limit_window_seconds": 18000
            },
            "secondary_window": null
          },
          "spend_control": {
            "reached": false,
            "individual_limit": null
          },
          "code_review_rate_limit": null
        }
        """
    }

    private func makeScratchPreferences() throws -> VigilPreferences {
        let suiteName = "vigil-pause-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return VigilPreferences(defaults: defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilPauseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class PauseStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedStatus = 200
    private static var storedBody = Data()
    private static var storedCount = 0

    static var requestCount: Int { lock.withLock { storedCount } }

    static func reset(statusCode: Int, body: Data) {
        lock.withLock {
            storedStatus = statusCode
            storedBody = body
            storedCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.storedCount += 1
            return (Self.storedStatus, Self.storedBody)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/UsageServicePauseTests
```

Expected: **TEST FAILED** — the pause tests compile (Task 11 added the `preferences:` parameter) but fail on assertions: `requestCount` is 1 instead of 0 and a ledger row exists, because nothing consults the pause flags yet. `testManualPullStillFetchesWhilePaused` may already pass — that is expected.

- [ ] **Step 3: Minimal implementation** — `apps/apple/Vigil/Support/UsageService.swift`, insert after the lifecycle-argument guard (lines 123–125, `if lifecycle != nil, generation == nil { ... }`) and before `let acquiredLease: FetchLease?` (line 127):

```swift
        // Pause subtracts work only (spec invariant): it is consulted before
        // ANY ledger or network activity so a paused account can never
        // acquire a lease, charge a poll clock, or paint a failure state.
        // Only automatic surfaces respect it — the user-initiated pull is the
        // sole bypassPollFloor caller and always fetches. Link verification
        // passes preferences: nil and is never pause-gated.
        if !bypassPollFloor,
           let preferences,
           preferences.isPollingPaused(forAccountKey: account.key) {
            log.info("[\(surface)] \(account.key, privacy: .private(mask: .hash)): paused, automatic fetch skipped")
            return Result(
                snapshot: nil,
                nextAllowed: nil,
                persistenceIssue: nil,
                effectiveCredentials: credentials,
                credentialState: .unchanged
            )
        }
```

No `FetchScheduler` change is needed: because the skip precedes `schedulerAcquire`, the ledger row is never created and no interval can shorten or extend. (The pause-toggle UI binds to `pauseAllPolling`/`pausedAccountKeys` and lands with the Settings page assembly in PR-4; this task ships the behavior those toggles control.)

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expected: **TEST SUCCEEDED**, all five `UsageServicePauseTests` pass. Regression check: rerun `-only-testing:VigilTests/AppModelReliabilityTests` and `-only-testing:VigilTests/UsageServiceAlertLevelTests` — both green (their calls pass `preferences: nil` or unpaused prefs).

- [ ] **Step 5: Docs (maintenance rule — same PR as the behavior)** — `docs/user-guide/troubleshooting.md`, Common states table: insert a new row directly after the **Stale** row (line 19):

```markdown
| **Paused** | Automatic checks are off for this account or for every account (Settings → Refresh). | Retained data keeps aging visibly — pausing never freezes the display of time. Pull to refresh to fetch on demand, or turn the pause off. Resuming never fetches earlier than the normal polling gate allows. |
```

Then verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected pass.

- [ ] **Step 6: Commit**

```sh
cd /Users/biscuit/Vigil
git add apps/apple/Vigil/Support/UsageService.swift \
  apps/apple/VigilTests/UsageServicePauseTests.swift \
  docs/user-guide/troubleshooting.md
git commit -m "Skip automatic fetches for paused accounts without touching the poll clock" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 15: Staleness threshold parameterized through SnapshotFreshness and fed from staleAfterMinutes

**PR:** PR-2 — alerts + refresh/pause/staleness

**Files:**
- Modify: `apps/apple/Vigil/Support/SnapshotFreshness.swift` (whole file is 56 lines; parameterize `isStale`/`isDegraded`, add `threshold(afterMinutes:)` and the environment key)
- Modify: `apps/apple/Vigil/RootView.swift` (inject the environment value on the `NavigationStack`, body at lines 18–24 — note PR-1 already replaced `.preferredColorScheme(.dark)` here)
- Modify: `apps/apple/Vigil/Dashboard/AccountLimitSummary.swift` (init at lines 10–20, `isStale` sites at lines 61, 103, 115, 339, 350, `ranked` at lines 124–137)
- Modify: `apps/apple/Vigil/Dashboard/DashboardView.swift` (`summaries` at lines 15–21)
- Modify: `apps/apple/Vigil/Dashboard/AccountCardView.swift` (`isStale` at line 137)
- Modify: `apps/apple/Vigil/Dashboard/ReserveDial.swift` (`SnapshotFreshnessLine.freshnessSymbol`/`freshnessTint`, `isStale` at lines 97 and 108)
- Modify: `apps/apple/Vigil/Dashboard/WindowRows.swift` (`isDegraded` at line 96)
- Modify: `apps/apple/Vigil/Connections/ConnectionsView.swift` (`isStale` at line 256)
- Modify: `docs/user-guide/reading-limits.md` (lines 43–44 and the Refresh timing section), `docs/product-contract.md` (after line 60), `docs/user-guide/troubleshooting.md` (Stale row, line 19)
- Test: `apps/apple/VigilTests/SnapshotFreshnessThresholdTests.swift` (new)

**Interfaces:**
- Consumes: `VigilPreferences.staleAfterMinutes: Int` (allowed {15, 30, 60}, default 30 — PR-1 store), `AppModel.preferences`.
- Produces: `SnapshotFreshness.threshold(afterMinutes: Int) -> TimeInterval`; `isStale(fetchedAt:at:staleAfter:)` and `isDegraded(status:fetchedAt:at:staleAfter:)` with `staleAfter: TimeInterval = SnapshotFreshness.staleAfter` (existing public shape preserved — every current call site compiles unchanged); `EnvironmentValues.vigilStaleAfter: TimeInterval`; `AccountLimitSummary` gains `staleAfter: TimeInterval = SnapshotFreshness.staleAfter` (init and `ranked`).
- Scope note (spec section 4): the threshold is **presentation-only** and feeds the **app-target** surfaces. The widget and `ThresholdEngine.maximumPendingAge` (VigilKit) deliberately keep the 30-minute default; VigilKit stays preference-free.

- [ ] **Step 1: Write the failing tests** — create `apps/apple/VigilTests/SnapshotFreshnessThresholdTests.swift`:

```swift
import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class SnapshotFreshnessThresholdTests: XCTestCase {
    func testThresholdMapsOnlyAllowedMinutes() {
        XCTAssertEqual(SnapshotFreshness.threshold(afterMinutes: 15), 15 * 60)
        XCTAssertEqual(SnapshotFreshness.threshold(afterMinutes: 30), 30 * 60)
        XCTAssertEqual(SnapshotFreshness.threshold(afterMinutes: 60), 60 * 60)
        XCTAssertEqual(
            SnapshotFreshness.threshold(afterMinutes: 45), 30 * 60,
            "Unknown values fall back to the shipped 30-minute default"
        )
        XCTAssertEqual(SnapshotFreshness.threshold(afterMinutes: 0), 30 * 60)
        XCTAssertEqual(SnapshotFreshness.threshold(afterMinutes: -15), 30 * 60)
    }

    func testIsStaleHonorsEachAllowedThreshold() {
        let now = Date()
        for minutes in [15, 30, 60] {
            let threshold = SnapshotFreshness.threshold(afterMinutes: minutes)
            let atBoundary = now.addingTimeInterval(-threshold)
            XCTAssertFalse(
                SnapshotFreshness.isStale(fetchedAt: atBoundary, at: now, staleAfter: threshold),
                "\(minutes) min: exactly at the boundary is not yet stale"
            )
            XCTAssertTrue(
                SnapshotFreshness.isStale(
                    fetchedAt: atBoundary.addingTimeInterval(-1),
                    at: now,
                    staleAfter: threshold
                ),
                "\(minutes) min: one second past the boundary is stale"
            )
        }
    }

    func testIsDegradedUsesTheParameterizedThreshold() {
        let now = Date()
        let twentyMinutesAgo = now.addingTimeInterval(-20 * 60)
        XCTAssertFalse(
            SnapshotFreshness.isDegraded(status: .ok, fetchedAt: twentyMinutesAgo, at: now),
            "Default 30-minute shape is unchanged"
        )
        XCTAssertTrue(
            SnapshotFreshness.isDegraded(
                status: .ok,
                fetchedAt: twentyMinutesAgo,
                at: now,
                staleAfter: SnapshotFreshness.threshold(afterMinutes: 15)
            )
        )
    }

    func testDefaultPublicShapeIsUnchanged() {
        XCTAssertEqual(SnapshotFreshness.staleAfter, 1800)
        let now = Date()
        XCTAssertFalse(SnapshotFreshness.isStale(fetchedAt: now.addingTimeInterval(-1800), at: now))
        XCTAssertTrue(SnapshotFreshness.isStale(fetchedAt: now.addingTimeInterval(-1801), at: now))
    }

    func testAccountLimitSummaryHonorsCustomStaleThreshold() {
        let account = AccountRef(key: "claude:stale-test", providerId: "claude", label: nil, plan: nil)
        let now = Date()
        let snapshot = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now.addingTimeInterval(-20 * 60),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: 40,
                    resetsAt: now.addingTimeInterval(3_600),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )

        let defaultSummary = AccountLimitSummary(
            account: account,
            snapshot: snapshot,
            nextAllowed: nil,
            evaluatedAt: now
        )
        XCTAssertEqual(defaultSummary.displayStatusTitle, "Live", "20 minutes is fresh at the default 30")

        let strict = AccountLimitSummary(
            account: account,
            snapshot: snapshot,
            nextAllowed: nil,
            evaluatedAt: now,
            staleAfter: SnapshotFreshness.threshold(afterMinutes: 15)
        )
        XCTAssertEqual(strict.displayStatusTitle, "Stale", "20 minutes is stale at a 15-minute threshold")

        let relaxedSnapshot = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: now.addingTimeInterval(-45 * 60),
            status: .ok,
            windows: snapshot.windows
        )
        let relaxed = AccountLimitSummary(
            account: account,
            snapshot: relaxedSnapshot,
            nextAllowed: nil,
            evaluatedAt: now,
            staleAfter: SnapshotFreshness.threshold(afterMinutes: 60)
        )
        XCTAssertEqual(relaxed.displayStatusTitle, "Live", "45 minutes is fresh at a 60-minute threshold")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/SnapshotFreshnessThresholdTests
```

Expected: **BUILD FAILED** — `type 'SnapshotFreshness' has no member 'threshold'`, `extra argument 'staleAfter' in call`.

- [ ] **Step 3: Minimal implementation of the parameterized entry points** — `apps/apple/Vigil/Support/SnapshotFreshness.swift`. Replace lines 13–25 (`staleAfter` through `isDegraded`) with:

```swift
    /// Matches the widget timeline's re-fetch threshold and the app's warning
    /// threshold. Do not invent per-surface thresholds. This default is also
    /// what the widget process and VigilKit's pending-notification age keep
    /// using: the user preference below is presentation-only and app-scoped.
    static let staleAfter: TimeInterval = 30 * 60

    /// The user's presentation threshold (Settings → Refresh). Only these
    /// values are honest choices; anything else — corrupt storage, a future
    /// build's value — falls back to the shipped 30-minute default rather
    /// than freezing or hiding staleness.
    static let allowedStaleMinutes: Set<Int> = [15, 30, 60]

    static func threshold(afterMinutes minutes: Int) -> TimeInterval {
        allowedStaleMinutes.contains(minutes)
            ? TimeInterval(minutes) * 60
            : staleAfter
    }

    static func isStale(
        fetchedAt: Date,
        at now: Date = Date(),
        staleAfter: TimeInterval = SnapshotFreshness.staleAfter
    ) -> Bool {
        now.timeIntervalSince(fetchedAt) > staleAfter
    }

    static func isDegraded(
        status: SnapshotStatus,
        fetchedAt: Date,
        at now: Date = Date(),
        staleAfter: TimeInterval = SnapshotFreshness.staleAfter
    ) -> Bool {
        status != .ok || isStale(fetchedAt: fetchedAt, at: now, staleAfter: staleAfter)
    }
```

Change the file's `import Foundation` block to also `import SwiftUI`, and append at the end of the file:

```swift
private struct VigilStaleAfterKey: EnvironmentKey {
    static let defaultValue: TimeInterval = SnapshotFreshness.staleAfter
}

extension EnvironmentValues {
    /// Preference-fed staleness threshold. RootView injects it from
    /// `preferences.staleAfterMinutes`; app freshness surfaces pass it into
    /// the SnapshotFreshness entry points. Everywhere nothing injects —
    /// widgets, previews, tests — it stays the shipped 30 minutes.
    var vigilStaleAfter: TimeInterval {
        get { self[VigilStaleAfterKey.self] }
        set { self[VigilStaleAfterKey.self] = newValue }
    }
}
```

Then `apps/apple/Vigil/Dashboard/AccountLimitSummary.swift`: add the property and init parameter (lines 10–20):

```swift
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let evaluatedAt: Date
    /// Presentation staleness threshold, injected by the app so ranking and
    /// labels agree with the user's Settings → Refresh choice.
    let staleAfter: TimeInterval

    init(
        account: AccountRef,
        snapshot: ProviderSnapshot?,
        nextAllowed: Date?,
        evaluatedAt: Date = Date(),
        staleAfter: TimeInterval = SnapshotFreshness.staleAfter
    ) {
        self.account = account
        self.snapshot = snapshot
        self.nextAllowed = nextAllowed
        self.evaluatedAt = evaluatedAt
        self.staleAfter = staleAfter
    }
```

and at each of the five `SnapshotFreshness.isStale(fetchedAt: ..., at: ...)` call sites in this file (`actionRank` line 61, `displayStatusTitle` line 103, `displayStatusSymbol` line 115, `isCurrent` line 339, `cardTint` line 350 — the last two use `summary.evaluatedAt` and become `staleAfter: summary.staleAfter`), add the argument, e.g.:

```swift
            let stale = SnapshotFreshness.isStale(
                fetchedAt: snapshot.fetchedAt,
                at: evaluatedAt,
                staleAfter: staleAfter
            )
```

and thread it through `ranked` (lines 124–137):

```swift
    static func ranked(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot],
        nextAllowed: [String: Date],
        evaluatedAt: Date = Date(),
        staleAfter: TimeInterval = SnapshotFreshness.staleAfter
    ) -> [AccountLimitSummary] {
        return accounts.map {
            AccountLimitSummary(
                account: $0,
                snapshot: snapshots[$0.key],
                nextAllowed: nextAllowed[$0.key],
                evaluatedAt: evaluatedAt,
                staleAfter: staleAfter
            )
        }
```

(the `.sorted { ... }` tail is unchanged).

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expected: **TEST SUCCEEDED** (5 tests). Also rerun `-only-testing:VigilTests/SurfaceHonestyTests` and `-only-testing:VigilTests/AccountLimitSummaryTests` to prove the existing public shape is untouched — both green.

- [ ] **Step 5: Feed the preference through the environment** — `apps/apple/Vigil/RootView.swift`, on the `NavigationStack` in `body` (lines 18–24; PR-1 already gave RootView `@Environment(AppModel.self) private var model` for the appearance preference — if it used a different access route, feed from that same model reference):

```swift
        NavigationStack {
            launchView
        }
        .tint(VigilPalette.signal)
        .environment(
            \.vigilStaleAfter,
            SnapshotFreshness.threshold(afterMinutes: model.preferences.staleAfterMinutes)
        )
```

(keep the PR-1 `.preferredColorScheme(model.preferences.appearance.colorScheme)` modifier as-is). Then wire the consuming views — each edit adds one property and one argument:

- `apps/apple/Vigil/Dashboard/DashboardView.swift`: add `@Environment(\.vigilStaleAfter) private var staleAfter` below line 9, and in `summaries` (lines 15–21) pass `staleAfter: staleAfter`:

```swift
    private var summaries: [AccountLimitSummary] {
        AccountLimitSummary.ranked(
            accounts: model.accounts,
            snapshots: model.snapshots,
            nextAllowed: model.nextAllowed,
            staleAfter: staleAfter
        )
    }
```

- `apps/apple/Vigil/Dashboard/AccountCardView.swift`: add `@Environment(\.vigilStaleAfter) private var staleAfter` next to the existing `@Environment(\.dynamicTypeSize)` (line 13); at line 137 change to `SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, staleAfter: staleAfter)`.
- `apps/apple/Vigil/Dashboard/ReserveDial.swift` (`SnapshotFreshnessLine`): add `@Environment(\.vigilStaleAfter) private var staleAfter` below the `nextAllowed` property (line 44); at lines 97 and 108 change both calls to `SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, staleAfter: staleAfter)`.
- `apps/apple/Vigil/Dashboard/WindowRows.swift`: add `@Environment(\.vigilStaleAfter) private var staleAfter` next to the existing environment property (line 88); at line 96 change to `SnapshotFreshness.isDegraded(status: status, fetchedAt: fetchedAt, staleAfter: staleAfter)`.
- `apps/apple/Vigil/Connections/ConnectionsView.swift`: add `@Environment(\.vigilStaleAfter) private var staleAfter` below `@Environment(AppModel.self)` (line 5); at line 256 change to `SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, staleAfter: staleAfter)`.

The widget (`VigilWidgets.swift`, `UsageTimelineProvider.swift`) is deliberately untouched — spec section 4 scopes the preference to the app-target presentation, so widgets keep the 30-minute default.

- [ ] **Step 6: Build and run the full app test suite to verify nothing regressed**

```sh
cd /Users/biscuit/Vigil/apps/apple
xcodegen generate
DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests
```

Expected: **TEST SUCCEEDED** — the whole `VigilTests` bundle, including every suite added by Tasks 11–15.

- [ ] **Step 7: Docs (maintenance rule — same PR as the behavior)** — three files, then `scripts/check-docs.sh`.

`docs/user-guide/reading-limits.md`, Freshness table (lines 43–44) — replace the two rows:

```markdown
| **Live** | The latest accepted response satisfied the provider contract and is not older than your stale threshold (default 30 minutes). |
| **Stale** | The last accepted response is older than your stale threshold — 15, 30, or 60 minutes (default 30), set in Settings → Refresh. |
```

and append to the end of the "Refresh timing" paragraph (after "...so Vigil does not promise fixed sampling intervals."):

```markdown
The stale threshold is presentation-only: changing it never changes when Vigil polls.
```

`docs/product-contract.md`, after line 60 ("Countdowns may advance locally... not proof of fresh provider data."), append a new paragraph:

```markdown
The **Stale** label's age threshold is a user preference (15, 30, or 60 minutes; default 30). It changes only how soon retained data is labeled stale — never polling cadence, retention, or the data itself.
```

`docs/user-guide/troubleshooting.md`, **Stale** row (line 19) — replace the meaning cell:

> The last accepted reading is over 30 minutes old.

with:

> The last accepted reading is older than your stale threshold (default 30 minutes; 15, 30, or 60 in Settings → Refresh).

Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected pass.

- [ ] **Step 8: Commit**

```sh
cd /Users/biscuit/Vigil
git add apps/apple/Vigil/Support/SnapshotFreshness.swift \
  apps/apple/Vigil/RootView.swift \
  apps/apple/Vigil/Dashboard/AccountLimitSummary.swift \
  apps/apple/Vigil/Dashboard/DashboardView.swift \
  apps/apple/Vigil/Dashboard/AccountCardView.swift \
  apps/apple/Vigil/Dashboard/ReserveDial.swift \
  apps/apple/Vigil/Dashboard/WindowRows.swift \
  apps/apple/Vigil/Connections/ConnectionsView.swift \
  apps/apple/VigilTests/SnapshotFreshnessThresholdTests.swift \
  docs/user-guide/reading-limits.md \
  docs/product-contract.md \
  docs/user-guide/troubleshooting.md
git commit -m "Parameterize the presentation stale threshold from staleAfterMinutes" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```


## PR-3

### Task 16: UsageSeverity — the non-color severity band behind every dial tint
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Create: `apps/apple/Vigil/Dashboard/UsageSeverity.swift`
- Test: `apps/apple/VigilTests/UsageSeverityTests.swift`

**Interfaces:**
- Consumes: `VigilPalette.limitColor(utilization:)` (`apps/apple/Vigil/DesignSystem/VigilTheme.swift:25-29` — `>= 95` critical, `>= 80` caution, else `signal`)
- Produces:
  ```swift
  enum UsageSeverity: Equatable {
      case normal, caution, critical
      static func forUtilization(_ utilization: Double) -> UsageSeverity
      var marker: String?            // nil / "LOW" / "CRITICAL"
      var spokenQualifier: String?   // nil / "running low" / "critically low"
  }
  ```

The spec (§5, docs/superpowers/specs/2026-07-30-settings-revamp-design.md) requires that status never be encoded by hue alone. `ReserveDial` currently signals the caution/critical band only through `UsageTint.color(for:)` ring hue. This task creates the pure band model whose thresholds are pinned to `VigilPalette.limitColor` so tint and marker can never disagree.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/UsageSeverityTests.swift`:
  ```swift
  import SwiftUI
  import XCTest
  import VigilKit
  @testable import Vigil

  final class UsageSeverityTests: XCTestCase {
      func testThresholdsMatchThePaletteTintBands() {
          XCTAssertEqual(UsageSeverity.forUtilization(0), .normal)
          XCTAssertEqual(UsageSeverity.forUtilization(79.9), .normal)
          XCTAssertEqual(UsageSeverity.forUtilization(80), .caution)
          XCTAssertEqual(UsageSeverity.forUtilization(94.9), .caution)
          XCTAssertEqual(UsageSeverity.forUtilization(95), .critical)
          XCTAssertEqual(UsageSeverity.forUtilization(100), .critical)
      }

      /// The marker exists so the band never depends on hue alone; it must
      /// therefore flip at exactly the utilizations where the tint flips.
      func testSeverityNeverDisagreesWithLimitColor() {
          for utilization in stride(from: 0.0, through: 100.0, by: 0.5) {
              let severity = UsageSeverity.forUtilization(utilization)
              let tint = VigilPalette.limitColor(utilization: utilization)
              switch severity {
              case .normal: XCTAssertEqual(tint, VigilPalette.signal, "at \(utilization)")
              case .caution: XCTAssertEqual(tint, VigilPalette.caution, "at \(utilization)")
              case .critical: XCTAssertEqual(tint, VigilPalette.critical, "at \(utilization)")
              }
          }
      }

      func testMarkersAndSpokenQualifiers() {
          XCTAssertNil(UsageSeverity.normal.marker)
          XCTAssertEqual(UsageSeverity.caution.marker, "LOW")
          XCTAssertEqual(UsageSeverity.critical.marker, "CRITICAL")
          XCTAssertNil(UsageSeverity.normal.spokenQualifier)
          XCTAssertEqual(UsageSeverity.caution.spokenQualifier, "running low")
          XCTAssertEqual(UsageSeverity.critical.spokenQualifier, "critically low")
      }
  }
  ```
- [ ] **Step 2: Run the test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests/UsageSeverityTests
  ```
  Expected: BUILD FAILS with `error: cannot find 'UsageSeverity' in scope` (that compile error is this step's red).
- [ ] **Step 3: Minimal implementation.** Create `apps/apple/Vigil/Dashboard/UsageSeverity.swift` (app target only — the `Vigil/` source tree; do NOT add it to the widget target):
  ```swift
  import Foundation
  import VigilKit

  /// The non-color counterpart of `VigilPalette.limitColor(utilization:)`.
  /// Status and severity must never be encoded by hue alone, so the same
  /// thresholds that pick the caution/critical tint also pick a short text
  /// marker (dial center) and a spoken qualifier (VoiceOver card summary).
  enum UsageSeverity: Equatable {
      case normal
      case caution
      case critical

      /// Thresholds mirror `VigilPalette.limitColor`: >= 95 critical,
      /// >= 80 caution. Keep both in lockstep — the parity unit test fails
      /// if either side moves alone.
      static func forUtilization(_ utilization: Double) -> UsageSeverity {
          if utilization >= 95 { return .critical }
          if utilization >= 80 { return .caution }
          return .normal
      }

      /// Short text marker rendered beside the colored value.
      var marker: String? {
          switch self {
          case .normal: return nil
          case .caution: return "LOW"
          case .critical: return "CRITICAL"
          }
      }

      /// Spoken qualifier appended to a card's VoiceOver summary.
      var spokenQualifier: String? {
          switch self {
          case .normal: return nil
          case .caution: return "running low"
          case .critical: return "critically low"
          }
      }
  }
  ```
- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: `Test Suite 'UsageSeverityTests' passed` — 3 tests, 0 failures.
- [ ] **Step 5: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Dashboard/UsageSeverity.swift apps/apple/VigilTests/UsageSeverityTests.swift && \
  git commit -m "Add the UsageSeverity band model pinned to the palette tint thresholds" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 17: Unconditional status markers — Live pill symbol and dial severity marker
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Modify: `apps/apple/Vigil/Support/UsagePresentation.swift` (`statusSymbol`, lines 194-202 at main@c62061d)
- Modify: `apps/apple/Vigil/Dashboard/ReserveDial.swift` (center `VStack`, lines 25-34)
- Test: `apps/apple/VigilTests/UsagePresentationTests.swift` (add one method to the existing class)

**Interfaces:**
- Consumes: `UsageSeverity` (Task 16); `VigilStatusPill(text:color:symbol:)` (`apps/apple/Vigil/DesignSystem/VigilTheme.swift:143-170`)
- Produces: `UsagePresentation.statusSymbol(_ status: SnapshotStatus) -> String?` now returns `"checkmark.circle"` for `.ok` (was `nil`); `ReserveDial` renders `UsageSeverity.marker` under its "LEFT" caption.

Today the "Live" pill renders text plus a plain colored dot (`VigilStatusPill`'s nil-symbol fallback, VigilTheme.swift:153-156) — the only status whose glyph is hue-only. Every other status already carries a symbol. Making `statusSymbol(.ok)` non-nil fixes the Live pill at all three call sites at once (`AccountLimitSummary.swift:121`, `ConnectionsView.swift:262`, `AccountCardView.swift:147`). Safety check performed: the one `?? "exclamationmark.circle"` fallback (`ReserveDial.swift:92`, `SnapshotFreshnessLine`) is only reached when `status != .ok`, and no existing test asserts `statusSymbol(.ok) == nil`, so this change is isolated.

- [ ] **Step 1: Write the failing test.** In `apps/apple/VigilTests/UsagePresentationTests.swift`, add inside `final class UsagePresentationTests`:
  ```swift
  /// Status pills must never rely on a colored dot alone. Every status —
  /// including Live — carries an SF Symbol, so hue is redundant, not load-
  /// bearing (spec §5, unconditional labels).
  func testEveryStatusCarriesANonColorSymbol() {
      XCTAssertEqual(UsagePresentation.statusSymbol(.ok), "checkmark.circle")
      XCTAssertEqual(UsagePresentation.statusSymbol(.rateLimited), "hourglass")
      XCTAssertEqual(UsagePresentation.statusSymbol(.authExpired), "key.slash")
      XCTAssertEqual(UsagePresentation.statusSymbol(.schemaChanged), "exclamationmark.triangle")
      XCTAssertEqual(UsagePresentation.statusSymbol(.network), "wifi.slash")
  }
  ```
- [ ] **Step 2: Run the test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/UsagePresentationTests/testEveryStatusCarriesANonColorSymbol
  ```
  Expected: FAILS — `XCTAssertEqual failed: ("nil") is not equal to ("Optional("checkmark.circle")")`.
- [ ] **Step 3: Minimal implementation, part 1 — the symbol.** In `apps/apple/Vigil/Support/UsagePresentation.swift`, change the `.ok` case of `statusSymbol` (line 196):
  ```swift
      static func statusSymbol(_ status: SnapshotStatus) -> String? {
          switch status {
          case .ok: return "checkmark.circle"
          case .rateLimited: return "hourglass"
          case .authExpired: return "key.slash"
          case .schemaChanged: return "exclamationmark.triangle"
          case .network: return "wifi.slash"
          }
      }
  ```
  Note: this file is also compiled into the VigilWidgets target (project.yml line 137) — the change is pure Foundation and safe there.
- [ ] **Step 4: Minimal implementation, part 2 — the dial marker.** In `apps/apple/Vigil/Dashboard/ReserveDial.swift`, replace the center `VStack` (lines 25-34):
  ```swift
              VStack(spacing: 0) {
                  Text("\(Int(clamped.rounded()))")
                      .font(.system(size: 18, weight: .bold, design: .rounded))
                      .monospacedDigit()
                      .foregroundStyle(VigilPalette.ink)
                  Text("LEFT")
                      .font(.system(size: 7, weight: .bold, design: .monospaced))
                      .tracking(0.8)
                      .foregroundStyle(VigilPalette.inkMuted)
                  if let marker = severity.marker {
                      // Text marker, not hue: the band stays readable when the
                      // ring tint is indistinguishable for the viewer.
                      Text(marker)
                          .font(.system(size: 7, weight: .heavy, design: .monospaced))
                          .tracking(0.6)
                          .foregroundStyle(tint)
                  }
              }
  ```
  and add this computed property below `private var clamped` (line 12):
  ```swift
      /// remaining is percent-left; the severity model keys on utilization.
      private var severity: UsageSeverity { .forUtilization(100 - clamped) }
  ```
- [ ] **Step 5: Run the test to verify it passes, and the full app suite for regressions.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests
  ```
  Expected: `testEveryStatusCarriesANonColorSymbol` PASSES; all pre-existing VigilTests stay green (nothing asserted `statusSymbol(.ok) == nil`).
- [ ] **Step 6: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/UsagePresentation.swift apps/apple/Vigil/Dashboard/ReserveDial.swift apps/apple/VigilTests/UsagePresentationTests.swift && \
  git commit -m "Give the Live pill a symbol and the reserve dial a text severity marker" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 18: Spoken severity band on the Home card, near-limit demo state, and the spoken-surface UI test
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Modify: `apps/apple/Vigil/Dashboard/UsageSeverity.swift` (add `spokenRemaining(for:)`)
- Modify: `apps/apple/Vigil/Dashboard/AccountLimitSummary.swift` (`accessibilitySummary`, lines 369-371 at main@c62061d)
- Modify: `apps/apple/Vigil/Support/DemoData.swift` (new opt-in flag + seed parameter)
- Modify: `apps/apple/Vigil/AppModel.swift` (`seedDemoDataIfRequested`, lines 199-215)
- Modify: `docs/user-guide/reading-limits.md` ("Freshness and status labels" section)
- Test: `apps/apple/VigilTests/UsageSeverityTests.swift`, `apps/apple/VigilTests/DemoDataTests.swift`, `apps/apple/VigilUITests/VigilAccessibilityUITests.swift`

**Interfaces:**
- Consumes: `UsageSeverity` (Task 16); `UsagePresentation.remainingPercent(for:)`; `DemoData.seed(now:claudeStatus:)`; the UI-test launch-env convention (`VIGIL_DEMO*` flags read in `AppModel.seedDemoDataIfRequested`, asserted via `XCUIApplication.launchEnvironment` as in `VigilAccessibilityUITests.launch(tab:demo:...)`, lines 193-217)
- Produces:
  ```swift
  extension UsageSeverity {
      static func spokenRemaining(for window: UsageWindow) -> String
  }
  // DemoData:
  static func claudeNearLimitRequested(in environment: [String: String]) -> Bool
  static func seed(now: Date = Date(), claudeStatus: SnapshotStatus = .ok, claudeNearLimit: Bool = false) -> (accounts: [AccountRef], snapshots: [String: ProviderSnapshot])
  ```

The card's VoiceOver summary (`AccountLimitSummary.swift:359-392`) is the pinned spoken surface — the card combines its children, so sighted-only markers (Task 17) are invisible to VoiceOver unless the summary speaks the band too. No default demo account crosses 80% utilization (Claude session is 42, Codex 77), so a deterministic near-limit demo state is added following the exact `VIGIL_DEMO_CLAUDE_AUTH_EXPIRED` pattern.

- [ ] **Step 1: Write the failing unit tests.** Append to `final class UsageSeverityTests` in `apps/apple/VigilTests/UsageSeverityTests.swift`:
  ```swift
  func testSpokenRemainingAppendsTheSeverityQualifier() {
      let normal = UsageWindow(id: "session", utilization: 42, resetsAt: nil, windowSeconds: 18_000, secondary: false)
      XCTAssertEqual(UsageSeverity.spokenRemaining(for: normal), "58 percent left")

      let caution = UsageWindow(id: "session", utilization: 80, resetsAt: nil, windowSeconds: 18_000, secondary: false)
      XCTAssertEqual(UsageSeverity.spokenRemaining(for: caution), "20 percent left, running low")

      let critical = UsageWindow(id: "session", utilization: 96, resetsAt: nil, windowSeconds: 18_000, secondary: false)
      XCTAssertEqual(UsageSeverity.spokenRemaining(for: critical), "4 percent left, critically low")
  }
  ```
  And append to `final class DemoDataTests` in `apps/apple/VigilTests/DemoDataTests.swift`:
  ```swift
  func testNearLimitClaudeStateIsSeparatelyOptIn() throws {
      XCTAssertTrue(DemoData.claudeNearLimitRequested(in: [
          "VIGIL_DEMO_CLAUDE_NEAR_LIMIT": "1",
      ]))
      XCTAssertFalse(DemoData.claudeNearLimitRequested(in: [:]))
      XCTAssertFalse(DemoData.claudeNearLimitRequested(in: [
          "VIGIL_DEMO_CLAUDE_NEAR_LIMIT": "true",
      ]))

      let now = Date(timeIntervalSince1970: 1_784_500_000)
      let seed = DemoData.seed(now: now, claudeNearLimit: true)
      let claude = try XCTUnwrap(seed.accounts.first { $0.providerId == "claude" })
      let session = try XCTUnwrap(
          seed.snapshots[claude.key]?.windows.first { $0.id == "session" }
      )
      XCTAssertEqual(session.utilization, 96, "the near-limit state must land in the critical band")

      let defaultSession = try XCTUnwrap(
          DemoData.seed(now: now).snapshots[claude.key]?.windows.first { $0.id == "session" }
      )
      XCTAssertEqual(defaultSession.utilization, 42, "the default screenshot seed must not change")
  }
  ```
- [ ] **Step 2: Run to verify both fail.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilTests/UsageSeverityTests -only-testing:VigilTests/DemoDataTests
  ```
  Expected: BUILD FAILS — `cannot find 'spokenRemaining'`/`claudeNearLimitRequested` and `extra argument 'claudeNearLimit' in call` (compile errors are the red).
- [ ] **Step 3: Implement the model and seed.** In `apps/apple/Vigil/Dashboard/UsageSeverity.swift`, append:
  ```swift
  extension UsageSeverity {
      /// Spoken clause for a decisive window — "4 percent left, critically
      /// low" — so VoiceOver users hear the band sighted users see as tint
      /// plus text marker.
      static func spokenRemaining(for window: UsageWindow) -> String {
          let percent = Int(UsagePresentation.remainingPercent(for: window).rounded())
          guard let qualifier = forUtilization(window.utilization).spokenQualifier else {
              return "\(percent) percent left"
          }
          return "\(percent) percent left, \(qualifier)"
      }
  }
  ```
  In `apps/apple/Vigil/Support/DemoData.swift`, after `claudeProviderChangedRequested` (line 29), add:
  ```swift
      /// UI-test-only state placing the Claude session window in the critical
      /// band, so severity markers and their spoken surface are testable.
      /// It has no effect unless demo mode is also enabled by the caller.
      static func claudeNearLimitRequested(in environment: [String: String]) -> Bool {
          environment["VIGIL_DEMO_CLAUDE_NEAR_LIMIT"] == "1"
      }
  ```
  Change the `seed` signature (line 38-41) to:
  ```swift
      static func seed(
          now: Date = Date(),
          claudeStatus: SnapshotStatus = .ok,
          claudeNearLimit: Bool = false
      ) -> (accounts: [AccountRef], snapshots: [String: ProviderSnapshot]) {
  ```
  and the Claude session window (line 84) to:
  ```swift
                  window("session", claudeNearLimit ? 96 : 42, resetsIn: 2.3 * hour, windowSeconds: session),
  ```
  In `apps/apple/Vigil/AppModel.swift` `seedDemoDataIfRequested` (line 211), change the seed call to:
  ```swift
          let demo = DemoData.seed(
              claudeStatus: claudeStatus,
              claudeNearLimit: DemoData.claudeNearLimitRequested(in: environment)
          )
  ```
- [ ] **Step 4: Run Step 2's command again.** Expected: both unit tests PASS.
- [ ] **Step 5: Write the failing spoken-surface UI test.** In `apps/apple/VigilUITests/VigilAccessibilityUITests.swift`, add a parameter to the private `launch` method — insert `claudeNearLimit: Bool = false` after `claudeProviderChanged: Bool = false` (line 198), and inside it after line 207 add:
  ```swift
          app.launchEnvironment["VIGIL_DEMO_CLAUDE_NEAR_LIMIT"] = claudeNearLimit ? "1" : "0"
  ```
  Then add the test method:
  ```swift
  func testNearLimitHomeCardSpeaksTheSeverityBand() {
      // The Home card combines its children into one spoken summary, so the
      // severity band added beside the tint must be spoken there too — a
      // VoiceOver user must not need color vision to hear "critically low".
      launch(tab: "home", demo: true, claudeNearLimit: true)

      let claudeAccount = reachableElement("vigil.home.account.claude")
      let spoken = claudeAccount.label
      XCTAssertTrue(
          spoken.contains("4 percent left, critically low"),
          "A critical reserve must speak its severity band. Spoken: \(spoken)"
      )
  }
  ```
- [ ] **Step 6: Run the UI test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO \
    -only-testing:VigilUITests/VigilAccessibilityUITests/testNearLimitHomeCardSpeaksTheSeverityBand
  ```
  Expected: FAILS — the label contains `"4 percent left"` but not `", critically low"` (the summary still uses the unqualified string).
- [ ] **Step 7: Wire the spoken clause.** In `apps/apple/Vigil/Dashboard/AccountLimitSummary.swift` `accessibilitySummary` (line 369-371), replace:
  ```swift
          if let window = summary.decisiveWindow {
              parts.append("\(Int(UsagePresentation.remainingPercent(for: window).rounded())) percent left")
              parts.append(UsagePresentation.title(for: window))
  ```
  with:
  ```swift
          if let window = summary.decisiveWindow {
              parts.append(UsageSeverity.spokenRemaining(for: window))
              parts.append(UsagePresentation.title(for: window))
  ```
- [ ] **Step 8: Run the UI test again (Step 6 command).** Expected: PASSES.
- [ ] **Step 9: Docs (same task as the behavior).** In `docs/user-guide/reading-limits.md`, at the end of the "Freshness and status labels" section (after the "Do not read a retained value as current." paragraph), add:
  ```markdown
  Status and severity are never encoded by color alone. Every status pill pairs its tint with a symbol and a written label, the reserve dial adds a **LOW** or **CRITICAL** text marker below its percentage when a window enters the caution or critical band, and VoiceOver speaks the same band ("running low", "critically low") in the card summary.
  ```
  Then run `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected: passes.
- [ ] **Step 10: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Dashboard/UsageSeverity.swift apps/apple/Vigil/Dashboard/AccountLimitSummary.swift apps/apple/Vigil/Support/DemoData.swift apps/apple/Vigil/AppModel.swift apps/apple/VigilTests/UsageSeverityTests.swift apps/apple/VigilTests/DemoDataTests.swift apps/apple/VigilUITests/VigilAccessibilityUITests.swift docs/user-guide/reading-limits.md && \
  git commit -m "Speak the severity band in the Home card summary with a near-limit demo state" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 19: MotionPolicy — reduce-prominent-animations calms the dial and refresh fills
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Create: `apps/apple/Vigil/Support/MotionPolicy.swift`
- Modify: `apps/apple/Vigil/Dashboard/ReserveDial.swift` (animation site, line 37 at main@c62061d)
- Modify: `apps/apple/Vigil/Dashboard/WindowRows.swift` (`LimitReservoirBar` animation site, lines 286-289)
- Test: `apps/apple/VigilTests/MotionPolicyTests.swift`

**Interfaces:**
- Consumes: `VigilPreferences.reduceProminentAnimations` and `AppModel.preferences` (canonical, PR-1); `@Environment(\.accessibilityReduceMotion)` (already read at both sites)
- Produces:
  ```swift
  enum MotionPolicy {
      static func animatesProminently(systemReduceMotion: Bool, reduceProminentAnimations: Bool) -> Bool
  }
  ```

Animation-site inventory (verified by grep over `apps/apple/Vigil`): `ReserveDial.swift:37` (`.animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: clamped)`) and `WindowRows.swift:286-289` (the `LimitReservoirBar` fill) are the dial/refresh animations — both animate when a refresh lands new values, and both already honor system Reduce Motion unconditionally, which stays true. `DashboardView.swift` has no explicit animation site (its refresh spinner is the system `ProgressView`/`refreshable` indicator, not calmable app code). `ObservedHistorySection.swift:290` is a row-expansion chevron toggle, not a prominent dial/refresh animation — deliberately out of scope.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/MotionPolicyTests.swift`:
  ```swift
  import XCTest
  @testable import Vigil

  final class MotionPolicyTests: XCTestCase {
      /// System Reduce Motion always wins; the in-app preference can only
      /// subtract motion, never add it back while the system asks for calm.
      func testProminentAnimationRunsOnlyWhenNothingAsksForCalm() {
          XCTAssertTrue(MotionPolicy.animatesProminently(
              systemReduceMotion: false, reduceProminentAnimations: false
          ))
          XCTAssertFalse(MotionPolicy.animatesProminently(
              systemReduceMotion: true, reduceProminentAnimations: false
          ))
          XCTAssertFalse(MotionPolicy.animatesProminently(
              systemReduceMotion: false, reduceProminentAnimations: true
          ))
          XCTAssertFalse(MotionPolicy.animatesProminently(
              systemReduceMotion: true, reduceProminentAnimations: true
          ))
      }
  }
  ```
- [ ] **Step 2: Run the test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests/MotionPolicyTests
  ```
  Expected: BUILD FAILS with `cannot find 'MotionPolicy' in scope`.
- [ ] **Step 3: Minimal implementation.** Create `apps/apple/Vigil/Support/MotionPolicy.swift`:
  ```swift
  import Foundation

  /// One decision for every prominent animation. The system Reduce Motion
  /// setting is respected unconditionally; the in-app "reduce prominent
  /// animations" preference additionally calms dial and refresh animations
  /// for users who do not use the system setting (spec §5). Preferences can
  /// only subtract motion.
  enum MotionPolicy {
      static func animatesProminently(
          systemReduceMotion: Bool,
          reduceProminentAnimations: Bool
      ) -> Bool {
          !systemReduceMotion && !reduceProminentAnimations
      }
  }
  ```
- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: PASS.
- [ ] **Step 5: Wire the dial.** In `apps/apple/Vigil/Dashboard/ReserveDial.swift`, add below the existing `@Environment(\.accessibilityReduceMotion) private var reduceMotion` (line 10):
  ```swift
      @Environment(AppModel.self) private var model
  ```
  and replace line 37:
  ```swift
          .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: clamped)
  ```
  with:
  ```swift
          .animation(
              MotionPolicy.animatesProminently(
                  systemReduceMotion: reduceMotion,
                  reduceProminentAnimations: model.preferences.reduceProminentAnimations
              ) ? .easeOut(duration: 0.3) : nil,
              value: clamped
          )
  ```
  (Every `ReserveDial` render sits under the app's `.environment(model)` — `VigilApp.swift:134` — and the only Dashboard `#Preview` (`DashboardView.swift:217-225`) supplies an `AppModel`, so the environment lookup cannot trap.)
- [ ] **Step 6: Wire the reservoir fill.** In `apps/apple/Vigil/Dashboard/WindowRows.swift` inside `LimitReservoirBar`, add below `@Environment(\.accessibilityReduceMotion) private var reduceMotion` (line 270):
  ```swift
      @Environment(AppModel.self) private var model
  ```
  and replace lines 286-289:
  ```swift
          .animation(
              reduceMotion ? nil : .easeOut(duration: 0.25),
              value: remaining
          )
  ```
  with:
  ```swift
          .animation(
              MotionPolicy.animatesProminently(
                  systemReduceMotion: reduceMotion,
                  reduceProminentAnimations: model.preferences.reduceProminentAnimations
              ) ? .easeOut(duration: 0.25) : nil,
              value: remaining
          )
  ```
- [ ] **Step 7: Build + full app-test regression run.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests
  ```
  Expected: all green. (No docs change: the default `reduceProminentAnimations == false` reproduces today's shipped behavior exactly; the user-facing setting row and its documentation land with the Settings page assembly in PR-4.)
- [ ] **Step 8: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/MotionPolicy.swift apps/apple/Vigil/Dashboard/ReserveDial.swift apps/apple/Vigil/Dashboard/WindowRows.swift apps/apple/VigilTests/MotionPolicyTests.swift && \
  git commit -m "Calm dial and refresh animations behind MotionPolicy and the reduce-animations preference" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 20: HapticPolicy — gated confirmation haptics on link, removal, and destructive settings confirms
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Create: `apps/apple/Vigil/Support/ConfirmationHaptics.swift`
- Modify: `apps/apple/Vigil/Onboarding/AddAccountView.swift` (success path in `run`, lines 299-300 at main@c62061d; modifier chain after `.onDisappear`, line 96)
- Modify: `apps/apple/Vigil/Connections/ConnectionsView.swift` (`remove`/`finishRemovalWithHistoryRecovery`, lines 147-163; root `ZStack` modifier chain)
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (repair-backup delete action lines 171-177; `performFullRecoveryReset` lines 306-313; root `ZStack` modifier chain)
- Test: `apps/apple/VigilTests/HapticPolicyTests.swift`

**Interfaces:**
- Consumes: `VigilPreferences.hapticsEnabled` via `AppModel.preferences` (canonical, PR-1); SwiftUI `sensoryFeedback(trigger:_:)` (iOS 17)
- Produces:
  ```swift
  enum HapticPolicy {
      static func confirmationFeedback(hapticsEnabled: Bool) -> SensoryFeedback?
  }
  extension View {
      func vigilConfirmationHaptic(trigger: Int, hapticsEnabled: @escaping () -> Bool) -> some View
  }
  ```

Confirmation haptics are one of the three named 1.0.0 behavior exceptions (spec, Non-negotiable invariants): default ON, with `prefs.hapticsEnabled` as the off switch. One shared helper makes every confirm surface take the same gate, and the gate itself is a pure function tested without rendering.

- [ ] **Step 1: Write the failing test.** Create `apps/apple/VigilTests/HapticPolicyTests.swift`:
  ```swift
  import SwiftUI
  import XCTest
  @testable import Vigil

  final class HapticPolicyTests: XCTestCase {
      func testConfirmationFeedbackFiresOnlyWhenEnabled() {
          XCTAssertEqual(HapticPolicy.confirmationFeedback(hapticsEnabled: true), .success)
          XCTAssertNil(HapticPolicy.confirmationFeedback(hapticsEnabled: false))
      }
  }
  ```
- [ ] **Step 2: Run the test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests/HapticPolicyTests
  ```
  Expected: BUILD FAILS with `cannot find 'HapticPolicy' in scope`.
- [ ] **Step 3: Minimal implementation.** Create `apps/apple/Vigil/Support/ConfirmationHaptics.swift`:
  ```swift
  import SwiftUI

  /// Confirmation haptics are added in 1.0.0 (default on, prefs.hapticsEnabled
  /// as the off switch). The gate lives here so every confirm surface makes
  /// the same decision and tests can pin it without rendering a view.
  enum HapticPolicy {
      static func confirmationFeedback(hapticsEnabled: Bool) -> SensoryFeedback? {
          hapticsEnabled ? .success : nil
      }
  }

  extension View {
      /// Fires one success haptic each time `trigger` increments, unless the
      /// user disabled in-app haptics. Attach at the surface that owns the
      /// confirmed action (link, removal, destructive settings action). The
      /// preference is read at fire time, not attach time.
      func vigilConfirmationHaptic(
          trigger: Int,
          hapticsEnabled: @escaping () -> Bool
      ) -> some View {
          sensoryFeedback(trigger: trigger) { _, _ in
              HapticPolicy.confirmationFeedback(hapticsEnabled: hapticsEnabled())
          }
      }
  }
  ```
- [ ] **Step 4: Run the test to verify it passes.** Same command as Step 2. Expected: PASS.
- [ ] **Step 5: Wire "account linked".** In `apps/apple/Vigil/Onboarding/AddAccountView.swift`: add a state property below `@State private var activeLinkAttemptID: UUID?` (line 23):
  ```swift
      @State private var confirmedLinks = 0
  ```
  In `run(_:allowUnverified:allowReplace:)`, change the success tail (lines 299-300):
  ```swift
              guard !Task.isCancelled, activeLinkAttemptID == attemptID else { return }
              confirmedLinks += 1
              dismiss()
  ```
  And in `body`, insert after `.onDisappear { cancelLinking() }` (line 96):
  ```swift
          .vigilConfirmationHaptic(trigger: confirmedLinks) { model.preferences.hapticsEnabled }
  ```
- [ ] **Step 6: Wire "removal completed".** In `apps/apple/Vigil/Connections/ConnectionsView.swift`: add below `@State private var removalError: String?` (line 9):
  ```swift
      @State private var confirmedRemovals = 0
  ```
  Change `remove(_:)` (lines 147-155) and `finishRemovalWithHistoryRecovery(_:)` (lines 157-163) success paths:
  ```swift
      private func remove(_ account: AccountRef) async {
          do {
              try await model.removeAccount(account)
              confirmedRemovals += 1
          } catch AppModel.LinkError.historyRecoveryRequired(_) {
              accountPendingHistoryRecovery = account
          } catch {
              removalError = error.localizedDescription
          }
      }

      private func finishRemovalWithHistoryRecovery(_ account: AccountRef) async {
          do {
              try await model.finishRemovalByDeletingAllHistory(account)
              confirmedRemovals += 1
          } catch {
              removalError = error.localizedDescription
          }
      }
  ```
  And on the root `ZStack`'s modifier chain, insert after `.toolbarBackground(.visible, for: .navigationBar)` (line 48):
  ```swift
          .vigilConfirmationHaptic(trigger: confirmedRemovals) { model.preferences.hapticsEnabled }
  ```
- [ ] **Step 7: Wire the destructive settings confirms.** In `apps/apple/Vigil/Settings/SettingsView.swift`: add below `@State private var fullRecoveryCompleted = false` (line 15):
  ```swift
      @State private var confirmedDestructiveActions = 0
  ```
  In the repair-backup confirmation dialog action (lines 171-177), change to:
  ```swift
              Button("Delete Repair Backup", role: .destructive) {
                  do {
                      try model.deleteAccountRepairBackups()
                      confirmedDestructiveActions += 1
                  } catch {
                      repairBackupError = error.localizedDescription
                  }
              }
  ```
  In `performFullRecoveryReset()` (lines 306-313), change the success branch to:
  ```swift
          do {
              try await model.resetAllLocalDataForRecovery()
              fullRecoveryCompleted = true
              confirmedDestructiveActions += 1
          } catch {
              fullRecoveryError = error.localizedDescription
          }
  ```
  And insert after `.toolbarBackground(.visible, for: .navigationBar)` (line 143):
  ```swift
          .vigilConfirmationHaptic(trigger: confirmedDestructiveActions) { model.preferences.hapticsEnabled }
  ```
- [ ] **Step 8: Full app-test regression run.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests
  ```
  Expected: all green (haptic firing itself is simulator-silent; the gate is what's tested). No docs change here: the on/off setting row and its copy land with PR-4's Settings assembly.
- [ ] **Step 9: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/ConfirmationHaptics.swift apps/apple/Vigil/Onboarding/AddAccountView.swift apps/apple/Vigil/Connections/ConnectionsView.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/HapticPolicyTests.swift && \
  git commit -m "Add hapticsEnabled-gated confirmation haptics to link, removal, and destructive confirms" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 21: Widget redaction when the app lock is on
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Create: `apps/apple/Vigil/Support/WidgetPresentationPolicy.swift` (dual-membership: app + widget targets)
- Modify: `apps/apple/project.yml` (VigilWidgets sources, after line 137 `- path: Vigil/Support/UsagePresentation.swift`)
- Modify: `apps/apple/Vigil/AppModel.swift` (`lockEnabled` didSet lines 95-97; `loadFromDisk` line 247)
- Modify: `apps/apple/VigilWidgets/UsageTimelineProvider.swift` (`UsageEntry` lines 76-80; `snapshot(for:in:)` lines 102-116; `timeline(for:in:)` lines 118-212; static `timeline` builder lines 279-315)
- Modify: `apps/apple/VigilWidgets/VigilWidgets.swift` (`SmallUsageView` body line 56; `CircularUsageView` body line 229)
- Modify: `docs/user-guide/privacy-deletion-notifications.md` (line 61), `docs/user-guide/troubleshooting.md` (line 76)
- Test: `apps/apple/VigilTests/WidgetPresentationPolicyTests.swift`

**Interfaces:**
- Consumes: `VigilPreferences.widgetRedactedWhenLocked` and `VigilPreferences(defaults:)` (canonical, PR-1 — `VigilPreferences.swift` is already dual-membership per the contract); `SharedContainer.appGroupID` (`SharedContainer.swift:13`); `AppModel.reloadWidgets()` (`AppModel.swift:2393-2397`); `UsagePresentation.statusTitle(_:)`
- Produces:
  ```swift
  enum WidgetPresentationPolicy {
      static let appLockMirrorKey: String  // "app.vigil.lockEnabled.mirror"
      static func mirrorAppLock(enabled: Bool, into defaults: UserDefaults?)
      static func appLockEnabled(in defaults: UserDefaults?) -> Bool
      static func isRedacted(redactWhenLocked: Bool, appLockEnabled: Bool) -> Bool
  }
  // UsageEntry gains: var redactsUsage: Bool = false
  ```

Lock-state plumbing (investigated): `lockEnabled` lives in **standard** `UserDefaults` under `"app.vigil.lockEnabled"` (`AppModel.swift:95-97`, deliberately app-only per spec §1), so the widget process cannot read it. The app therefore mirrors the flag into the App Group suite under a distinct mirror key, and the widget combines that mirror with `prefs.widgetRedactedWhenLocked`. Redaction only removes percentages/metrics; provider name, status, and data age stay (the "ages visibly" invariant survives redaction).

- [ ] **Step 1: Write the failing tests.** Create `apps/apple/VigilTests/WidgetPresentationPolicyTests.swift`:
  ```swift
  import Foundation
  import XCTest
  @testable import Vigil

  final class WidgetPresentationPolicyTests: XCTestCase {
      /// Percentages hide only when the user asked for redaction AND the app
      /// lock is actually on. Either alone changes nothing — the default
      /// (preference off) reproduces today's widget exactly.
      func testRedactionRequiresBothThePreferenceAndTheAppLock() {
          XCTAssertFalse(WidgetPresentationPolicy.isRedacted(redactWhenLocked: false, appLockEnabled: false))
          XCTAssertFalse(WidgetPresentationPolicy.isRedacted(redactWhenLocked: true, appLockEnabled: false))
          XCTAssertFalse(WidgetPresentationPolicy.isRedacted(redactWhenLocked: false, appLockEnabled: true))
          XCTAssertTrue(WidgetPresentationPolicy.isRedacted(redactWhenLocked: true, appLockEnabled: true))
      }

      func testAppLockMirrorRoundTripsThroughAnIsolatedSuite() throws {
          let suiteName = "vigil.tests.widget-policy.\(UUID().uuidString)"
          let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
          defer { defaults.removePersistentDomain(forName: suiteName) }

          XCTAssertFalse(WidgetPresentationPolicy.appLockEnabled(in: defaults), "missing key must read as unlocked")
          WidgetPresentationPolicy.mirrorAppLock(enabled: true, into: defaults)
          XCTAssertTrue(WidgetPresentationPolicy.appLockEnabled(in: defaults))
          WidgetPresentationPolicy.mirrorAppLock(enabled: false, into: defaults)
          XCTAssertFalse(WidgetPresentationPolicy.appLockEnabled(in: defaults))
      }

      /// An unavailable suite (entitlement problem) must fail open to today's
      /// behavior — unredacted — never crash and never invent a lock.
      func testNilSuiteReadsAsUnlockedAndMirrorIsANoOp() {
          WidgetPresentationPolicy.mirrorAppLock(enabled: true, into: nil)
          XCTAssertFalse(WidgetPresentationPolicy.appLockEnabled(in: nil))
      }
  }
  ```
- [ ] **Step 2: Run the tests to verify they fail.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests/WidgetPresentationPolicyTests
  ```
  Expected: BUILD FAILS with `cannot find 'WidgetPresentationPolicy' in scope`.
- [ ] **Step 3: Minimal implementation of the policy.** Create `apps/apple/Vigil/Support/WidgetPresentationPolicy.swift`:
  ```swift
  import Foundation

  /// Pure decisions about what a widget may show. The widget process cannot
  /// read the app's standard-defaults lock flag (app.vigil.lockEnabled is
  /// deliberately app-only), so the app mirrors that flag into the shared
  /// App Group suite under a separate mirror key; this policy combines the
  /// mirror with prefs.widgetRedactedWhenLocked. Redaction only removes
  /// detail (percentages, metrics) — it never hides provider identity,
  /// status, or data age, and it fails open to unredacted when the shared
  /// suite is unavailable.
  enum WidgetPresentationPolicy {
      /// App-lock mirror key in the App Group suite. Written by the app only.
      static let appLockMirrorKey = "app.vigil.lockEnabled.mirror"

      static func mirrorAppLock(enabled: Bool, into defaults: UserDefaults?) {
          defaults?.set(enabled, forKey: appLockMirrorKey)
      }

      static func appLockEnabled(in defaults: UserDefaults?) -> Bool {
          defaults?.bool(forKey: appLockMirrorKey) ?? false
      }

      static func isRedacted(redactWhenLocked: Bool, appLockEnabled: Bool) -> Bool {
          redactWhenLocked && appLockEnabled
      }
  }
  ```
  Add it to the widget target in `apps/apple/project.yml` — after the line `- path: Vigil/Support/UsagePresentation.swift` (line 137) insert:
  ```yaml
      - path: Vigil/Support/WidgetPresentationPolicy.swift
  ```
- [ ] **Step 4: Run the tests to verify they pass.** Same command as Step 2 (xcodegen re-runs automatically in it). Expected: 3 tests PASS.
- [ ] **Step 5: Mirror the lock flag from the app.** In `apps/apple/Vigil/AppModel.swift`, replace the `lockEnabled` property (lines 95-97):
  ```swift
      var lockEnabled: Bool {
          didSet {
              UserDefaults.standard.set(lockEnabled, forKey: "app.vigil.lockEnabled")
              // The widget cannot read standard defaults; keep the App Group
              // mirror current and re-render widgets so redaction tracks the
              // lock without waiting for the next timeline reload.
              WidgetPresentationPolicy.mirrorAppLock(
                  enabled: lockEnabled,
                  into: UserDefaults(suiteName: SharedContainer.appGroupID)
              )
              reloadWidgets()
          }
      }
  ```
  Property observers do not fire during `init`, so also refresh the mirror once per launch — in `loadFromDisk()` insert directly after `hasLoadedFromDisk = true` (line 248):
  ```swift
          WidgetPresentationPolicy.mirrorAppLock(
              enabled: lockEnabled,
              into: UserDefaults(suiteName: SharedContainer.appGroupID)
          )
  ```
  (`loadFromDisk` runs post-`UIApplicationMain` under `SuspensionGuard`, so this write cannot join the pre-main 0xdead10cc window that keeps I/O out of `init`.)
- [ ] **Step 6: Thread redaction through the timeline provider.** In `apps/apple/VigilWidgets/UsageTimelineProvider.swift`:
  - `UsageEntry` (lines 76-80) becomes:
    ```swift
    struct UsageEntry: TimelineEntry {
        let date: Date
        let account: AccountRef?
        let snapshot: ProviderSnapshot?
        var redactsUsage: Bool = false
    }
    ```
  - Add a private helper inside `UsageTimelineProvider`:
    ```swift
        private static func shouldRedactUsage() -> Bool {
            let defaults = UserDefaults(suiteName: SharedContainer.appGroupID)
            let preferences = VigilPreferences(defaults: defaults ?? .standard)
            return WidgetPresentationPolicy.isRedacted(
                redactWhenLocked: preferences.widgetRedactedWhenLocked,
                appLockEnabled: WidgetPresentationPolicy.appLockEnabled(in: defaults)
            )
        }
    ```
  - In `snapshot(for:in:)`, change the return (lines 111-116) to:
    ```swift
            return UsageEntry(
                date: Date(),
                account: account,
                snapshot: snapshot ?? (context.isPreview ? Self.sampleSnapshot : nil),
                redactsUsage: context.isPreview ? false : Self.shouldRedactUsage()
            )
    ```
    (Gallery previews stay unredacted — they show sample data, not the user's.)
  - In `timeline(for:in:)`, capture `let redactsUsage = Self.shouldRedactUsage()` as the first line, and pass it through both `Self.timeline(...)` calls (lines 141 and 207-211) as `redactsUsage: redactsUsage`.
  - Change the static builder signature (lines 279-283) to:
    ```swift
        private static func timeline(
            account: AccountRef?,
            snapshot: ProviderSnapshot?,
            refreshAfter: Date? = nil,
            redactsUsage: Bool = false
        ) -> Timeline<UsageEntry> {
    ```
    and add `redactsUsage: redactsUsage` to both `UsageEntry(...)` constructions inside it (lines 285-289 and 300-304).
- [ ] **Step 7: Render the redacted bodies.** In `apps/apple/VigilWidgets/VigilWidgets.swift`:
  - `SmallUsageView.body` (line 56): change the leading branch structure to:
    ```swift
        var body: some View {
            if entry.redactsUsage, let snapshot = entry.snapshot {
                redactedBody(snapshot)
            } else if let snapshot = entry.snapshot {
    ```
    (the existing `if let snapshot = entry.snapshot {` body becomes the `else if` branch; the trailing `else` unlinked branch is unchanged), and add the private view builder:
    ```swift
        /// Provider name and status without percentages (spec §6). Data age
        /// stays visible: redaction hides detail, never freshness honesty.
        private func redactedBody(_ snapshot: ProviderSnapshot) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(
                        entry.account.map(UsagePresentation.accountTitle)
                            ?? snapshot.providerId.capitalized
                    )
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(UsagePresentation.statusTitle(snapshot.status))
                    .font(.system(.headline, design: .rounded))
                Group {
                    if snapshot.fetchedAt > .distantPast {
                        Text(snapshot.fetchedAt, style: .relative)
                    } else {
                        Text("No update yet")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    ```
  - `CircularUsageView.body` (line 229): insert a first branch before the existing `if let snapshot = entry.snapshot, let tightest = ...`:
    ```swift
            if entry.redactsUsage, entry.snapshot != nil {
                VStack(spacing: 1) {
                    Text(providerLetter)
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                }
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text("\(entry.account?.displayName ?? "Vigil"), usage hidden while the app lock is on")
                )
            } else if let snapshot = entry.snapshot,
    ```
    (turn the existing first branch's `if` into `else if`).
- [ ] **Step 8: Build both targets and rerun the policy + app suites.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests
  ```
  Expected: green (the scheme build compiles the VigilWidgets target too, proving the widget-side changes and the project.yml dual membership).
- [ ] **Step 9: Docs (same task as the behavior — both files currently claim the lock never affects widgets).**
  - `docs/user-guide/privacy-deletion-notifications.md` line 61, replace the paragraph with:
    ```markdown
    The lock protects the app surface. It does not add another encryption layer to local files or hide notification previews. By default it also does not change a configured widget. Turning on **Settings → Widgets → Redact widget when locked** makes widgets show only the provider name, status, and data age — no percentages, balances, or reset times — while the app lock is enabled. Remove the widget if even that should not remain visible outside the app.
    ```
  - `docs/user-guide/troubleshooting.md` line 76, replace with:
    ```markdown
    By default the app lock does not hide widgets. With **Redact widget when locked** enabled in Settings → Widgets, a locked configuration shows only the provider name, status, and data age. Remove a widget if its contents are too sensitive for the Home or Lock Screen.
    ```
  - Run `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected: passes.
- [ ] **Step 10: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/WidgetPresentationPolicy.swift apps/apple/project.yml apps/apple/Vigil/AppModel.swift apps/apple/VigilWidgets/UsageTimelineProvider.swift apps/apple/VigilWidgets/VigilWidgets.swift apps/apple/VigilTests/WidgetPresentationPolicyTests.swift docs/user-guide/privacy-deletion-notifications.md docs/user-guide/troubleshooting.md && \
  git commit -m "Redact widget percentages behind the app-lock mirror and widgetRedactedWhenLocked" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

### Task 22: Widgets follow the theme override (widgetsFollowThemeOverride consumption)
**PR:** PR-3 — accessibility extras + widget options
**Files:**
- Modify: `apps/apple/Vigil/Support/WidgetPresentationPolicy.swift` (add `colorSchemeOverride`)
- Modify: `apps/apple/VigilWidgets/VigilWidgets.swift` (`UsageWidgetEntryView`, lines 28-40 at main@c62061d)
- Test: `apps/apple/VigilTests/WidgetPresentationPolicyTests.swift`

**Interfaces:**
- Consumes: `VigilPreferences.Appearance` and its `colorScheme` property (`system → nil`, canonical, PR-1); `VigilPreferences.widgetsFollowThemeOverride` (default `true`); `SharedContainer.appGroupID`
- Produces:
  ```swift
  static func colorSchemeOverride(
      appearance: VigilPreferences.Appearance,
      followsThemeOverride: Bool
  ) -> ColorScheme?
  ```

- [ ] **Step 0: Check for PR-1 leftovers first.** Run `grep -rn "widgetsFollowThemeOverride" /Users/biscuit/Vigil/apps/apple/VigilWidgets`. If PR-1 already wired consumption into the entry view, skip Steps 3b/4's view edit and only land the pure policy + tests below (adjusting the view to route through `WidgetPresentationPolicy.colorSchemeOverride` so the decision has exactly one tested home). At main@c62061d there is no consumption — `VigilWidgets.swift` never reads preferences.
- [ ] **Step 1: Write the failing test.** Append to `final class WidgetPresentationPolicyTests` (add `import SwiftUI` to the file's imports for `ColorScheme`):
  ```swift
  /// nil = follow the system appearance. The user's in-app theme override
  /// reaches widgets only while prefs.widgetsFollowThemeOverride is on
  /// (default on); switching it off pins widgets to the system theme.
  func testWidgetThemeOverrideOnlyAppliesWhileFollowingIsOn() {
      XCTAssertNil(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .system, followsThemeOverride: true
      ))
      XCTAssertEqual(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .light, followsThemeOverride: true
      ), .light)
      XCTAssertEqual(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .dark, followsThemeOverride: true
      ), .dark)
      XCTAssertNil(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .system, followsThemeOverride: false
      ))
      XCTAssertNil(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .light, followsThemeOverride: false
      ))
      XCTAssertNil(WidgetPresentationPolicy.colorSchemeOverride(
          appearance: .dark, followsThemeOverride: false
      ))
  }
  ```
- [ ] **Step 2: Run the test to verify it fails.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests/WidgetPresentationPolicyTests
  ```
  Expected: BUILD FAILS with `type 'WidgetPresentationPolicy' has no member 'colorSchemeOverride'`.
- [ ] **Step 3: Minimal implementation.** (a) In `apps/apple/Vigil/Support/WidgetPresentationPolicy.swift`, change `import Foundation` to also `import SwiftUI`, and append inside the enum:
  ```swift
      /// nil = follow the system appearance. Appearance.colorScheme already
      /// maps system → nil; this only adds the follow gate on top.
      static func colorSchemeOverride(
          appearance: VigilPreferences.Appearance,
          followsThemeOverride: Bool
      ) -> ColorScheme? {
          guard followsThemeOverride else { return nil }
          return appearance.colorScheme
      }
  ```
  (b) In `apps/apple/VigilWidgets/VigilWidgets.swift`, replace `UsageWidgetEntryView` (lines 28-40):
  ```swift
  struct UsageWidgetEntryView: View {
      @Environment(\.widgetFamily) private var family
      let entry: UsageEntry

      /// Reads the shared suite at render time: widget renders are rare and
      /// WidgetKit re-renders on reloadAllTimelines when preferences change.
      private var themeOverride: ColorScheme? {
          let defaults = UserDefaults(suiteName: SharedContainer.appGroupID)
          let preferences = VigilPreferences(defaults: defaults ?? .standard)
          return WidgetPresentationPolicy.colorSchemeOverride(
              appearance: preferences.appearance,
              followsThemeOverride: preferences.widgetsFollowThemeOverride
          )
      }

      var body: some View {
          if let scheme = themeOverride {
              familyView.environment(\.colorScheme, scheme)
          } else {
              familyView
          }
      }

      @ViewBuilder
      private var familyView: some View {
          switch family {
          case .accessoryCircular:
              CircularUsageView(entry: entry)
          default:
              SmallUsageView(entry: entry)
          }
      }
  }
  ```
- [ ] **Step 4: Run the test to verify it passes, then the full app suite + widget compile.**
  ```sh
  cd /Users/biscuit/Vigil/apps/apple && \
  DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    test CODE_SIGNING_ALLOWED=NO -only-testing:VigilTests
  ```
  Expected: all green, and the VigilWidgets target compiles as part of the scheme build. No docs change here: user-facing wording for the Widgets settings section (including this toggle's caption) ships with the PR-4 Settings page assembly; the on-device theme render check joins the release walk per spec §9.
- [ ] **Step 5: Commit.**
  ```sh
  cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Support/WidgetPresentationPolicy.swift apps/apple/VigilWidgets/VigilWidgets.swift apps/apple/VigilTests/WidgetPresentationPolicyTests.swift && \
  git commit -m "Apply the theme override to widgets behind widgetsFollowThemeOverride" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```


## PR-4

### Task 23: Extract the shared Settings row components into their own file
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/SettingsComponents.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (private helpers at lines 225–274, private row structs at lines 363–447, call sites at lines 24–33, 35, 94, 109, 123)
- Test: `apps/apple/VigilTests/SettingsComponentsTests.swift`

**Interfaces:**
- Consumes: `VigilPalette`, `VigilSpacing` (`apps/apple/Vigil/DesignSystem/VigilTheme.swift`), `.vigilInsetSurface()` modifier.
- Produces (internal, app target):
  - `struct SettingsSection<Content: View>: View { let title: String; @ViewBuilder let content: () -> Content }`
  - `struct SettingsToggleRow: View { let title: String; let detail: String; let identifier: String; @Binding var isOn: Bool }`
  - `struct SettingsNavigationRow: View { let symbol: String; let title: String; let detail: String; var showsChevron = true }` (moved, no longer `private`)
  - `struct SettingsValueRow: View { let label: String; let value: String }` (moved, no longer `private`)

Context: the group's later tasks create one file per Settings section. Those files need the row components that today are `private` to `SettingsView.swift`. This task moves them, bit-for-bit in layout, into a shared file. The Face ID toggle also gains its `vigil.settings.*` identifier here because the shared toggle component requires one.

- [ ] **Step 1: Write the failing test** — create `apps/apple/VigilTests/SettingsComponentsTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Vigil

/// The Settings row components must be constructible outside SettingsView.swift
/// so each section subview (one file per section) reuses them without forking
/// the card language.
final class SettingsComponentsTests: XCTestCase {
    func testSettingsRowComponentsAreConstructibleFromOtherFiles() {
        _ = SettingsSection(title: "About") { EmptyView() }
        _ = SettingsValueRow(label: "Version", value: "1.0.0 (22)")
        _ = SettingsNavigationRow(
            symbol: "lock.shield",
            title: "How Vigil handles your data",
            detail: "Credentials, snapshots, and direct provider requests"
        )
        _ = SettingsToggleRow(
            title: "Require Face ID or Touch ID",
            detail: "Lock Vigil whenever it returns to the foreground.",
            identifier: "vigil.settings.appLock",
            isOn: .constant(false)
        )
    }
}
```
- [ ] **Step 2: Run test to verify it fails** — from `apps/apple`:
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/SettingsComponentsTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: the VigilTests target fails to compile — `error: cannot find 'SettingsSection' in scope` (and the same for `SettingsToggleRow`), ending in `** TEST FAILED **`. `SettingsNavigationRow`/`SettingsValueRow` exist but are `private` to `SettingsView.swift`, so they also fail resolution from the test file.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/SettingsComponents.swift`. `SettingsSection` reproduces the `settingsSection(_:content:)` layout from `SettingsView.swift:225-235`; `SettingsToggleRow` reproduces `adaptiveToggle` + `settingCopy` from lines 237–274 and adds the identifier on the `Toggle`; the two row structs move verbatim from lines 363–447 with `private` dropped:
```swift
import SwiftUI

/// Shared building blocks for the Settings page and its per-section subviews.
/// Extracted from SettingsView so each section lives in its own file without
/// forking the card language.

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
            content()
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let identifier: String
    @Binding var isOn: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    copy
                    toggle
                }
            } else {
                HStack(spacing: 12) {
                    copy
                    Spacer(minLength: 12)
                    toggle
                }
            }
        }
        .padding(14)
        .vigilInsetSurface()
        .accessibilityElement(children: .contain)
    }

    private var toggle: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .accessibilityIdentifier(identifier)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsNavigationRow: View {
    let symbol: String
    let title: String
    let detail: String
    var showsChevron = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    icon
                    copy
                    if showsChevron { chevron }
                }
            } else {
                HStack(spacing: 12) {
                    icon
                    copy
                    Spacer(minLength: 8)
                    if showsChevron { chevron }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .vigilInsetSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(VigilPalette.signal)
            .frame(width: 36, height: 36)
            .background(VigilPalette.signal.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(VigilPalette.ink)
            Text(detail).font(.caption).foregroundStyle(VigilPalette.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(VigilPalette.inkFaint)
            .accessibilityHidden(true)
    }
}

struct SettingsValueRow: View {
    let label: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) { labels }
            } else {
                HStack { labels }
            }
        }
        .font(.subheadline)
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var labels: some View {
        Text(label).foregroundStyle(VigilPalette.inkMuted)
        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        Text(value)
            .fontWeight(.semibold)
            .foregroundStyle(VigilPalette.ink)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
}
```
Then in `apps/apple/Vigil/Settings/SettingsView.swift`:
1. Delete the private `settingsSection`, `adaptiveToggle`, and `settingCopy` members (lines 225–274) and the private `SettingsNavigationRow`/`SettingsValueRow` structs (lines 363–447).
2. Replace every `settingsSection("X") {` call with `SettingsSection(title: "X") {` (Security line 24, Privacy line 35, Refresh line 94, Diagnostics line 109, About line 123).
3. Replace the Security toggle (lines 25–32) with:
```swift
                    SettingsSection(title: "Security") {
                        SettingsToggleRow(
                            title: "Require Face ID or Touch ID",
                            detail: "Lock Vigil whenever it returns to the foreground.",
                            identifier: "vigil.settings.appLock",
                            isOn: Binding(
                                get: { model.lockEnabled },
                                set: { model.lockEnabled = $0 }
                            )
                        )
                    }
```
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `Test Suite 'SettingsComponentsTests' passed` / `** TEST SUCCEEDED **`. Also run the existing Settings reachability regression:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilAccessibilityUITests/testDiagnosticExportIsReachableAtDefaultContentSize CODE_SIGNING_ALLOWED=NO
```
Expected: PASS (the extraction is behavior-preserving).
- [ ] **Step 5: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/SettingsComponents.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/SettingsComponentsTests.swift && git commit -m "Extract shared Settings row components for per-section subview files"
```

### Task 24: Deterministic preferences reset for UI tests + Settings UI-test scaffold
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Modify: `apps/apple/Vigil/VigilApp.swift` (new launch-configuration enum after line 68; call at top of `init()` body, currently line 78)
- Create: `apps/apple/VigilUITests/VigilSettingsUITests.swift`
- Test: `apps/apple/VigilTests/AppPreferencesLaunchConfigurationTests.swift`

**Interfaces:**
- Consumes: `SharedContainer.appGroupID` (`apps/apple/Vigil/Support/SharedContainer.swift:13`, value `"group.app.vigil.shared"`); the `prefs.*` key namespace from the `VigilPreferences` contract.
- Produces:
  - `enum AppPreferencesLaunchConfiguration { static func resetsPreferencesForUITesting(environment: [String: String]) -> Bool; static func resetPreferences(in defaults: UserDefaults, environment: [String: String]) }` (DEBUG-gated, mirroring `AppLockLaunchConfiguration` at `VigilApp.swift:25-37`)
  - New launch env var `VIGIL_UI_TEST_RESET_PREFS=1`.

Context: preferences persist in the App Group `UserDefaults` suite, so a UI test that toggles a control could leak state into the next test. Every Settings UI walk in this group launches with `VIGIL_UI_TEST_RESET_PREFS=1` so each run starts from contract defaults. Release builds never honor the override, matching the existing launch-configuration enums.

- [ ] **Step 1: Write the failing test** — create `apps/apple/VigilTests/AppPreferencesLaunchConfigurationTests.swift`:
```swift
import Foundation
import XCTest
@testable import Vigil

/// UI tests need deterministic preference defaults without weakening release
/// behavior. Style mirrors AppPrivacyPolicyTests' launch-hook tests.
final class AppPreferencesLaunchConfigurationTests: XCTestCase {
    func testResetHookRequiresExactOptIn() {
        XCTAssertTrue(
            AppPreferencesLaunchConfiguration.resetsPreferencesForUITesting(
                environment: ["VIGIL_UI_TEST_RESET_PREFS": "1"]
            )
        )
        XCTAssertFalse(
            AppPreferencesLaunchConfiguration.resetsPreferencesForUITesting(
                environment: [:]
            )
        )
        XCTAssertFalse(
            AppPreferencesLaunchConfiguration.resetsPreferencesForUITesting(
                environment: ["VIGIL_UI_TEST_RESET_PREFS": "true"]
            )
        )
    }

    func testResetRemovesOnlyPrefsNamespacedKeys() throws {
        let suiteName = "test.prefs.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("dark", forKey: "prefs.appearance")
        defaults.set(true, forKey: "prefs.pauseAllPolling")
        defaults.set(true, forKey: "app.vigil.lockEnabled")

        AppPreferencesLaunchConfiguration.resetPreferences(
            in: defaults,
            environment: ["VIGIL_UI_TEST_RESET_PREFS": "1"]
        )

        XCTAssertNil(defaults.object(forKey: "prefs.appearance"))
        XCTAssertNil(defaults.object(forKey: "prefs.pauseAllPolling"))
        XCTAssertTrue(
            defaults.bool(forKey: "app.vigil.lockEnabled"),
            "The reset must never touch keys outside the prefs. namespace"
        )
    }

    func testResetIsInertWithoutTheOptIn() throws {
        let suiteName = "test.prefs.noreset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("light", forKey: "prefs.appearance")

        AppPreferencesLaunchConfiguration.resetPreferences(
            in: defaults,
            environment: [:]
        )

        XCTAssertEqual(defaults.string(forKey: "prefs.appearance"), "light")
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/AppPreferencesLaunchConfigurationTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'AppPreferencesLaunchConfiguration' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — in `apps/apple/Vigil/VigilApp.swift`, after the `AppStorageNoticeLaunchConfiguration` enum's closing brace (line 68), add:
```swift
enum AppPreferencesLaunchConfiguration {
    /// Deterministic preference defaults for Settings UI walks. Preferences
    /// live in the App Group suite and would otherwise leak between UI-test
    /// launches. Release builds never honor process-environment overrides.
    static func resetsPreferencesForUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        environment["VIGIL_UI_TEST_RESET_PREFS"] == "1"
        #else
        false
        #endif
    }

    static func resetPreferences(
        in defaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard resetsPreferencesForUITesting(environment: environment) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("prefs.") {
            defaults.removeObject(forKey: key)
        }
    }
}
```
Then at the top of `VigilApp.init()` (before `let model = AppModel()` at line 79), add:
```swift
        if let sharedDefaults = UserDefaults(suiteName: SharedContainer.appGroupID) {
            AppPreferencesLaunchConfiguration.resetPreferences(in: sharedDefaults)
        }
```
(The wipe must precede `AppModel()` because `AppModel` constructs `VigilPreferences` from that suite.)
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Add the Settings UI-test scaffold (green regression, not a red test)** — create `apps/apple/VigilUITests/VigilSettingsUITests.swift` with the launch/scroll helpers mirrored from `VigilAccessibilityUITests` and one smoke test:
```swift
import UIKit
import XCTest

/// Settings-page walks and spoken-surface pins. Launch and scrolling
/// conventions mirror VigilAccessibilityUITests; every launch resets the
/// prefs.* namespace so walks start from contract defaults.
final class VigilSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = nil
    }

    func testSettingsPageOpensWithDemoAccounts() {
        launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        assertReachable("vigil.settings.exportDiagnostics")
        assertReachable("vigil.settings.appLock")
    }

    // MARK: - Launch and scrolling helpers

    private func launchSettings(contentSizeCategory: UIContentSizeCategory? = nil) {
        if app?.state != .notRunning {
            app?.terminate()
        }
        app = XCUIApplication()
        app.launchEnvironment["VIGIL_TAB"] = "settings"
        app.launchEnvironment["VIGIL_DEMO"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_FORCE_ACTIVE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_SUPPRESS_STORAGE_NOTICE"] = "1"
        app.launchEnvironment["VIGIL_UI_TEST_RESET_PREFS"] = "1"
        if let contentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                contentSizeCategory.rawValue,
            ]
        }
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func assertReachable(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = element(identifier)
        let scrollView = app.scrollViews.firstMatch

        if target.waitForExistence(timeout: 2), hasSafeVisibleArea(target) {
            return target
        }
        for _ in 0..<12 where scrollView.exists {
            scrollToward(target, in: scrollView)
            if target.waitForExistence(timeout: 1), hasSafeVisibleArea(target) {
                return target
            }
        }
        XCTAssertTrue(
            target.exists,
            "Missing accessibility element \(identifier)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            target.isHittable,
            "Accessibility element \(identifier) could not be reached by scrolling",
            file: file,
            line: line
        )
        return target
    }

    /// Switches and segmented controls are shorter than the 44-point card
    /// bar used by VigilAccessibilityUITests, so require 24 visible points.
    private func hasSafeVisibleArea(_ target: XCUIElement) -> Bool {
        guard target.exists, target.isHittable else { return false }
        return target.frame.intersection(safeApplicationFrame).height >= 24
    }

    private func tapVisiblePortion(of target: XCUIElement) {
        let visibleFrame = target.frame.intersection(safeApplicationFrame)
        XCTAssertGreaterThanOrEqual(visibleFrame.height, 24)
        let frame = target.frame
        let tapPoint = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let offset = CGVector(
            dx: (tapPoint.x - frame.minX) / frame.width,
            dy: (tapPoint.y - frame.minY) / frame.height
        )
        target.coordinate(withNormalizedOffset: offset).tap()
    }

    private var safeApplicationFrame: CGRect {
        app.frame.inset(
            by: UIEdgeInsets(top: 110, left: 8, bottom: 84, right: 8)
        )
    }

    private func scrollToward(_ target: XCUIElement, in scrollView: XCUIElement) {
        guard target.exists else {
            scrollView.swipeUp()
            return
        }
        if target.frame.midY < safeApplicationFrame.midY {
            scrollView.swipeDown()
        } else {
            scrollView.swipeUp()
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
```
Run it:
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testSettingsPageOpensWithDemoAccounts CODE_SIGNING_ALLOWED=NO
```
Expected: PASS (both identifiers exist after Task 23).
- [ ] **Step 6: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/VigilApp.swift apps/apple/VigilTests/AppPreferencesLaunchConfigurationTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift && git commit -m "Add a DEBUG-only prefs reset launch hook and the Settings UI-walk scaffold"
```

### Task 25: Appearance section
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/AppearanceSettingsSection.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (insert as first child of the sections `VStack`, above `SettingsSection(title: "Security")`), `docs/user-guide/setup.md` (insert before `## Re-link or remove an account`, line 86)
- Test: `apps/apple/VigilTests/AppearanceSectionTests.swift`, `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes (contract): `model.preferences: VigilPreferences`; `var appearance: VigilPreferences.Appearance` (cases `.system`, `.light`, `.dark`, default `.system`).
- Produces: `struct AppearanceSettingsSection: View { static let choices: [VigilPreferences.Appearance] }`; `extension VigilPreferences.Appearance { var displayName: String }` (app target; UI copy stays out of the store per "VigilKit stays UI-free" and the store file stays copy-free).

- [ ] **Step 1: Write the failing unit test** — create `apps/apple/VigilTests/AppearanceSectionTests.swift`:
```swift
import SwiftUI
import XCTest
@testable import Vigil

final class AppearanceSectionTests: XCTestCase {
    func testAppearanceChoicesCoverSystemLightDarkInOrder() {
        XCTAssertEqual(AppearanceSettingsSection.choices, [.system, .light, .dark])
    }

    func testAppearanceSpokenNamesMatchTheSegmentLabels() {
        XCTAssertEqual(VigilPreferences.Appearance.system.displayName, "System")
        XCTAssertEqual(VigilPreferences.Appearance.light.displayName, "Light")
        XCTAssertEqual(VigilPreferences.Appearance.dark.displayName, "Dark")
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/AppearanceSectionTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'AppearanceSettingsSection' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/AppearanceSettingsSection.swift`:
```swift
import SwiftUI

extension VigilPreferences.Appearance {
    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct AppearanceSettingsSection: View {
    @Environment(AppModel.self) private var model

    static let choices: [VigilPreferences.Appearance] = [.system, .light, .dark]

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: VigilSpacing.small) {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(Self.choices, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vigil.settings.appearance")
                .padding(14)
                .vigilInsetSurface()

                Text("System follows your iPhone's appearance. Light and Dark pin Vigil to one theme.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
```
In `SettingsView.swift`, insert `AppearanceSettingsSection()` as the first child of the `VStack(alignment: .leading, spacing: VigilSpacing.large)`, immediately above `SettingsSection(title: "Security")`.
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Write the failing UI test** — add to `VigilSettingsUITests.swift`:
```swift
    func testAppearanceControlSpeaksAndSwitchesSelection() {
        launchSettings()
        let picker = assertReachable("vigil.settings.appearance")
        XCTAssertTrue(picker.buttons["System"].exists)
        XCTAssertTrue(picker.buttons["Light"].exists)
        XCTAssertTrue(picker.buttons["Dark"].exists)
        XCTAssertTrue(
            picker.buttons["System"].isSelected,
            "Appearance must default to System per the approved spec."
        )

        picker.buttons["Light"].tap()
        XCTAssertTrue(picker.buttons["Light"].isSelected)
        picker.buttons["System"].tap()
        XCTAssertTrue(picker.buttons["System"].isSelected)
    }
```
Run before building the app change? The section already exists after Step 3, so run this test now and expect PASS:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testAppearanceControlSpeaksAndSwitchesSelection CODE_SIGNING_ALLOWED=NO
```
Expected: PASS. (If it fails, the segmented control did not surface its identifier — fix the section, not the test.)
- [ ] **Step 6: Docs** — in `docs/user-guide/setup.md`, insert before the `## Re-link or remove an account` heading (line 86):
```markdown
## Adjust Vigil in Settings

Open **Settings** (the gear) from the Limits toolbar.

- **Appearance** — System follows the iPhone appearance; Light and Dark pin
  Vigil to one theme. The default is System.

```
Then verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected: exits 0.
- [ ] **Step 7: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/AppearanceSettingsSection.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/AppearanceSectionTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/setup.md && git commit -m "Add the Appearance settings section with a System/Light/Dark control"
```

### Task 26: Alerts section — global preset toggles and custom levels
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/AlertsSettingsSection.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (insert `AlertsSettingsSection()` directly below `AppearanceSettingsSection()`), `docs/user-guide/setup.md` (append a bullet under "Adjust Vigil in Settings")
- Test: `apps/apple/VigilTests/AlertLevelPresetsTests.swift`, `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes (contract): `var alertLevels: [Int]` (default `[80, 95]`); `static func addingValidatedLevel(_ level: Int, to levels: [Int]) -> [Int]?` (nil when out of 1...99, duplicate, or would exceed 8).
- Produces:
  - `enum AlertLevelPresets { static let all: [Int] /* [50, 80, 90, 95] */; static func toggling(_ preset: Int, in levels: [Int]) -> [Int] }`
  - `struct AlertLevelEditor: View { @Binding var levels: [Int]; let identifierPrefix: String }` — reused by Task 27's per-account editor.
  - `struct AlertsSettingsSection: View`

- [ ] **Step 1: Write the failing unit test** — create `apps/apple/VigilTests/AlertLevelPresetsTests.swift`:
```swift
import XCTest
@testable import Vigil

final class AlertLevelPresetsTests: XCTestCase {
    func testPresetsMatchTheApprovedSpec() {
        XCTAssertEqual(AlertLevelPresets.all, [50, 80, 90, 95])
    }

    func testTogglingAnInactivePresetAddsItSorted() {
        XCTAssertEqual(AlertLevelPresets.toggling(50, in: [80, 95]), [50, 80, 95])
    }

    func testTogglingAnActivePresetRemovesIt() {
        XCTAssertEqual(AlertLevelPresets.toggling(95, in: [80, 95]), [80])
    }

    func testTogglingCanEmptyTheSetEntirely() {
        XCTAssertEqual(AlertLevelPresets.toggling(80, in: [80]), [])
    }

    func testTogglingRefusesToBreakTheEightLevelCap() {
        let full = [10, 20, 30, 40, 50, 60, 70, 80]
        XCTAssertEqual(
            AlertLevelPresets.toggling(90, in: full), full,
            "A full set must refuse the addition and stay unchanged"
        )
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/AlertLevelPresetsTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'AlertLevelPresets' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/AlertsSettingsSection.swift`:
```swift
import SwiftUI

enum AlertLevelPresets {
    /// The four familiar presets from the approved design, in display order.
    static let all = [50, 80, 90, 95]

    /// Removes an active preset; otherwise adds it through the store's
    /// validation (sorted, unique, capped at 8). A full set refuses the
    /// addition and returns the levels unchanged.
    static func toggling(_ preset: Int, in levels: [Int]) -> [Int] {
        if levels.contains(preset) {
            return levels.filter { $0 != preset }
        }
        return VigilPreferences.addingValidatedLevel(preset, to: levels) ?? levels
    }
}

/// Preset toggles + custom-level entry over one bound level set. Reused by
/// the per-account override editor with a different identifier prefix.
struct AlertLevelEditor: View {
    @Binding var levels: [Int]
    let identifierPrefix: String

    @State private var customLevelText = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            VStack(spacing: 10) {
                ForEach(AlertLevelPresets.all, id: \.self) { preset in
                    SettingsToggleRow(
                        title: "\(preset)% used",
                        detail: "Notify when a usage window crosses \(preset) percent.",
                        identifier: "\(identifierPrefix).preset.\(preset)",
                        isOn: Binding(
                            get: { levels.contains(preset) },
                            set: { _ in levels = AlertLevelPresets.toggling(preset, in: levels) }
                        )
                    )
                }
            }

            let customLevels = levels.filter { !AlertLevelPresets.all.contains($0) }
            if !customLevels.isEmpty {
                VStack(spacing: 10) {
                    ForEach(customLevels, id: \.self) { level in
                        HStack(spacing: 12) {
                            Text("\(level)% used")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(VigilPalette.ink)
                            Spacer(minLength: 12)
                            Button("Remove") {
                                levels = levels.filter { $0 != level }
                            }
                            .font(.subheadline)
                            .accessibilityLabel("Remove the \(level) percent level")
                            .accessibilityIdentifier("\(identifierPrefix).remove.\(level)")
                        }
                        .padding(14)
                        .vigilInsetSurface()
                    }
                }
            }

            HStack(spacing: 12) {
                TextField("Custom percent (1–99)", text: $customLevelText)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Custom alert percent")
                    .accessibilityIdentifier("\(identifierPrefix).customField")
                Button("Add") { addCustomLevel() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Add custom alert level")
                    .accessibilityIdentifier("\(identifierPrefix).addCustom")
            }
            .padding(14)
            .vigilInsetSurface()

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifierPrefix).validation")
            }

            if levels.isEmpty {
                Text("No usage alerts will fire.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifierPrefix).noAlerts")
            }
        }
    }

    private func addCustomLevel() {
        guard let value = Int(customLevelText.trimmingCharacters(in: .whitespaces)) else {
            validationMessage = "Enter a whole percent from 1 to 99."
            return
        }
        guard let updated = VigilPreferences.addingValidatedLevel(value, to: levels) else {
            if levels.count >= 8 {
                validationMessage = "At most 8 alert levels can be active."
            } else if levels.contains(value) {
                validationMessage = "\(value)% is already active."
            } else {
                validationMessage = "Enter a whole percent from 1 to 99."
            }
            return
        }
        levels = updated
        customLevelText = ""
        validationMessage = nil
    }
}

struct AlertsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Alerts") {
            VStack(alignment: .leading, spacing: VigilSpacing.small) {
                AlertLevelEditor(
                    levels: $preferences.alertLevels,
                    identifierPrefix: "vigil.settings.alerts"
                )

                Text("Alert notifications name the provider, window, and percent crossed — never credentials or usage history.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
```
(The notification-privacy caption matches what `NotificationManager.deliver` actually sends: title `"\(account.displayName) \(windowName) at N%"`, `apps/apple/Vigil/Notifications/NotificationManager.swift:113-115`.)
In `SettingsView.swift`, insert `AlertsSettingsSection()` directly below `AppearanceSettingsSection()`.
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: UI tests (defaults + custom-entry round trip)** — add to `VigilSettingsUITests.swift`:
```swift
    func testAlertPresetsReflectTheDefaultLevelsAndSpeak() {
        launchSettings()
        let preset50 = assertReachable("vigil.settings.alerts.preset.50")
        XCTAssertEqual(preset50.label, "50% used")
        XCTAssertEqual(preset50.value as? String, "0")
        XCTAssertEqual(assertReachable("vigil.settings.alerts.preset.80").value as? String, "1")
        XCTAssertEqual(assertReachable("vigil.settings.alerts.preset.90").value as? String, "0")
        XCTAssertEqual(assertReachable("vigil.settings.alerts.preset.95").value as? String, "1")
        assertReachable("vigil.settings.alerts.addCustom")
    }

    func testAddingAndRemovingACustomLevel() {
        launchSettings()
        let field = assertReachable("vigil.settings.alerts.customField")
        tapVisiblePortion(of: field)
        field.typeText("77")
        tapVisiblePortion(of: assertReachable("vigil.settings.alerts.addCustom"))
        let remove = assertReachable("vigil.settings.alerts.remove.77")
        tapVisiblePortion(of: remove)
        XCTAssertFalse(
            element("vigil.settings.alerts.remove.77").waitForExistence(timeout: 2),
            "Removing the custom level must delete its row"
        )
    }
```
Run:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeoproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testAlertPresetsReflectTheDefaultLevelsAndSpeak -only-testing:VigilUITests/VigilSettingsUITests/testAddingAndRemovingACustomLevel CODE_SIGNING_ALLOWED=NO
```
(Note: correct the project name to `Vigil.xcodeproj` — typo guard.) Expected: PASS for both.
- [ ] **Step 6: Docs** — in `docs/user-guide/setup.md`, under the "Adjust Vigil in Settings" section, append after the Appearance bullet:
```markdown
- **Alerts** — choose the usage percentages that notify you (defaults 80 and
  95), add custom whole percents from 1 to 99 (at most 8 active levels), or
  turn every level off. With all levels off, no usage alerts will fire.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 7: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/AlertsSettingsSection.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/AlertLevelPresetsTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/setup.md && git commit -m "Add the Alerts settings section with preset and custom level controls"
```

### Task 27: Per-account alert overrides
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/AccountAlertOverridesView.swift`
- Modify: `apps/apple/Vigil/Settings/AlertsSettingsSection.swift` (add the navigation row above the privacy caption), `docs/user-guide/setup.md`
- Test: `apps/apple/VigilTests/AccountAlertModeTests.swift`, `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes (contract): `var accountAlertOverrides: [String: [Int]]` (missing entry = use global, empty = muted); `var alertLevels: [Int]`. Consumes `AccountRef` (`apps/apple/Vigil/Support/SharedContainer.swift:235`, `key`/`displayName`/`label`) and `AlertLevelEditor` (Task 26).
- Produces:
  - `enum AccountAlertMode: String, CaseIterable { case global, custom, muted; var displayName: String; static func current(override: [Int]?) -> AccountAlertMode; static func override(for mode: AccountAlertMode, previous: [Int]?, globalLevels: [Int]) -> [Int]? }`
  - `struct AccountAlertOverridesView: View`

- [ ] **Step 1: Write the failing unit test** — create `apps/apple/VigilTests/AccountAlertModeTests.swift`:
```swift
import XCTest
@testable import Vigil

/// Spec section 3: a missing entry means "use global"; an empty override
/// means muted; anything else is a custom set.
final class AccountAlertModeTests: XCTestCase {
    func testMissingOverrideMeansGlobal() {
        XCTAssertEqual(AccountAlertMode.current(override: nil), .global)
    }

    func testEmptyOverrideMeansMuted() {
        XCTAssertEqual(AccountAlertMode.current(override: []), .muted)
    }

    func testNonEmptyOverrideMeansCustom() {
        XCTAssertEqual(AccountAlertMode.current(override: [50]), .custom)
    }

    func testSwitchingToGlobalRemovesTheOverride() {
        XCTAssertNil(
            AccountAlertMode.override(for: .global, previous: [50], globalLevels: [80, 95])
        )
    }

    func testSwitchingToMutedStoresAnEmptyOverride() {
        XCTAssertEqual(
            AccountAlertMode.override(for: .muted, previous: [50], globalLevels: [80, 95]),
            []
        )
    }

    func testSwitchingToCustomSeedsFromGlobalLevels() {
        XCTAssertEqual(
            AccountAlertMode.override(for: .custom, previous: nil, globalLevels: [80, 95]),
            [80, 95]
        )
        XCTAssertEqual(
            AccountAlertMode.override(for: .custom, previous: [], globalLevels: [80, 95]),
            [80, 95]
        )
    }

    func testSwitchingToCustomKeepsAnExistingCustomSet() {
        XCTAssertEqual(
            AccountAlertMode.override(for: .custom, previous: [50], globalLevels: [80, 95]),
            [50]
        )
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/AccountAlertModeTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'AccountAlertMode' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/AccountAlertOverridesView.swift`:
```swift
import SwiftUI

enum AccountAlertMode: String, CaseIterable {
    case global
    case custom
    case muted

    var displayName: String {
        switch self {
        case .global: "Global"
        case .custom: "Custom"
        case .muted: "Muted"
        }
    }

    static func current(override: [Int]?) -> AccountAlertMode {
        guard let override else { return .global }
        return override.isEmpty ? .muted : .custom
    }

    /// nil removes the override entry (back to global). Switching to custom
    /// keeps a non-empty existing set, otherwise seeds from the global levels.
    static func override(
        for mode: AccountAlertMode,
        previous: [Int]?,
        globalLevels: [Int]
    ) -> [Int]? {
        switch mode {
        case .global:
            nil
        case .muted:
            []
        case .custom:
            if let previous, !previous.isEmpty { previous } else { globalLevels }
        }
    }
}

struct AccountAlertOverridesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    ForEach(model.accounts) { account in
                        AccountAlertOverrideEditor(account: account)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Per-account alerts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct AccountAlertOverrideEditor: View {
    @Environment(AppModel.self) private var model
    let account: AccountRef

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: account.label ?? account.displayName) {
            VStack(alignment: .leading, spacing: VigilSpacing.small) {
                Picker(
                    "Alert levels for \(account.displayName)",
                    selection: modeBinding(preferences)
                ) {
                    ForEach(AccountAlertMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vigil.settings.alerts.account.\(account.key).mode")
                .padding(14)
                .vigilInsetSurface()

                switch AccountAlertMode.current(
                    override: preferences.accountAlertOverrides[account.key]
                ) {
                case .custom:
                    AlertLevelEditor(
                        levels: Binding(
                            get: { preferences.accountAlertOverrides[account.key] ?? [] },
                            set: { preferences.accountAlertOverrides[account.key] = $0 }
                        ),
                        identifierPrefix: "vigil.settings.alerts.account.\(account.key)"
                    )
                case .muted:
                    Text("No usage alerts will fire for this account.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                case .global:
                    Text("Uses the global alert levels.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modeBinding(_ preferences: VigilPreferences) -> Binding<AccountAlertMode> {
        Binding(
            get: {
                AccountAlertMode.current(
                    override: preferences.accountAlertOverrides[account.key]
                )
            },
            set: { mode in
                preferences.accountAlertOverrides[account.key] = AccountAlertMode.override(
                    for: mode,
                    previous: preferences.accountAlertOverrides[account.key],
                    globalLevels: preferences.alertLevels
                )
            }
        )
    }
}
```
In `AlertsSettingsSection.swift`, insert between the `AlertLevelEditor` and the privacy caption:
```swift
                if !model.accounts.isEmpty {
                    NavigationLink {
                        AccountAlertOverridesView()
                    } label: {
                        SettingsNavigationRow(
                            symbol: "person.2.badge.gearshape",
                            title: "Per-account alerts",
                            detail: "Override or mute alert levels for one account"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vigil.settings.alerts.accounts")
                }
```
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: UI test** — add to `VigilSettingsUITests.swift` (demo accounts are keyed `claude:demo` etc., `apps/apple/Vigil/Support/DemoData.swift:75`):
```swift
    func testPerAccountOverrideEditorReachesGlobalCustomAndMuted() {
        launchSettings()
        tapVisiblePortion(of: assertReachable("vigil.settings.alerts.accounts"))
        XCTAssertTrue(app.navigationBars["Per-account alerts"].waitForExistence(timeout: 5))

        let mode = assertReachable("vigil.settings.alerts.account.claude:demo.mode")
        XCTAssertTrue(mode.buttons["Global"].isSelected, "A missing override must read as Global")

        mode.buttons["Muted"].tap()
        XCTAssertTrue(
            app.staticTexts["No usage alerts will fire for this account."]
                .waitForExistence(timeout: 3)
        )

        mode.buttons["Custom"].tap()
        let preset80 = assertReachable("vigil.settings.alerts.account.claude:demo.preset.80")
        XCTAssertEqual(
            preset80.value as? String, "1",
            "Custom must seed from the global defaults (80 on)"
        )

        mode.buttons["Global"].tap()
        XCTAssertTrue(app.staticTexts["Uses the global alert levels."].waitForExistence(timeout: 3))
    }
```
Run:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testPerAccountOverrideEditorReachesGlobalCustomAndMuted CODE_SIGNING_ALLOWED=NO
```
Expected: PASS.
- [ ] **Step 6: Docs** — in `docs/user-guide/setup.md`, append after the Alerts bullet:
```markdown
- **Alerts → Per-account alerts** — an account can keep the global levels,
  carry its own set, or be muted entirely. Removing an account removes its
  override.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 7: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/AccountAlertOverridesView.swift apps/apple/Vigil/Settings/AlertsSettingsSection.swift apps/apple/VigilTests/AccountAlertModeTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/setup.md && git commit -m "Add per-account alert overrides with global, custom, and muted modes"
```

### Task 28: Refresh section — pause controls and stale-threshold picker
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/RefreshSettingsSection.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (replace the whole `SettingsSection(title: "Refresh") { ... }` block — the block that was lines 94–106 pre-Task-21, containing the `"Provider minimum" / "5 min + jitter"` row — with `RefreshSettingsSection()`), `docs/user-guide/reading-limits.md` (lines 43–44 and 58), `docs/user-guide/setup.md`
- Test: `apps/apple/VigilTests/RefreshSectionTests.swift`, `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes (contract): `var pauseAllPolling: Bool` (default false); `var pausedAccountKeys: Set<String>` (default []); `var staleAfterMinutes: Int` (default 30, allowed {15, 30, 60}). Consumes `AccountRef`, `SettingsToggleRow`, `SettingsValueRow`, `SettingsSection`.
- Produces: `struct RefreshSettingsSection: View { static let staleChoices: [Int] }`.

Note: this task moves the two legacy info rows (`"Provider minimum" / "5 min + jitter"`, `"Background checks" / "Scheduled by iOS"`) into the new section verbatim as a pure move. Task 29 corrects them — move and correction stay separately reviewable.

- [ ] **Step 1: Write the failing unit test** — create `apps/apple/VigilTests/RefreshSectionTests.swift`:
```swift
import XCTest
@testable import Vigil

final class RefreshSectionTests: XCTestCase {
    func testStaleChoicesMatchTheContractAllowedValues() {
        XCTAssertEqual(RefreshSettingsSection.staleChoices, [15, 30, 60])
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/RefreshSectionTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'RefreshSettingsSection' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/RefreshSettingsSection.swift`:
```swift
import SwiftUI

struct RefreshSettingsSection: View {
    @Environment(AppModel.self) private var model

    static let staleChoices = [15, 30, 60]

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Refresh") {
            VStack(alignment: .leading, spacing: VigilSpacing.small) {
                SettingsToggleRow(
                    title: "Pause all automatic checks",
                    detail: "Foreground, background, and widget checks all skip. Pull to refresh still fetches on demand.",
                    identifier: "vigil.settings.refresh.pauseAll",
                    isOn: $preferences.pauseAllPolling
                )

                ForEach(model.accounts) { account in
                    SettingsToggleRow(
                        title: "Pause \(account.label ?? account.displayName)",
                        detail: "Skips this account's automatic checks only.",
                        identifier: "vigil.settings.refresh.pause.\(account.key)",
                        isOn: Binding(
                            get: { preferences.pausedAccountKeys.contains(account.key) },
                            set: { paused in
                                if paused {
                                    preferences.pausedAccountKeys.insert(account.key)
                                } else {
                                    preferences.pausedAccountKeys.remove(account.key)
                                }
                            }
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Mark readings stale after")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Mark readings stale after", selection: $preferences.staleAfterMinutes) {
                        ForEach(Self.staleChoices, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("vigil.settings.refresh.staleAfter")
                }
                .padding(14)
                .vigilInsetSurface()

                Text("Staleness is presentation only. It never changes how often Vigil checks a provider, and paused readings keep aging visibly.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    SettingsValueRow(label: "Provider minimum", value: "5 min + jitter")
                    Divider().overlay(VigilPalette.border.opacity(0.7))
                    SettingsValueRow(label: "Background checks", value: "Scheduled by iOS")
                }
                .vigilInsetSurface()

                Text("Manual refresh, background work, and widgets share the same provider cooldown. Observed history can contain gaps.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
```
In `SettingsView.swift`, delete the entire `SettingsSection(title: "Refresh") { ... }` block (the one containing `SettingsValueRow(label: "Provider minimum", value: "5 min + jitter")`) and put `RefreshSettingsSection()` in its place.
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: UI test** — add to `VigilSettingsUITests.swift`:
```swift
    func testRefreshControlsSpeakWithShippedDefaults() {
        launchSettings()
        let pauseAll = assertReachable("vigil.settings.refresh.pauseAll")
        XCTAssertEqual(pauseAll.label, "Pause all automatic checks")
        XCTAssertEqual(pauseAll.value as? String, "0", "Pause must default off — no behavior change for a user who never opens Settings")

        let pauseClaude = assertReachable("vigil.settings.refresh.pause.claude:demo")
        XCTAssertEqual(pauseClaude.label, "Pause Claude")
        XCTAssertEqual(pauseClaude.value as? String, "0")

        let stale = assertReachable("vigil.settings.refresh.staleAfter")
        XCTAssertTrue(stale.buttons["30 min"].isSelected, "Stale threshold must default to 30 minutes")
        stale.buttons["60 min"].tap()
        XCTAssertTrue(stale.buttons["60 min"].isSelected)
        stale.buttons["30 min"].tap()
    }
```
Run:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testRefreshControlsSpeakWithShippedDefaults CODE_SIGNING_ALLOWED=NO
```
Expected: PASS.
- [ ] **Step 6: Docs** — three edits:
1. `docs/user-guide/reading-limits.md` lines 43–44, replace the Live/Stale table rows:
```markdown
| **Live** | The latest accepted response satisfied the provider contract and is not older than the stale threshold (30 minutes unless you change it in Settings). |
| **Stale** | The last accepted response is older than the stale threshold. |
```
2. `docs/user-guide/reading-limits.md` line 58 — append to the "Refresh timing" paragraph:
```markdown
Pausing checks in Settings — globally or per account — only subtracts work: paused accounts skip automatic checks, pull-to-refresh still fetches on demand, and paused readings keep aging visibly.
```
3. `docs/user-guide/setup.md` — append under "Adjust Vigil in Settings":
```markdown
- **Refresh** — pause all automatic checks or a single account (pull to
  refresh still works), and choose when readings are marked stale: 15, 30,
  or 60 minutes.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 7: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/RefreshSettingsSection.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilTests/RefreshSectionTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/reading-limits.md docs/user-guide/setup.md && git commit -m "Add Refresh settings controls for pause and the stale threshold"
```

### Task 29: Corrected info rows and retention info rows
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/SettingsInfoRows.swift`
- Modify: `apps/apple/Vigil/Settings/RefreshSettingsSection.swift` (replace the legacy two-row block from Task 28), `docs/user-guide/history-and-imports.md` (Retention section, after line 51)
- Test: `apps/apple/VigilTests/SettingsInfoRowsTests.swift`, `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes: `UsageHistoryStore.defaultRetentionDays` (400.0), `.defaultMaximumObservedEntries` (120_000), `.defaultMaximumProviderBackfillEntries` (5_000) — public constants at `packages/VigilKit/Sources/VigilKit/History/UsageHistoryStore.swift:94-96`.
- Produces:
  - `struct SettingsInfoRow: Equatable, Identifiable { let identifier: String; let label: String; let value: String; var id: String { identifier } }`
  - `enum SettingsInfoRows { static let refresh: [SettingsInfoRow]; static let retention: [SettingsInfoRow]; static func grouped(_ value: Int) -> String }`

Number provenance (verified before hardcoding):
- **"60 seconds + jitter"** — `docs/product-contract.md:58` ("a one-minute provider floor plus jitter as a minimum delay, not a sampling promise") and `protocol/providers.json`, where every provider's poll block carries `"minSeconds": 60` (14 occurrences, e.g. lines 29, 269, 410, 534, 573, 639, 1064, 1104, 1391, 1683). The current Settings row saying "5 min + jitter" is stale — the spec names it explicitly.
- **Manual refresh copy** — `docs/product-contract.md:58`: "A manual pull-to-refresh fetches on demand — it skips the floor but never an in-flight fetch or a rate-limit backoff."
- **Rolling 400 days / 120,000 observed / 5,000 imported per account** — `docs/user-guide/history-and-imports.md:46-49`, `docs/development/architecture.md:172`, and the shipped constants at `UsageHistoryStore.swift:94-96`. The rows derive from the kit constants so the copy cannot drift from the shipped limits.

- [ ] **Step 1: Write the failing unit test** — create `apps/apple/VigilTests/SettingsInfoRowsTests.swift`:
```swift
import XCTest
import VigilKit
@testable import Vigil

/// The Settings info rows are honesty surfaces: their numbers must match the
/// shipped contract (60-second poll floor, product-contract.md:58 and
/// providers.json minSeconds) and the shipped retention constants
/// (UsageHistoryStore.swift:94-96, history-and-imports.md:46-49).
final class SettingsInfoRowsTests: XCTestCase {
    func testRefreshInfoRowsStateTheSixtySecondFloor() {
        XCTAssertEqual(SettingsInfoRows.refresh, [
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.info.providerMinimum",
                label: "Provider minimum",
                value: "60 seconds + jitter"
            ),
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.info.manualRefresh",
                label: "Manual refresh",
                value: "On demand, never interrupts an in-flight check"
            ),
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.info.background",
                label: "Background checks",
                value: "Scheduled by iOS"
            ),
        ])
    }

    func testRetentionRowsDeriveFromTheShippedKitLimits() {
        XCTAssertEqual(UsageHistoryStore.defaultRetentionDays, 400.0)
        XCTAssertEqual(UsageHistoryStore.defaultMaximumObservedEntries, 120_000)
        XCTAssertEqual(UsageHistoryStore.defaultMaximumProviderBackfillEntries, 5_000)

        XCTAssertEqual(SettingsInfoRows.retention, [
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.retention.archive",
                label: "History archive",
                value: "Rolling 400 days"
            ),
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.retention.observed",
                label: "Observed readings",
                value: "Up to 120,000 per account"
            ),
            SettingsInfoRow(
                identifier: "vigil.settings.refresh.retention.imported",
                label: "Imported records",
                value: "Up to 5,000 per account"
            ),
        ])
    }

    func testGroupingIsLocaleStable() {
        XCTAssertEqual(SettingsInfoRows.grouped(120_000), "120,000")
        XCTAssertEqual(SettingsInfoRows.grouped(5_000), "5,000")
    }
}
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilTests/SettingsInfoRowsTests CODE_SIGNING_ALLOWED=NO
```
Expected failure: `error: cannot find 'SettingsInfoRows' in scope`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/SettingsInfoRows.swift`:
```swift
import Foundation
import VigilKit

struct SettingsInfoRow: Equatable, Identifiable {
    let identifier: String
    let label: String
    let value: String

    var id: String { identifier }
}

/// Static honesty rows for the Refresh section. Retention values derive from
/// the shipped VigilKit constants so this copy cannot drift from behavior.
enum SettingsInfoRows {
    static let refresh: [SettingsInfoRow] = [
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.info.providerMinimum",
            label: "Provider minimum",
            value: "60 seconds + jitter"
        ),
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.info.manualRefresh",
            label: "Manual refresh",
            value: "On demand, never interrupts an in-flight check"
        ),
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.info.background",
            label: "Background checks",
            value: "Scheduled by iOS"
        ),
    ]

    static let retention: [SettingsInfoRow] = [
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.retention.archive",
            label: "History archive",
            value: "Rolling \(Int(UsageHistoryStore.defaultRetentionDays)) days"
        ),
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.retention.observed",
            label: "Observed readings",
            value: "Up to \(grouped(UsageHistoryStore.defaultMaximumObservedEntries)) per account"
        ),
        SettingsInfoRow(
            identifier: "vigil.settings.refresh.retention.imported",
            label: "Imported records",
            value: "Up to \(grouped(UsageHistoryStore.defaultMaximumProviderBackfillEntries)) per account"
        ),
    ]

    /// Fixed en_US grouping keeps the displayed copy and its tests stable
    /// regardless of simulator locale. Vigil ships English-only copy today.
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
```
In `RefreshSettingsSection.swift`, replace the legacy block (from `VStack(spacing: 0) {` containing `"5 min + jitter"` through the `"Manual refresh, background work..."` caption) with:
```swift
                VStack(spacing: 0) {
                    ForEach(Array(SettingsInfoRows.refresh.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(VigilPalette.border.opacity(0.7)) }
                        SettingsValueRow(label: row.label, value: row.value)
                            .accessibilityIdentifier(row.identifier)
                    }
                }
                .vigilInsetSurface()

                Text("Manual refresh, background work, and widgets share the same provider cooldown. Observed history can contain gaps.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(Array(SettingsInfoRows.retention.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(VigilPalette.border.opacity(0.7)) }
                        SettingsValueRow(label: row.label, value: row.value)
                            .accessibilityIdentifier(row.identifier)
                    }
                }
                .vigilInsetSurface()

                Text("Vigil keeps observed and imported history on this iPhone within these limits. Retention is not adjustable in this release; removing an account or a recovery reset deletes its stored history.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
```
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: UI test** — add to `VigilSettingsUITests.swift` (the rows use `.accessibilityElement(children: .combine)`, so assert on the combined element's spoken label, mirroring `testDegradedHomeCardSpeaksDataAgeNotACheckTime`):
```swift
    func testRefreshInfoRowsSpeakTheCorrectedFloorAndRetention() {
        launchSettings()

        let providerMinimum = assertReachable("vigil.settings.refresh.info.providerMinimum")
        XCTAssertTrue(
            providerMinimum.label.contains("60 seconds + jitter"),
            "Spoken: \(providerMinimum.label)"
        )
        XCTAssertFalse(
            app.staticTexts["5 min + jitter"].exists,
            "The stale five-minute floor copy must be gone everywhere"
        )

        let manualRefresh = assertReachable("vigil.settings.refresh.info.manualRefresh")
        XCTAssertTrue(
            manualRefresh.label.contains("never interrupts an in-flight check"),
            "Spoken: \(manualRefresh.label)"
        )

        XCTAssertTrue(
            assertReachable("vigil.settings.refresh.retention.archive")
                .label.contains("Rolling 400 days")
        )
        XCTAssertTrue(
            assertReachable("vigil.settings.refresh.retention.observed")
                .label.contains("Up to 120,000 per account")
        )
        XCTAssertTrue(
            assertReachable("vigil.settings.refresh.retention.imported")
                .label.contains("Up to 5,000 per account")
        )
    }
```
Run:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testRefreshInfoRowsSpeakTheCorrectedFloorAndRetention CODE_SIGNING_ALLOWED=NO
```
Expected: PASS.
- [ ] **Step 6: Docs** — in `docs/user-guide/history-and-imports.md`, after the paragraph ending "One account cannot consume another account's per-account capacity." (line 51), insert:
```markdown
**Settings → Refresh** shows these same limits, so retained history is visible in the app without reading documentation.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 7: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/SettingsInfoRows.swift apps/apple/Vigil/Settings/RefreshSettingsSection.swift apps/apple/VigilTests/SettingsInfoRowsTests.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/history-and-imports.md && git commit -m "Correct the refresh info rows to the 60-second floor and surface retention limits"
```

### Task 30: Accessibility and Widgets sections
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/AccessibilitySettingsSection.swift`, `apps/apple/Vigil/Settings/WidgetsSettingsSection.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (insert both sections directly below the Security section), `docs/user-guide/setup.md`
- Test: `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes (contract): `var reduceProminentAnimations: Bool` (default false); `var hapticsEnabled: Bool` (default true); `var widgetRedactedWhenLocked: Bool` (default false); `var widgetsFollowThemeOverride: Bool` (default true). Consumes `SettingsToggleRow`, `SettingsSection`.
- Produces: `struct AccessibilitySettingsSection: View`, `struct WidgetsSettingsSection: View`.

These sections are pure preference bindings with no local logic, so the failing test is the UI walk (missing identifiers make it red).

- [ ] **Step 1: Write the failing UI test** — add to `VigilSettingsUITests.swift`:
```swift
    func testAccessibilityAndWidgetTogglesSpeakWithShippedDefaults() {
        launchSettings()

        let reduce = assertReachable("vigil.settings.accessibility.reduceAnimations")
        XCTAssertEqual(reduce.label, "Reduce prominent animations")
        XCTAssertEqual(reduce.value as? String, "0")

        let haptics = assertReachable("vigil.settings.accessibility.haptics")
        XCTAssertEqual(haptics.label, "Confirmation haptics")
        XCTAssertEqual(haptics.value as? String, "1", "Haptics default on per the approved 1.0.0 exceptions")

        let redact = assertReachable("vigil.settings.widgets.redactWhenLocked")
        XCTAssertEqual(redact.label, "Redact widgets while Vigil is locked")
        XCTAssertEqual(redact.value as? String, "0")

        let follow = assertReachable("vigil.settings.widgets.followTheme")
        XCTAssertEqual(follow.label, "Widgets follow theme override")
        XCTAssertEqual(follow.value as? String, "1")
    }
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testAccessibilityAndWidgetTogglesSpeakWithShippedDefaults CODE_SIGNING_ALLOWED=NO
```
Expected failure: `Missing accessibility element vigil.settings.accessibility.reduceAnimations`, `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/AccessibilitySettingsSection.swift`:
```swift
import SwiftUI

struct AccessibilitySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Accessibility") {
            VStack(spacing: 10) {
                SettingsToggleRow(
                    title: "Reduce prominent animations",
                    detail: "Calms dial and refresh animations. The system Reduce Motion setting is always respected.",
                    identifier: "vigil.settings.accessibility.reduceAnimations",
                    isOn: $preferences.reduceProminentAnimations
                )
                SettingsToggleRow(
                    title: "Confirmation haptics",
                    detail: "Plays a light tap when Vigil confirms an action.",
                    identifier: "vigil.settings.accessibility.haptics",
                    isOn: $preferences.hapticsEnabled
                )
            }
        }
    }
}
```
Create `apps/apple/Vigil/Settings/WidgetsSettingsSection.swift`:
```swift
import SwiftUI

struct WidgetsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Widgets") {
            VStack(spacing: 10) {
                SettingsToggleRow(
                    title: "Redact widgets while Vigil is locked",
                    detail: "With app lock on, widgets show provider and status without percentages.",
                    identifier: "vigil.settings.widgets.redactWhenLocked",
                    isOn: $preferences.widgetRedactedWhenLocked
                )
                SettingsToggleRow(
                    title: "Widgets follow theme override",
                    detail: "Off means widgets always follow the system appearance.",
                    identifier: "vigil.settings.widgets.followTheme",
                    isOn: $preferences.widgetsFollowThemeOverride
                )
            }
        }
    }
}
```
In `SettingsView.swift`, insert `AccessibilitySettingsSection()` then `WidgetsSettingsSection()` directly below the `SettingsSection(title: "Security")` block.
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Docs** — two edits in `docs/user-guide/setup.md`:
1. Append under "Adjust Vigil in Settings":
```markdown
- **Accessibility** — reduce prominent animations (the system Reduce Motion
  setting is always respected) and turn confirmation haptics off or on.
- **Widgets** — redact widget percentages while Vigil is locked, and choose
  whether widgets follow the in-app theme override or always match the
  system appearance.
```
2. In the "## Add a widget" section, after the paragraph ending "so a countdown can move while the provider reading becomes stale." (line 84), append:
```markdown
With app lock on, **Redact widgets while Vigil is locked** (Settings → Widgets) shows provider name and status without percentages.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 6: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/AccessibilitySettingsSection.swift apps/apple/Vigil/Settings/WidgetsSettingsSection.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/setup.md && git commit -m "Add the Accessibility and Widgets settings sections"
```

### Task 31: Final page assembly in the approved section order
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Create: `apps/apple/Vigil/Settings/SecuritySettingsSection.swift`, `apps/apple/Vigil/Settings/PrivacySettingsSection.swift`, `apps/apple/Vigil/Settings/AboutSettingsSection.swift`
- Modify: `apps/apple/Vigil/Settings/SettingsView.swift` (body becomes the ordered section list; Security/Privacy/About blocks move out; `appVersion` moves to `AboutSettingsSection`; DEBUG Diagnostics moves after About; all dialogs, alerts, `fileExporter`, and helper funcs stay), `docs/user-guide/setup.md`
- Test: `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes: everything produced in Tasks 21–28; `model.hasAccountRepairBackups`, `model.requiresFullLocalDataRecovery`, `model.isResettingAllLocalData` (existing `AppModel` members used by the current Privacy section at `SettingsView.swift:59-90` pre-refactor).
- Produces:
  - `struct SecuritySettingsSection: View`
  - `struct PrivacySettingsSection: View { let exportDiagnostics: () -> Void; let requestRepairBackupDeletion: () -> Void; let requestFullRecoveryReset: () -> Void }`
  - `struct AboutSettingsSection: View`
  - New identifiers: `vigil.settings.privacyDetails`, `vigil.settings.about.version`, `vigil.settings.about.storage`.

Approved order (spec section 7): Appearance, Alerts, Refresh, Security, Accessibility, Widgets, Privacy, About. Before this task the page still runs Appearance, Alerts, Security, Accessibility, Widgets, Privacy, Refresh, About — Refresh must move up and Privacy down.

- [ ] **Step 1: Write the failing UI test** — a downward-only sweep: each identifier must be reachable using only downward scrolling in the approved order, which fails whenever a later-listed control sits above an earlier one. Add to `VigilSettingsUITests.swift`:
```swift
    func testApprovedSectionOrderTopToBottom() {
        launchSettings()
        let orderedIdentifiers = [
            "vigil.settings.appearance",
            "vigil.settings.alerts.preset.50",
            "vigil.settings.alerts.accounts",
            "vigil.settings.refresh.pauseAll",
            "vigil.settings.refresh.staleAfter",
            "vigil.settings.refresh.info.providerMinimum",
            "vigil.settings.refresh.retention.archive",
            "vigil.settings.appLock",
            "vigil.settings.accessibility.reduceAnimations",
            "vigil.settings.accessibility.haptics",
            "vigil.settings.widgets.redactWhenLocked",
            "vigil.settings.widgets.followTheme",
            "vigil.settings.privacyDetails",
            "vigil.settings.exportDiagnostics",
            "vigil.settings.about.version",
        ]
        for identifier in orderedIdentifiers {
            assertVisibleScrollingDownOnly(identifier)
        }
    }

    private func assertVisibleScrollingDownOnly(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(identifier)
        let scrollView = app.scrollViews.firstMatch
        if target.waitForExistence(timeout: 2), hasSafeVisibleArea(target) { return }
        for _ in 0..<14 where scrollView.exists {
            scrollView.swipeUp()
            if target.waitForExistence(timeout: 1), hasSafeVisibleArea(target) { return }
        }
        XCTFail(
            "\(identifier) was not reachable scrolling down in the approved section order",
            file: file,
            line: line
        )
    }
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testApprovedSectionOrderTopToBottom CODE_SIGNING_ALLOWED=NO
```
Expected failure: `vigil.settings.appLock was not reachable scrolling down in the approved section order` (Security currently sits above Refresh, so after scrolling down to the Refresh rows the lock toggle is already above the viewport). `vigil.settings.privacyDetails` and `vigil.settings.about.version` also do not exist yet. `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — create `apps/apple/Vigil/Settings/SecuritySettingsSection.swift`:
```swift
import SwiftUI

struct SecuritySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection(title: "Security") {
            SettingsToggleRow(
                title: "Require Face ID or Touch ID",
                detail: "Lock Vigil whenever it returns to the foreground.",
                identifier: "vigil.settings.appLock",
                isOn: Binding(
                    get: { model.lockEnabled },
                    set: { model.lockEnabled = $0 }
                )
            )
        }
    }
}
```
Create `apps/apple/Vigil/Settings/PrivacySettingsSection.swift` — the rows move verbatim from `SettingsView`; the destructive flows stay in `SettingsView` and arrive as closures so its confirmation dialogs and alerts do not move:
```swift
import SwiftUI

struct PrivacySettingsSection: View {
    @Environment(AppModel.self) private var model
    let exportDiagnostics: () -> Void
    let requestRepairBackupDeletion: () -> Void
    let requestFullRecoveryReset: () -> Void

    var body: some View {
        SettingsSection(title: "Privacy") {
            VStack(spacing: 10) {
                NavigationLink {
                    PrivacyView()
                } label: {
                    SettingsNavigationRow(
                        symbol: "lock.shield",
                        title: "How Vigil handles your data",
                        detail: "Credentials, snapshots, and direct provider requests"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vigil.settings.privacyDetails")

                Button(action: exportDiagnostics) {
                    SettingsNavigationRow(
                        symbol: "square.and.arrow.up",
                        title: "Export diagnostic report",
                        detail: "Bounded recent support data without credentials or raw responses",
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vigil.settings.exportDiagnostics")

                if model.hasAccountRepairBackups {
                    Button(role: .destructive, action: requestRepairBackupDeletion) {
                        SettingsNavigationRow(
                            symbol: "trash",
                            title: "Delete account repair backup",
                            detail: "Remove the damaged account list preserved during recovery",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("vigil.settings.deleteRepairBackup")
                }

                if model.requiresFullLocalDataRecovery {
                    Button(role: .destructive, action: requestFullRecoveryReset) {
                        SettingsNavigationRow(
                            symbol: "exclamationmark.arrow.triangle.2.circlepath",
                            title: model.isResettingAllLocalData
                                ? "Erasing local Vigil data..."
                                : "Erase Vigil data and start over",
                            detail: "Deletes every linked credential, snapshot, history record, and Vigil notification from this iPhone",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isResettingAllLocalData)
                    .accessibilityIdentifier("vigil.settings.fullRecoveryReset")
                }
            }
        }
    }
}
```
Create `apps/apple/Vigil/Settings/AboutSettingsSection.swift` (the `appVersion` computed property moves here from `SettingsView.swift`):
```swift
import SwiftUI

struct AboutSettingsSection: View {
    var body: some View {
        SettingsSection(title: "About") {
            VStack(spacing: 0) {
                SettingsValueRow(label: "Version", value: appVersion)
                    .accessibilityIdentifier("vigil.settings.about.version")
                Divider().overlay(VigilPalette.border.opacity(0.7))
                SettingsValueRow(label: "Storage", value: "This device only")
                    .accessibilityIdentifier("vigil.settings.about.storage")
            }
            .vigilInsetSurface()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
```
In `SettingsView.swift`: delete the inline Security, Privacy, and About `SettingsSection` blocks and the `appVersion` property; the sections `VStack` becomes exactly:
```swift
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    AppearanceSettingsSection()
                    AlertsSettingsSection()
                    RefreshSettingsSection()
                    SecuritySettingsSection()
                    AccessibilitySettingsSection()
                    WidgetsSettingsSection()
                    PrivacySettingsSection(
                        exportDiagnostics: prepareDiagnosticExport,
                        requestRepairBackupDeletion: { showRepairBackupDeletion = true },
                        requestFullRecoveryReset: { showFullRecoveryReset = true }
                    )
                    AboutSettingsSection()

                    #if DEBUG
                    SettingsSection(title: "Diagnostics") {
                        Button { Task { await simulateThresholdCrossing() } } label: {
                            SettingsNavigationRow(
                                symbol: "bell.badge",
                                title: "Simulate the 80% alert",
                                detail: "Exercises the local notification path",
                                showsChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.accounts.isEmpty)
                    }
                    #endif
                }
```
Everything else in `SettingsView.swift` (`fileExporter`, all alerts and confirmation dialogs, `prepareDiagnosticExport`, `performFullRecoveryReset`, `diagnosticFilename`, `simulateThresholdCrossing`) stays where it is.
- [ ] **Step 4: Run test to verify it passes** — same command as Step 2, expected `** TEST SUCCEEDED **`. Then run the full UI regression for Settings-adjacent suites:
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests -only-testing:VigilUITests/VigilAccessibilityUITests CODE_SIGNING_ALLOWED=NO
```
Expected: all PASS (the existing `testDiagnosticExportIsReachable*` tests prove the moved Privacy rows kept their identifiers).
- [ ] **Step 5: Docs** — in `docs/user-guide/setup.md`, replace the intro line of "Adjust Vigil in Settings" ("Open **Settings** (the gear) from the Limits toolbar.") with:
```markdown
Open **Settings** (the gear) from the Limits toolbar. Sections appear in
order: Appearance, Alerts, Refresh, Security, Accessibility, Widgets,
Privacy, About.
```
and append the three remaining bullets after the Widgets bullet:
```markdown
- **Security** — require Face ID or Touch ID whenever Vigil returns to the
  foreground.
- **Privacy** — data-handling details, the credential-free diagnostic
  export, and recovery actions when Vigil detects damaged local data.
- **About** — version and the storage reminder: this device only.
```
Verify: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — exits 0.
- [ ] **Step 6: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/SecuritySettingsSection.swift apps/apple/Vigil/Settings/PrivacySettingsSection.swift apps/apple/Vigil/Settings/AboutSettingsSection.swift apps/apple/Vigil/Settings/SettingsView.swift apps/apple/VigilUITests/VigilSettingsUITests.swift docs/user-guide/setup.md && git commit -m "Assemble the Settings page in the approved section order"
```

### Task 32: Full-page walks at default and accessibility-XXXL with pinned spoken surfaces
**PR:** PR-4 — Settings assembly + corrected info/retention rows
**Files:**
- Modify: `apps/apple/Vigil/Settings/AppearanceSettingsSection.swift`, `apps/apple/Vigil/Settings/RefreshSettingsSection.swift`, `apps/apple/Vigil/Settings/AccountAlertOverridesView.swift` (picker container spoken labels)
- Test: `apps/apple/VigilUITests/VigilSettingsUITests.swift`

**Interfaces:**
- Consumes: every identifier produced in Tasks 22–29; the `ContentSizeScenario` pattern from `apps/apple/VigilUITests/VigilAccessibilityUITests.swift:5-25` (mirrored as two content-size walk entry points, matching how that file's `testCriticalActionsAtDefaultContentSize`/`testCriticalActionsAtAccessibilityXXXL` split one `assert` helper).
- Produces: `.accessibilityLabel(...)` pins on the three segmented pickers (their containers otherwise speak nothing); two walk tests with `keepAlways` screenshot attachments (`settings-default`, `settings-accessibility-xxxl`) matching `attachScreenshot` usage at `VigilAccessibilityUITests.swift:317-322`.

- [ ] **Step 1: Write the failing test** — add to `VigilSettingsUITests.swift`:
```swift
    func testSettingsFullWalkAtDefaultSize() {
        assertSettingsFullWalk(named: "settings-default", contentSizeCategory: nil)
    }

    func testSettingsFullWalkAtAccessibilityXXXL() {
        assertSettingsFullWalk(
            named: "settings-accessibility-xxxl",
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
    }

    /// One walk per content size, mirroring VigilAccessibilityUITests'
    /// ContentSizeScenario split. Every new control must be reachable and
    /// speak its pinned surface at both sizes.
    private func assertSettingsFullWalk(
        named name: String,
        contentSizeCategory: UIContentSizeCategory?
    ) {
        launchSettings(contentSizeCategory: contentSizeCategory)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        attachScreenshot(named: "\(name)-top")

        let pinnedSpokenSurfaces: [(identifier: String, spoken: String)] = [
            ("vigil.settings.appearance", "Appearance"),
            ("vigil.settings.alerts.preset.50", "50% used"),
            ("vigil.settings.alerts.preset.80", "80% used"),
            ("vigil.settings.alerts.preset.90", "90% used"),
            ("vigil.settings.alerts.preset.95", "95% used"),
            ("vigil.settings.alerts.customField", "Custom alert percent"),
            ("vigil.settings.alerts.addCustom", "Add custom alert level"),
            ("vigil.settings.refresh.pauseAll", "Pause all automatic checks"),
            ("vigil.settings.refresh.pause.claude:demo", "Pause Claude"),
            ("vigil.settings.refresh.staleAfter", "Mark readings stale after"),
            ("vigil.settings.refresh.info.providerMinimum", "60 seconds + jitter"),
            ("vigil.settings.refresh.info.manualRefresh", "never interrupts an in-flight check"),
            ("vigil.settings.refresh.info.background", "Scheduled by iOS"),
            ("vigil.settings.refresh.retention.archive", "Rolling 400 days"),
            ("vigil.settings.refresh.retention.observed", "Up to 120,000 per account"),
            ("vigil.settings.refresh.retention.imported", "Up to 5,000 per account"),
            ("vigil.settings.appLock", "Require Face ID or Touch ID"),
            ("vigil.settings.accessibility.reduceAnimations", "Reduce prominent animations"),
            ("vigil.settings.accessibility.haptics", "Confirmation haptics"),
            ("vigil.settings.widgets.redactWhenLocked", "Redact widgets while Vigil is locked"),
            ("vigil.settings.widgets.followTheme", "Widgets follow theme override"),
            ("vigil.settings.privacyDetails", "How Vigil handles your data"),
            ("vigil.settings.exportDiagnostics", "Export diagnostic report"),
            ("vigil.settings.about.version", "Version"),
        ]

        for surface in pinnedSpokenSurfaces {
            let control = assertReachable(surface.identifier)
            XCTAssertTrue(
                control.label.contains(surface.spoken),
                "\(surface.identifier) must speak \"\(surface.spoken)\" at \(name). Spoken: \(control.label)"
            )
        }
        attachScreenshot(named: "\(name)-bottom")
    }
```
- [ ] **Step 2: Run test to verify it fails**
```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests/testSettingsFullWalkAtDefaultSize CODE_SIGNING_ALLOWED=NO
```
Expected failure: `vigil.settings.appearance must speak "Appearance" at settings-default. Spoken: ` — a SwiftUI segmented picker container has an empty accessibility label unless one is pinned. `** TEST FAILED **`.
- [ ] **Step 3: Minimal implementation** — pin the three picker container labels:
1. `AppearanceSettingsSection.swift` — after `.accessibilityIdentifier("vigil.settings.appearance")`, add:
```swift
                .accessibilityLabel("Appearance")
```
2. `RefreshSettingsSection.swift` — after `.accessibilityIdentifier("vigil.settings.refresh.staleAfter")`, add:
```swift
                    .accessibilityLabel("Mark readings stale after")
```
3. `AccountAlertOverridesView.swift` — after `.accessibilityIdentifier("vigil.settings.alerts.account.\(account.key).mode")`, add:
```swift
                .accessibilityLabel("Alert levels for \(account.displayName)")
```
- [ ] **Step 4: Run tests to verify both walks pass**
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test -only-testing:VigilUITests/VigilSettingsUITests CODE_SIGNING_ALLOWED=NO
```
Expected: the whole `VigilSettingsUITests` suite passes, including `testSettingsFullWalkAtDefaultSize` and `testSettingsFullWalkAtAccessibilityXXXL`, with four `keepAlways` screenshots attached to the result bundle. Then run the complete scheme once as the PR gate (mirrors CI):
```sh
cd /Users/biscuit/Vigil/apps/apple && DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination "platform=iOS Simulator,id=$DEVICE_UDID" test CODE_SIGNING_ALLOWED=NO && cd /Users/biscuit/Vigil && scripts/check-docs.sh && swift test --package-path packages/VigilKit
```
Expected: all green.
- [ ] **Step 5: Commit**
```sh
cd /Users/biscuit/Vigil && git add apps/apple/Vigil/Settings/AppearanceSettingsSection.swift apps/apple/Vigil/Settings/RefreshSettingsSection.swift apps/apple/Vigil/Settings/AccountAlertOverridesView.swift apps/apple/VigilUITests/VigilSettingsUITests.swift && git commit -m "Pin picker spoken surfaces and add full Settings walks at default and accessibility-XXXL"
```


## PR-5

### Task 33: Liquid Glass decision policy — glass vs opaque, unit-testable

**PR:** PR-5 — Liquid Glass adoption (iOS 26+)
**Files:**
- Create: `apps/apple/Vigil/DesignSystem/GlassSurface.swift` (picked up by the `path: Vigil` sources glob at `apps/apple/project.yml:39` after `xcodegen generate`)
- Create: `apps/apple/VigilTests/GlassSurfaceTests.swift`
**Interfaces:**
- Consumes: nothing outside the Swift standard library and SwiftUI.
- Produces: `enum VigilGlassPolicy { static var osSupportsGlass: Bool; static func usesGlass(osSupportsGlass: Bool, reduceTransparency: Bool) -> Bool }`

Context for the engineer: Vigil's deployment target stays iOS 17 (`apps/apple/project.yml:14`), so every Liquid Glass API use is double-gated: `#if compiler(>=6.2)` at compile time (Xcode 26 ships Swift 6.2+; CI's `macos-15` runner may carry Xcode 16, whose iOS 18 SDK has no `glassEffect` symbol, and would fail to build otherwise) and `if #available(iOS 26, *)` at runtime. The decision itself (glass vs opaque) is a pure function so it is testable on any simulator — this is the single decision point every adoption site in Tasks 26–27 consults. Read `/Users/biscuit/.claude/skills/swiftui-expert-skill/references/liquid-glass.md` before starting this task group.

- [ ] **Step 1: Write the failing test**

```swift
// apps/apple/VigilTests/GlassSurfaceTests.swift
import SwiftUI
import XCTest
@testable import Vigil

/// Liquid Glass adoption policy (PR-5). The glass-vs-opaque decision is a
/// pure function so CI simulators — which may predate iOS 26 — can pin every
/// combination. Glass RENDERING cannot be asserted here; it is verified on an
/// iOS 26 runtime during the release walk (docs/development/release.md §11).
final class GlassSurfaceTests: XCTestCase {
    // MARK: - Decision policy

    func testGlassRequiresOSSupportAndNoReduceTransparency() {
        XCTAssertTrue(
            VigilGlassPolicy.usesGlass(osSupportsGlass: true, reduceTransparency: false)
        )
        XCTAssertFalse(
            VigilGlassPolicy.usesGlass(osSupportsGlass: true, reduceTransparency: true),
            "Reduce Transparency always wins: the user asked for opaque surfaces."
        )
        XCTAssertFalse(
            VigilGlassPolicy.usesGlass(osSupportsGlass: false, reduceTransparency: false),
            "Pre-iOS 26 devices keep today's opaque surfaces."
        )
        XCTAssertFalse(
            VigilGlassPolicy.usesGlass(osSupportsGlass: false, reduceTransparency: true)
        )
    }

    func testOSSupportMatchesRuntimeAvailability() {
        #if compiler(>=6.2)
        let expected: Bool
        if #available(iOS 26, *) { expected = true } else { expected = false }
        XCTAssertEqual(
            VigilGlassPolicy.osSupportsGlass, expected,
            "On an iOS 26 SDK toolchain, OS support must track runtime availability exactly."
        )
        #else
        XCTAssertFalse(
            VigilGlassPolicy.osSupportsGlass,
            "A toolchain whose SDK predates iOS 26 must never claim glass support."
        )
        #endif
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple && xcodegen generate && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests
```

Expected failure: BUILD FAILED with `error: cannot find 'VigilGlassPolicy' in scope`. A compile-time red is this task's failing state.

- [ ] **Step 3: Minimal implementation**

```swift
// apps/apple/Vigil/DesignSystem/GlassSurface.swift
import SwiftUI

/// The one decision point for Liquid Glass adoption (PR-5). Every adoption
/// site — cards, insets, toolbars, the linking overlay — consults this policy
/// instead of duplicating availability or accessibility checks.
///
/// Double gate, and why both halves exist:
/// - `#if compiler(>=6.2)`: Liquid Glass APIs exist only in the iOS 26 SDK
///   (Xcode 26, Swift 6.2+). An older toolchain (CI's Xcode 16) compiles the
///   opaque path only, so the repo builds green on both.
/// - `if #available(iOS 26, *)`: an app built with the iOS 26 SDK still runs
///   on iOS 17 devices; they take the opaque path at runtime.
enum VigilGlassPolicy {
    /// Whether the running OS can render Liquid Glass at all.
    static var osSupportsGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    /// Glass is used only when the OS supports it and the user has not
    /// enabled Reduce Transparency. Every other combination keeps the
    /// pre-glass opaque surfaces.
    static func usesGlass(osSupportsGlass: Bool, reduceTransparency: Bool) -> Bool {
        osSupportsGlass && !reduceTransparency
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `Test Suite 'GlassSurfaceTests' passed` (2 tests). Note: on this machine (Xcode 26.6, iOS 26 simulators) `testOSSupportMatchesRuntimeAvailability` exercises the true branch; on an iOS 17.x simulator it exercises the false branch. Both are green by design.

- [ ] **Step 5: Commit**

```sh
cd /Users/biscuit/Vigil && \
git add apps/apple/Vigil/DesignSystem/GlassSurface.swift apps/apple/VigilTests/GlassSurfaceTests.swift && \
git commit -m "Add the unit-testable Liquid Glass decision policy" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 34: vigilGlassSurface modifier; route cards, insets, and the linking overlay through it

**PR:** PR-5 — Liquid Glass adoption (iOS 26+)
**Files:**
- Modify: `apps/apple/Vigil/DesignSystem/GlassSurface.swift` (append below `VigilGlassPolicy`)
- Modify: `apps/apple/Vigil/DesignSystem/VigilTheme.swift` — replace the bodies of `VigilCardModifier` (struct beginning at line 75 on current main) and the `extension View` carrying `vigilCard`/`vigilInsetSurface` (lines 93–108 on current main). PR-1 rewrites this file's palette; anchor on the symbol names, not the line numbers.
- Modify: `apps/apple/Vigil/Onboarding/AddAccountView.swift` — comment above `private var linkingOverlay` (line 202 on current main)
- Test: `apps/apple/VigilTests/GlassSurfaceTests.swift`
**Interfaces:**
- Consumes: `VigilGlassPolicy` (Task 33); `VigilPalette.surface`, `.surfaceInset`, `.border` and `VigilRadius.large`/`.medium` exactly as they exist after PR-1 (names unchanged per the PR-1 contract).
- Produces:
  - `enum VigilGlassSurfaceStyle: Equatable { case card; case inset(cornerRadius: CGFloat); var cornerRadius: CGFloat; var fallbackFill: Color; var fallbackFillOpacity: Double; var fallbackBorderOpacity: Double; var fallbackHasShadow: Bool }`
  - `extension View { func vigilGlassSurface(_ style: VigilGlassSurfaceStyle) -> some View }`
- Behavior contract: on iOS 26+ without Reduce Transparency the surface is `.glassEffect(.regular, in:)`; everywhere else it reproduces today's opaque card/inset backgrounds. All existing `vigilCard`/`vigilInsetSurface` call sites (21 inset sites and 16 card sites, including the linking overlay card at `AddAccountView.swift:221`) adopt with zero call-site churn.

- [ ] **Step 1: Write the failing test** — append inside `GlassSurfaceTests`:

```swift
    // MARK: - Fallback descriptors (the opaque halves must reproduce today's design)

    func testCardFallbackReproducesTodaysOpaqueCardSurface() {
        let style = VigilGlassSurfaceStyle.card
        XCTAssertEqual(style.cornerRadius, VigilRadius.large)
        XCTAssertEqual(style.fallbackFill, VigilPalette.surface)
        XCTAssertEqual(style.fallbackFillOpacity, 0.96, accuracy: 0.000001)
        XCTAssertEqual(style.fallbackBorderOpacity, 0.72, accuracy: 0.000001)
        XCTAssertTrue(style.fallbackHasShadow)
    }

    func testInsetFallbackReproducesTodaysOpaqueInsetSurface() {
        let style = VigilGlassSurfaceStyle.inset(cornerRadius: VigilRadius.medium)
        XCTAssertEqual(style.cornerRadius, VigilRadius.medium)
        XCTAssertEqual(style.fallbackFill, VigilPalette.surfaceInset)
        XCTAssertEqual(style.fallbackFillOpacity, 1.0, accuracy: 0.000001)
        XCTAssertEqual(style.fallbackBorderOpacity, 0.46, accuracy: 0.000001)
        XCTAssertFalse(style.fallbackHasShadow)
    }

    func testGlassSurfaceModifierCompilesOnEveryToolchain() {
        // Compile probe: the modifier must exist and accept both styles under
        // any toolchain. Rendering is covered by the full suite (fallback) and
        // the iOS 26 release walk (glass).
        _ = Text("probe").vigilGlassSurface(.card)
        _ = Text("probe").vigilGlassSurface(.inset(cornerRadius: VigilRadius.small))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests
```

Expected failure: BUILD FAILED with `error: cannot find 'VigilGlassSurfaceStyle' in scope` (and `value of type 'Text' has no member 'vigilGlassSurface'`).

- [ ] **Step 3: Minimal implementation — the abstraction.** Append to `apps/apple/Vigil/DesignSystem/GlassSurface.swift`:

```swift
/// The two surface families that adopt Liquid Glass. Each carries the exact
/// parameters of its pre-glass opaque background so the fallback is the
/// current shipped design, pinned by GlassSurfaceTests.
enum VigilGlassSurfaceStyle: Equatable {
    case card
    case inset(cornerRadius: CGFloat)

    var cornerRadius: CGFloat {
        switch self {
        case .card: return VigilRadius.large
        case .inset(let cornerRadius): return cornerRadius
        }
    }

    var fallbackFill: Color {
        switch self {
        case .card: return VigilPalette.surface
        case .inset: return VigilPalette.surfaceInset
        }
    }

    var fallbackFillOpacity: Double {
        switch self {
        case .card: return 0.96
        case .inset: return 1.0
        }
    }

    var fallbackBorderOpacity: Double {
        switch self {
        case .card: return 0.72
        case .inset: return 0.46
        }
    }

    var fallbackHasShadow: Bool {
        switch self {
        case .card: return true
        case .inset: return false
        }
    }
}

private struct VigilGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let style: VigilGlassSurfaceStyle

    func body(content: Content) -> some View {
        if VigilGlassPolicy.usesGlass(
            osSupportsGlass: VigilGlassPolicy.osSupportsGlass,
            reduceTransparency: reduceTransparency
        ) {
            glass(content)
        } else {
            opaque(content)
        }
    }

    /// Glass carries its own material, edge treatment, and shadowing, so the
    /// opaque fill, hairline stroke, and drop shadow are deliberately absent
    /// here (liquid-glass reference: do not add custom darkening to glass).
    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            )
        } else {
            opaque(content)
        }
        #else
        opaque(content)
        #endif
    }

    @ViewBuilder
    private func opaque(_ content: Content) -> some View {
        let surfaced = content
            .background(
                style.fallbackFill.opacity(style.fallbackFillOpacity),
                in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .stroke(
                        VigilPalette.border.opacity(style.fallbackBorderOpacity),
                        lineWidth: 1
                    )
            }
        if style.fallbackHasShadow {
            surfaced.shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        } else {
            surfaced
        }
    }
}

extension View {
    /// Vigil's Liquid Glass surface. iOS 26+ without Reduce Transparency
    /// renders glass; everywhere else this reproduces the pre-glass opaque
    /// card/inset design exactly.
    func vigilGlassSurface(_ style: VigilGlassSurfaceStyle) -> some View {
        modifier(VigilGlassSurfaceModifier(style: style))
    }
}
```

- [ ] **Step 4: Re-route the existing surfaces.** In `apps/apple/Vigil/DesignSystem/VigilTheme.swift`, replace the `VigilCardModifier` body and the `vigilCard`/`vigilInsetSurface` extension (currently lines 75–108; anchor on the symbols after PR-1) with:

```swift
private struct VigilCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .vigilGlassSurface(.card)
    }
}

extension View {
    func vigilCard(padding: CGFloat = VigilSpacing.medium) -> some View {
        modifier(VigilCardModifier(padding: padding))
    }

    func vigilInsetSurface(cornerRadius: CGFloat = VigilRadius.medium) -> some View {
        vigilGlassSurface(.inset(cornerRadius: cornerRadius))
    }
}
```

This is the whole adoption for cards and insets: every existing call site — including the linking overlay's card at `AddAccountView.swift:221` (`.vigilCard(padding: VigilSpacing.large)`) — now routes through the one abstraction. In `apps/apple/Vigil/Onboarding/AddAccountView.swift`, extend the comment above `private var linkingOverlay` (line 202) by appending one line to make the adoption explicit:

```swift
    /// The card routes through vigilGlassSurface: Liquid Glass on iOS 26+,
    /// today's opaque card under Reduce Transparency or older iOS. The black
    /// scrim is a dim layer, not a surface, and stays as-is.
    private var linkingOverlay: some View {
```

- [ ] **Step 5: Run test to verify it passes, then the full unit suite for fallback regressions**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests
```

Expected: `GlassSurfaceTests` passes (5 tests) and every other `VigilTests` class stays green. Honest scope note: this proves the opaque fallback and the compile gates. Glass rendering itself (material appearance on cards, the overlay, seam behavior between adjacent glass cards) is an iOS 26-runtime manual check recorded in Task 37's docs step — no simulator assertion in this suite claims otherwise.

- [ ] **Step 6: Commit**

```sh
cd /Users/biscuit/Vigil && \
git add apps/apple/Vigil/DesignSystem/GlassSurface.swift \
        apps/apple/Vigil/DesignSystem/VigilTheme.swift \
        apps/apple/Vigil/Onboarding/AddAccountView.swift \
        apps/apple/VigilTests/GlassSurfaceTests.swift && \
git commit -m "Route card, inset, and linking-overlay surfaces through vigilGlassSurface" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 35: Toolbar glass surfaces and the Home card glass container

**PR:** PR-5 — Liquid Glass adoption (iOS 26+)
**Files:**
- Modify: `apps/apple/Vigil/DesignSystem/GlassSurface.swift` (append)
- Modify (replace each `.toolbarBackground(VigilPalette.canvas.opacity(...), for: .navigationBar)` + `.toolbarBackground(.visible, for: .navigationBar)` pair, all verified on current main):
  - `apps/apple/Vigil/Dashboard/DashboardView.swift:41-42` (0.97)
  - `apps/apple/Vigil/Dashboard/AccountDetailView.swift:72-73` (0.97)
  - `apps/apple/Vigil/Connections/ConnectionsView.swift:47-48` (0.97)
  - `apps/apple/Vigil/Settings/SettingsView.swift:142-143` (0.97)
  - `apps/apple/Vigil/Settings/PrivacyView.swift:52-53` (0.96)
  - `apps/apple/Vigil/Onboarding/ManualEntryView.swift:71-72` (0.96, inside `#if os(iOS)`)
  - `apps/apple/Vigil/Onboarding/AddAccountView.swift:82-83` (0.97)
- Modify: `apps/apple/Vigil/Dashboard/DashboardView.swift:151` — wrap the Home `LazyVStack(spacing: 12)` of account cards
- Test: `apps/apple/VigilTests/GlassSurfaceTests.swift`
**Interfaces:**
- Consumes: `VigilGlassPolicy` (Task 33).
- Produces:
  - `enum VigilToolbarSurface { static let standard: Double /* 0.97 */; static let form: Double /* 0.96 */ }`
  - `extension View { func vigilToolbarSurface(opacity: Double = VigilToolbarSurface.standard) -> some View }`
  - `struct VigilGlassContainer<Content: View>: View { init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) }`
- Behavior contract: on the glass path the navigation bar keeps the system's Liquid Glass and scroll edge effect (no forced background — the reference's Design System Notes warn that custom bar darkening defeats both); the fallback path reapplies today's exact opaque canvas scrim. `VigilGlassContainer` gives adjacent Home cards one glass sampling region (glass cannot sample other glass) and is a pass-through when glass is off.

- [ ] **Step 1: Write the failing test** — append inside `GlassSurfaceTests`:

```swift
    // MARK: - Toolbar surfaces and glass grouping

    func testToolbarSurfacePinsTheOpaqueFallbackOpacities() {
        XCTAssertEqual(
            VigilToolbarSurface.standard, 0.97, accuracy: 0.000001,
            "Dashboard, detail, connections, settings, and add-account bars use 0.97."
        )
        XCTAssertEqual(
            VigilToolbarSurface.form, 0.96, accuracy: 0.000001,
            "Privacy and manual-entry bars use 0.96."
        )
    }

    func testToolbarSurfaceAndGlassContainerCompileOnEveryToolchain() {
        _ = Text("probe").vigilToolbarSurface()
        _ = Text("probe").vigilToolbarSurface(opacity: VigilToolbarSurface.form)
        _ = VigilGlassContainer(spacing: 12) { Text("probe") }
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests
```

Expected failure: BUILD FAILED with `error: cannot find 'VigilToolbarSurface' in scope` (and `cannot find 'VigilGlassContainer' in scope`).

- [ ] **Step 3: Minimal implementation.** Append to `apps/apple/Vigil/DesignSystem/GlassSurface.swift`:

```swift
/// Navigation-bar scrim opacities used by the opaque fallback. Two values
/// exist today and both are preserved exactly.
enum VigilToolbarSurface {
    static let standard = 0.97
    static let form = 0.96
}

private struct VigilToolbarSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let opacity: Double

    func body(content: Content) -> some View {
        if VigilGlassPolicy.usesGlass(
            osSupportsGlass: VigilGlassPolicy.osSupportsGlass,
            reduceTransparency: reduceTransparency
        ) {
            // iOS 26 renders bars in Liquid Glass with the automatic scroll
            // edge effect. Forcing the opaque background would defeat both
            // (liquid-glass reference: Design System Notes).
            content
        } else {
            content
                .toolbarBackground(VigilPalette.canvas.opacity(opacity), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

extension View {
    func vigilToolbarSurface(opacity: Double = VigilToolbarSurface.standard) -> some View {
        modifier(VigilToolbarSurfaceModifier(opacity: opacity))
    }
}

/// Groups sibling glass surfaces so they share one sampling region — glass
/// cannot sample other glass, and ungrouped neighbors render inconsistent
/// seams. A pass-through whenever glass is off.
struct VigilGlassContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *),
           VigilGlassPolicy.usesGlass(
               osSupportsGlass: VigilGlassPolicy.osSupportsGlass,
               reduceTransparency: reduceTransparency
           ) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
```

- [ ] **Step 4: Replace the seven toolbar call sites.** In each file, replace the two-line pair with one modifier — for the five 0.97 sites (`DashboardView.swift:41-42`, `AccountDetailView.swift:72-73`, `ConnectionsView.swift:47-48`, `SettingsView.swift:142-143`, `AddAccountView.swift:82-83`):

```swift
        .vigilToolbarSurface()
```

For the two 0.96 sites (`PrivacyView.swift:52-53`, and `ManualEntryView.swift:71-72` — keep it inside the existing `#if os(iOS)` block there):

```swift
        .vigilToolbarSurface(opacity: VigilToolbarSurface.form)
```

Then in `apps/apple/Vigil/Dashboard/DashboardView.swift`, wrap the Home card stack (the `LazyVStack(spacing: 12)` at line 151, inside `connectedContent`) so adjacent glass cards share a sampling region — container spacing matches the layout spacing per the reference:

```swift
            VigilGlassContainer(spacing: 12) {
                LazyVStack(spacing: 12) {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            AccountDetailView(
                                account: summary.account,
                                snapshot: summary.snapshot,
                                nextAllowed: summary.nextAllowed
                            )
                        } label: {
                            AccountLimitSummaryCard(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "vigil.home.account.\(summary.account.providerId)"
                        )
                    }
                }
            }
```

Other screens with stacked cards (AccountDetailView, ClaudeSignInView, CodexSignInView, ManualEntryView) are deliberately not wrapped in this PR; the Task 37 release-walk item records "wrap further stacks in VigilGlassContainer if the iOS 26 walk shows seams" as the follow-up trigger.

- [ ] **Step 5: Run test to verify it passes, then the UI accessibility suite for layout regressions**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests \
  -only-testing:VigilUITests/VigilAccessibilityUITests
```

Expected: PASS on both bundles. The UI suite (`VigilUITests/VigilAccessibilityUITests.swift` — launch env `VIGIL_TAB`/`VIGIL_DEMO` conventions, `reachableElement` frame checks) proves navigation bars, Home cards, and the add-account sheet keep their identifiers, hit targets, and reachability under whichever path the simulator runtime takes. Honest scope note: on an iOS 26 simulator this run exercises the glass path's layout but cannot judge material appearance; on an iOS 17 simulator it exercises only the fallback. Visual glass verification stays a manual iOS 26 check (Task 37 docs).

- [ ] **Step 6: Commit**

```sh
cd /Users/biscuit/Vigil && \
git add apps/apple/Vigil/DesignSystem/GlassSurface.swift \
        apps/apple/Vigil/Dashboard/DashboardView.swift \
        apps/apple/Vigil/Dashboard/AccountDetailView.swift \
        apps/apple/Vigil/Connections/ConnectionsView.swift \
        apps/apple/Vigil/Settings/SettingsView.swift \
        apps/apple/Vigil/Settings/PrivacyView.swift \
        apps/apple/Vigil/Onboarding/ManualEntryView.swift \
        apps/apple/Vigil/Onboarding/AddAccountView.swift \
        apps/apple/VigilTests/GlassSurfaceTests.swift && \
git commit -m "Adopt Liquid Glass toolbars and group Home cards in a glass container" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 36: Status-color AA contrast over the documented glass fallback surfaces

**PR:** PR-5 — Liquid Glass adoption (iOS 26+)
**Files:**
- Modify: `apps/apple/Vigil/DesignSystem/GlassSurface.swift` (append one pure helper)
- Test: `apps/apple/VigilTests/GlassSurfaceTests.swift`
**Interfaces:**
- Consumes (PR-1 test hooks, app target, exact signatures from the plan contract):
  - `extension VigilPalette { static func resolvedRGBA(_ color: Color, for scheme: ColorScheme) -> (r: Double, g: Double, b: Double, a: Double) }`
  - `static func contrastRatio(_ a: (r: Double, g: Double, b: Double, a: Double), _ b: (r: Double, g: Double, b: Double, a: Double)) -> Double`
  - `VigilGlassSurfaceStyle.fallbackFillOpacity` (Task 34)
- Produces: `extension VigilGlassPolicy { static func composite(_ top: (r: Double, g: Double, b: Double, a: Double), alpha: Double, over bottom: (r: Double, g: Double, b: Double, a: Double)) -> (r: Double, g: Double, b: Double, a: Double) }`

These tests extend PR-1's `contrastRatio` coverage to the two surfaces documented as the glass FALLBACK: the card composite (`surface` at 0.96 over `canvas`) and the inset (`surfaceInset`). They live in `GlassSurfaceTests` to keep PR-5 self-contained; if the reviewer prefers them beside PR-1's palette-contrast test class, moving them is a rename, not a rewrite. Stated honestly: computed contrast can only be proven for the opaque path — glass samples live content behind it, so no fixed ratio exists; the spec's rule ("if glass cannot hold contrast somewhere, that surface stays opaque") is enforced by the iOS 26-runtime manual check recorded in Task 37's docs step, not by these tests. The dark-theme numbers were verified against current main before writing the thresholds: worst case is `critical` vs the card composite at 5.94:1, so AA at 4.5:1 has real margin.

- [ ] **Step 1: Write the failing test** — append inside `GlassSurfaceTests`:

```swift
    // MARK: - WCAG AA over the documented glass fallback surfaces
    // Extends PR-1's contrast coverage. Glass itself has no computable ratio
    // (it samples live content); the glass path is verified on an iOS 26
    // runtime per docs/development/release.md §11.

    private let statusColors: [(name: String, color: Color)] = [
        ("signal", VigilPalette.signal),
        ("safe", VigilPalette.safe),
        ("caution", VigilPalette.caution),
        ("critical", VigilPalette.critical),
    ]

    func testCompositeMatchesSourceOverAlphaBlending() {
        let top = (r: 1.0, g: 0.5, b: 0.0, a: 1.0)
        let bottom = (r: 0.0, g: 0.5, b: 1.0, a: 1.0)
        let mixed = VigilGlassPolicy.composite(top, alpha: 0.75, over: bottom)
        XCTAssertEqual(mixed.r, 0.75, accuracy: 0.000001)
        XCTAssertEqual(mixed.g, 0.5, accuracy: 0.000001)
        XCTAssertEqual(mixed.b, 0.25, accuracy: 0.000001)
        XCTAssertEqual(mixed.a, 1.0, accuracy: 0.000001)
    }

    func testStatusColorsHoldAAOnTheOpaqueCardFallback() {
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let canvas = VigilPalette.resolvedRGBA(VigilPalette.canvas, for: scheme)
            let surface = VigilPalette.resolvedRGBA(VigilPalette.surface, for: scheme)
            let card = VigilGlassPolicy.composite(
                surface,
                alpha: VigilGlassSurfaceStyle.card.fallbackFillOpacity,
                over: canvas
            )
            for entry in statusColors {
                let resolved = VigilPalette.resolvedRGBA(entry.color, for: scheme)
                XCTAssertGreaterThanOrEqual(
                    VigilPalette.contrastRatio(resolved, card), 4.5,
                    "\(entry.name) must hold WCAG AA (4.5:1) on the card glass-fallback surface in \(scheme). Fix the palette value, never this threshold."
                )
            }
        }
    }

    func testStatusColorsHoldAAOnTheOpaqueInsetFallback() {
        let inset = VigilGlassSurfaceStyle.inset(cornerRadius: VigilRadius.medium)
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let canvas = VigilPalette.resolvedRGBA(VigilPalette.canvas, for: scheme)
            let surfaceInset = VigilPalette.resolvedRGBA(VigilPalette.surfaceInset, for: scheme)
            let background = VigilGlassPolicy.composite(
                surfaceInset,
                alpha: inset.fallbackFillOpacity,
                over: canvas
            )
            for entry in statusColors {
                let resolved = VigilPalette.resolvedRGBA(entry.color, for: scheme)
                XCTAssertGreaterThanOrEqual(
                    VigilPalette.contrastRatio(resolved, background), 4.5,
                    "\(entry.name) must hold WCAG AA (4.5:1) on the inset glass-fallback surface in \(scheme). Fix the palette value, never this threshold."
                )
            }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests
```

Expected failure: BUILD FAILED with `error: type 'VigilGlassPolicy' has no member 'composite'`.

- [ ] **Step 3: Minimal implementation.** Append to `apps/apple/Vigil/DesignSystem/GlassSurface.swift`:

```swift
extension VigilGlassPolicy {
    /// Source-over composite of a translucent fill over an opaque backdrop,
    /// in the same RGBA tuple space as VigilPalette.resolvedRGBA. Used by the
    /// contrast tests to compute the card fallback (surface at 0.96 over
    /// canvas) exactly as SwiftUI blends it.
    static func composite(
        _ top: (r: Double, g: Double, b: Double, a: Double),
        alpha: Double,
        over bottom: (r: Double, g: Double, b: Double, a: Double)
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            r: top.r * alpha + bottom.r * (1 - alpha),
            g: top.g * alpha + bottom.g * (1 - alpha),
            b: top.b * alpha + bottom.b * (1 - alpha),
            a: 1.0
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: `Test Suite 'GlassSurfaceTests' passed` (10 tests). If a light-theme assertion fails here, that is a real PR-1 palette defect surfaced by this coverage extension — per the spec, the fix is adjusting the light palette value in `VigilTheme.swift` (and PR-1's own contrast tests), never lowering the 4.5 threshold and never keeping glass on a surface that cannot hold contrast.

- [ ] **Step 5: Commit**

```sh
cd /Users/biscuit/Vigil && \
git add apps/apple/Vigil/DesignSystem/GlassSurface.swift apps/apple/VigilTests/GlassSurfaceTests.swift && \
git commit -m "Prove status-color AA contrast over the glass fallback surfaces" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 37: iOS 17 deployment-target guard, release-walk documentation, and CI-parity run

**PR:** PR-5 — Liquid Glass adoption (iOS 26+)
**Files:**
- Test: `apps/apple/VigilTests/GlassSurfaceTests.swift`
- Modify: `docs/development/release.md` (§11 "Test the delivered build", numbered list ending at item 11, lines 369–384; also the `Last reviewed:` header line)
- Modify: `docs/development/testing.md` ("Physical-device release checks" bullet list, lines 118–132; also the `Last reviewed:` header line)
**Interfaces:**
- Consumes: the app bundle's generated `Info.plist` (`MinimumOSVersion` is injected from `deploymentTarget: iOS "17.0"`, `apps/apple/project.yml:13-14`); the unit-test bundle is hosted in the app (`VigilTests` depends on the `Vigil` app target, `apps/apple/project.yml:92-98`), so `Bundle.main` is the app bundle.
- Produces: a regression tripwire ensuring Liquid Glass adoption never silently raises the deployment target, plus the honest documentation of what CI proves versus what the iOS 26 walk proves.

About requirement (d), stated plainly: the guard that "the deployment target still builds on iOS 17" is the full scheme run itself — the suite in Step 6 compiles the app at deployment target 17.0 and runs it, and on any toolchain without the iOS 26 SDK the `#if compiler(>=6.2)` gates compile the glass branches out, so CI (macos-15, `.github/workflows/apple.yml:13`) stays green either way. The unit test below adds the one thing the suite run cannot: it fails loudly if someone "fixes" glass by bumping the deployment target to 26.

- [ ] **Step 1: Write the failing test (deliberately miscalibrated so its red state is demonstrated)** — append inside `GlassSurfaceTests`:

```swift
    // MARK: - Deployment-target guard

    func testLiquidGlassAdoptionKeepsTheIOS17DeploymentTarget() {
        let minimum = Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
        XCTAssertEqual(
            minimum, "26.0",
            "Calibration placeholder — Step 3 corrects this to 17.0."
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

```sh
cd /Users/biscuit/Vigil/apps/apple && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO \
  -only-testing:VigilTests/GlassSurfaceTests/testLiquidGlassAdoptionKeepsTheIOS17DeploymentTarget
```

Expected failure: assertion failure `("17.0") is not equal to ("26.0")`. This proves the test reads the real built deployment target — the tripwire can actually fire.

- [ ] **Step 3: Correct the expectation**

```swift
    func testLiquidGlassAdoptionKeepsTheIOS17DeploymentTarget() {
        let minimum = Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
        XCTAssertEqual(
            minimum, "17.0",
            "Liquid Glass must never raise the deployment target: iOS 17 devices keep the opaque surfaces via the compiler and availability gates in GlassSurface.swift."
        )
    }
```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Document the iOS 26 manual verification (maintenance rule: docs land in the PR whose behavior they describe).** In `docs/development/release.md`, append item 12 to the §11 list (after line 384's item 11) and update the header's `Last reviewed:` date to the current date:

```markdown
12. On iOS 26 or later hardware (or an iOS 26 simulator when no such device
    is available, recorded as a simulator-only check): confirm Liquid Glass
    renders on the Home account cards, account-detail inset rows, navigation
    bars, and the add-account linking overlay, with status colors legible
    over glass; then enable Settings > Accessibility > Display & Text Size >
    Reduce Transparency and confirm every one of those surfaces returns to
    the opaque design. If any glass surface cannot hold status-color
    legibility, that surface reverts to opaque (spec rule) — file it, do not
    ship it. If adjacent glass cards show sampling seams on screens beyond
    Home, wrap their stacks in VigilGlassContainer as the follow-up. On
    earlier hardware, record this check as not performed.
```

In `docs/development/testing.md`, add one bullet to the "Physical-device release checks" list (after line 130's OpenAI Admin bullet) and update its `Last reviewed:` date:

```markdown
- Liquid Glass rendering and its Reduce Transparency fallback (iOS 26 or
  later only; CI simulators and the unit suite exercise the opaque fallback
  path and the glass-vs-opaque decision logic, never glass rendering itself)
```

Then validate: `cd /Users/biscuit/Vigil && scripts/check-docs.sh` — expected: exits 0.

- [ ] **Step 6: CI-parity full run — this is the iOS 17 build guard for the whole PR**

```sh
cd /Users/biscuit/Vigil && scripts/check-docs.sh && \
swift test --package-path packages/VigilKit && \
cd apps/apple && xcodegen generate && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO && \
DEVICE_UDID=$(xcrun simctl list devices available | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }') && \
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

Expected: all green — docs check, VigilKit package tests, the deployment-target-17 build, and the complete scheme (VigilTests + VigilUITests). This mirrors `.github/workflows/apple.yml` gate-for-gate. Record honestly in the PR description: this run proves the fallback path and both compile gates on whatever simulator runtime is first available; glass rendering remains the documented iOS 26 release-walk check from Step 5.

- [ ] **Step 7: Commit**

```sh
cd /Users/biscuit/Vigil && \
git add apps/apple/VigilTests/GlassSurfaceTests.swift \
        docs/development/release.md \
        docs/development/testing.md && \
git commit -m "Guard the iOS 17 deployment target and record the iOS 26 glass walk" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

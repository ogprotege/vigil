# iOS-only Vigil: remove vigil-link, the QR protocol, and the macOS target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse Vigil to a single phone-native platform — an iOS app that sets up every account on the device — by deleting the `vigil-link` CLI, the `vigil1` QR protocol, the computer-handoff UI, and the macOS target.

**Architecture:** This is subtraction plus a documentation rewrite. Nothing about fetching, mapping, scheduling, or display changes. Work proceeds inside-out: verify the replacement path first, then peel the app's QR surface, then the macOS target, then the CLI and protocol themselves, then docs. Each task leaves the repo building and green.

**Tech Stack:** Swift 5.10 / SwiftUI (iOS 17+), XcodeGen, Swift Package Manager (VigilKit), GitHub Actions.

## Global Constraints

- **iOS only.** After Task 3 the app target supports exactly one destination: `[iOS]`. Deployment target stays iOS 17.0.
- **Do NOT remove `.macOS(.v14)` from `packages/VigilKit/Package.swift`.** VigilKit's tests run on the host via `swift test`; removing the macOS platform breaks the test suite. Only the *app* target drops macOS.
- **The verification gate (Task 1) blocks every deletion.** No file may be deleted until one real Claude sign-in and one real Codex sign-in have succeeded on a device.
- **Merge PR #17 first, then rebase this branch onto `main`.** #17 fixes four Swift-mapper defects that matter after the TypeScript implementation is gone, and it also touches `cli/` (conflict resolves as: deletion wins).
- **Keep** `protocol/providers.json` and `protocol/fixtures/`. Delete only `protocol/qr-vectors/`.
- **ADRs are superseded, never deleted.** Add a status header; preserve the rationale.
- Live-endpoint tests must never run in CI. Gate them behind `VIGIL_LIVE_AUTH=1`.

---

## File Structure

**Deleted outright**
| Path | Why |
|---|---|
| `cli/` (entire package) | the vigil-link CLI |
| `protocol/qr-vectors/` | QR test vectors |
| `docs/qr-protocol.md` | QR protocol spec |
| `packages/VigilKit/Sources/VigilKit/Linking/` | contains only `QRDecoder.swift`, which also defines `LinkPayload` |
| `packages/VigilKit/Tests/VigilKitTests/QRVectorTests.swift` | QR vector parity |
| `packages/VigilKit/Sources/VigilKit/Providers/LocalCredentialDiscovery.swift` | Mac-only; sole consumer is `LocalImportView` |
| `packages/VigilKit/Tests/VigilKitTests/LocalCredentialDiscoveryTests.swift` | tests for the above |
| `apps/apple/Vigil/Onboarding/ScanView.swift` | camera QR scanner |
| `apps/apple/Vigil/Onboarding/PasteCodeView.swift` | paste-code path |
| `apps/apple/Vigil/Onboarding/LocalImportView.swift` | "Import from this Mac" |
| `apps/apple/Vigil/MenuBar/` | macOS menu-bar surface |
| `apps/apple/Entitlements/Vigil-macOS.entitlements` | macOS entitlements |
| `.github/workflows/cli.yml` | CLI CI |
| `docs/mac-checklist.md` | obsolete |

**Modified**
| Path | Responsibility after |
|---|---|
| `apps/apple/Vigil/Onboarding/AddAccountView.swift` | three phone-native paths only |
| `apps/apple/Vigil/AppModel.swift` | no `LinkPayload`, no `menuBarTitle` |
| `apps/apple/Vigil/VigilApp.swift` | one iOS `WindowGroup` scene; no deep link, no menu bar, no Settings scene |
| `apps/apple/Vigil/RootView.swift` | iOS tab navigation only |
| `apps/apple/project.yml` | iOS-only target; no camera, no URL scheme |
| `.github/workflows/apple.yml` | app tests on an iOS Simulator destination |
| `CLAUDE.md`, `README.md`, `docs/*` | single-platform, single-implementation |
| `docs/decisions/0003,0004,0005,0006,0007` | status headers |

**Created**
| Path | Responsibility |
|---|---|
| `packages/VigilKit/Tests/VigilKitTests/LiveAuthVerificationTests.swift` | opt-in live-endpoint probes for the phone-native auth flows |

---

## Task 1: Verify phone-native auth (BLOCKING GATE)

Nothing is deleted in this task. Its only deliverable is evidence that the on-device sign-in works, because after Task 4 it is the only way to add a Claude or Codex account.

**Files:**
- Create: `packages/VigilKit/Tests/VigilKitTests/LiveAuthVerificationTests.swift`

**Interfaces:**
- Consumes, with these exact verified signatures:
  - `ClaudeAuth.generatePKCE() -> ClaudeAuth.PKCE`, whose fields are `verifier`, `challenge`, `state`
  - `ClaudeAuth.authorizeURL(oauth: OAuthEndpoint, redirectURI: String, challenge: String, state: String) -> URL` (non-optional)
  - `OAuthEndpoint.manualRedirectUri` — the redirect URI `ClaudeSignInView` uses
  - `CodexAuth.userCodeRequest(oauth: OAuthEndpoint) -> URLRequest?`
  - `CodexAuth.parseUserCode(_ data: Data) -> CodexAuth.DeviceCode?`, whose fields are `deviceAuthId`, `userCode`, `intervalSeconds`
  - `CodexAuth.minimumPollInterval: TimeInterval`
- Produces: nothing consumed by later tasks. This is a gate, not a dependency.

- [ ] **Step 1: Write the live verification test**

Create `packages/VigilKit/Tests/VigilKitTests/LiveAuthVerificationTests.swift` with exactly this content.

```swift
import Foundation
import XCTest
@testable import VigilKit

/// Opt-in probes against the REAL provider auth endpoints.
///
/// These are the only proof that phone-native sign-in works, and after the CLI
/// is removed they guard the only path to a Claude or Codex account. They hit
/// the network, so they never run in CI: set VIGIL_LIVE_AUTH=1 to run them.
///
///     VIGIL_LIVE_AUTH=1 swift test --package-path packages/VigilKit \
///       --filter LiveAuthVerificationTests
///
/// They verify the mechanics only. The browser-approval half of both flows
/// needs a human and is covered by the on-device walk in Step 4.
final class LiveAuthVerificationTests: XCTestCase {
    private func requireLiveRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIGIL_LIVE_AUTH"] == "1",
            "set VIGIL_LIVE_AUTH=1 to run live endpoint probes"
        )
    }

    /// The authorize URL must be accepted by Anthropic — a malformed client id,
    /// redirect URI, or PKCE challenge shows up here as a 400.
    func testClaudeAuthorizeURLIsAcceptedLive() async throws {
        try requireLiveRun()
        let oauth = try XCTUnwrap(
            ProviderRegistry.claude.oauth,
            "claude must declare oauth metadata"
        )

        let pkce = ClaudeAuth.generatePKCE()
        let url = ClaudeAuth.authorizeURL(
            oauth: oauth,
            redirectURI: oauth.manualRedirectUri,
            challenge: pkce.challenge,
            state: pkce.state
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)

        XCTAssertLessThan(code, 400, "authorize URL rejected with HTTP \(code): \(url)")
        print("LIVE claude authorize -> HTTP \(code)")
    }

    /// Starting the device-code flow needs no approval, so a real device code
    /// coming back proves the request shape and the parser end to end.
    func testCodexDeviceAuthorizationReturnsARealCodeLive() async throws {
        try requireLiveRun()
        let oauth = try XCTUnwrap(
            ProviderRegistry.codex.oauth,
            "codex must declare oauth metadata"
        )

        let request = try XCTUnwrap(
            CodexAuth.userCodeRequest(oauth: oauth),
            "codex oauth metadata must supply a device-code URL"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertLessThan(code, 400, "device authorization failed with HTTP \(code)")

        let parsed = try XCTUnwrap(
            CodexAuth.parseUserCode(data),
            "live device-authorization body did not parse: "
                + (String(data: data, encoding: .utf8) ?? "<non-utf8>")
        )
        XCTAssertFalse(parsed.userCode.isEmpty)
        XCTAssertFalse(parsed.deviceAuthId.isEmpty)
        XCTAssertGreaterThanOrEqual(parsed.intervalSeconds, CodexAuth.minimumPollInterval)
        print("LIVE codex device code -> \(parsed.userCode) (interval \(parsed.intervalSeconds)s)")
    }
}
```

- [ ] **Step 2: Confirm the probes are skipped by default**

Run:
```bash
swift test --package-path packages/VigilKit --filter LiveAuthVerificationTests
```
Expected: the two tests report as **skipped**, and the run exits 0. This is what keeps CI offline and deterministic.

- [ ] **Step 3: Run the probes live**

Run:
```bash
VIGIL_LIVE_AUTH=1 swift test --package-path packages/VigilKit --filter LiveAuthVerificationTests
```
Expected: both PASS, with `LIVE claude authorize -> HTTP 200` (or another sub-400 status) and a real Codex user code printed.

**If either fails, STOP.** The phone-native path is broken and the project inverts: fix the mint before deleting anything. Report the failure and do not continue to Task 2.

- [ ] **Step 4: Get the human half of the gate**

Ask the user to perform, on the current TestFlight build (which still has every fallback):
1. **Add account → Sign in with Claude** — complete the browser approval and confirm the account appears and shows usage.
2. **Add account → Sign in with Codex** — complete the approval and confirm the account appears.

Record the outcome in the commit message. **Both must succeed before Task 2 begins.**

- [ ] **Step 5: Commit**

```bash
git add packages/VigilKit/Tests/VigilKitTests/LiveAuthVerificationTests.swift
git commit -m "test: add opt-in live probes for phone-native Claude and Codex auth

Gates the vigil-link removal. Skipped unless VIGIL_LIVE_AUTH=1 so CI stays
offline. Verified live: Claude authorize URL accepted, Codex device
authorization returns a real user code. On-device sign-in confirmed by the
user for both providers."
```

---

## Task 2: Remove the QR / computer-handoff surface from the app

**Files:**
- Delete: `apps/apple/Vigil/Onboarding/ScanView.swift`
- Delete: `apps/apple/Vigil/Onboarding/PasteCodeView.swift`
- Modify: `apps/apple/Vigil/Onboarding/AddAccountView.swift`
- Modify: `apps/apple/Vigil/AppModel.swift`
- Modify: `apps/apple/Vigil/VigilApp.swift`
- Modify: `apps/apple/project.yml`
- Modify: `apps/apple/VigilTests/AppModelReliabilityTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: an `AddAccountView` whose `LinkSource` enum has exactly one case, `credentials(Credentials)`. Task 3 edits the same file and must not reintroduce `payload`.

- [ ] **Step 1: Record the green baseline**

Run:
```bash
cd apps/apple && xcodegen generate && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`. Note the test count — it must not drop by more than the one test removed in Step 7.

- [ ] **Step 2: Delete the two view files**

```bash
git rm apps/apple/Vigil/Onboarding/ScanView.swift
git rm apps/apple/Vigil/Onboarding/PasteCodeView.swift
```

- [ ] **Step 3: Strip the pairing surface from `AddAccountView.swift`**

Remove, in this file:
- the `@State private var showScanner = false` property
- the `case payload(LinkPayload)` case of the `LinkSource` enum
- `computerPairingCard` from the `VStack` in `body`, and the whole `computerPairingCard` computed property
- the `.sheet(isPresented: $showScanner) { ScanView { ... } }` modifier
- the `pairingCommand` and `pairingSafetyNote` computed properties
- the `case .payload(let payload):` branch inside `attempt(...)`

The `LinkSource` enum must end up as:

```swift
    private enum LinkSource {
        case credentials(Credentials)
    }
```

- [ ] **Step 4: Remove `LinkPayload` from `AppModel.swift`**

Delete the `maximumFutureLinkSkewSeconds` constant (line ~18):

```swift
    static let maximumFutureLinkSkewSeconds = QRDecoder.maximumFutureSkewSeconds
```

and the entire `addAccounts(from payload: LinkPayload, ...)` method (starts line ~247).

- [ ] **Step 5: Remove the deep link from `VigilApp.swift`**

Delete: the `DeepLinkState` enum, the `@State private var deepLink` property, the `.onOpenURL { handleDeepLink(url) }` modifier, the deep-link `.alert(...)` block, and the `deepLinkAlertTitle`, `deepLinkAlertMessage`, `handleDeepLink(_:)`, and `add(_:allowUnverified:allowReplace:)` members.

- [ ] **Step 6: Remove the camera permission and URL scheme from `project.yml`**

Delete the `NSCameraUsageDescription` key (line ~66) and the whole `CFBundleURLTypes` block (lines ~83-85) that registers the `vigil1` scheme.

- [ ] **Step 7: Remove the obsolete link test**

In `apps/apple/VigilTests/AppModelReliabilityTests.swift`, delete `testFutureDatedLinkIsRejectedBeforeCredentialsAreSaved()` (line ~52) — it decodes a `LinkPayload`, a type this task removes.

- [ ] **Step 8: Rebuild and test**

```bash
cd apps/apple && xcodegen generate && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|Executed [0-9]+ tests|TEST"
```
Expected: `** TEST SUCCEEDED **`, test count exactly one lower than the Step 1 baseline.

- [ ] **Step 9: Assert the surface is actually gone**

```bash
cd /Users/biscuit/Vigil
grep -rn "ScanView\|PasteCodeView\|LinkPayload\|showScanner\|CFBundleURLTypes\|NSCameraUsageDescription" \
  --include="*.swift" --include="*.yml" apps/apple | grep -v "/build/"
```
Expected: **no output.**

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Remove the QR / computer-handoff surface from the app

Deletes the camera scanner, the paste-code path, the pairing card, LinkPayload
handling and the vigil1: deep link. Drops the camera permission and the vigil1
URL scheme from the bundle entirely — one fewer permission to justify.

Account setup is now phone-native only: Sign in with Claude, Sign in with
Codex, or paste a provider key."
```

---

## Task 3: Remove the macOS target

**Files:**
- Delete: `apps/apple/Entitlements/Vigil-macOS.entitlements`
- Delete: `apps/apple/Vigil/MenuBar/` (both files)
- Delete: `apps/apple/Vigil/Onboarding/LocalImportView.swift`
- Delete: `packages/VigilKit/Sources/VigilKit/Providers/LocalCredentialDiscovery.swift`
- Delete: `packages/VigilKit/Tests/VigilKitTests/LocalCredentialDiscoveryTests.swift`
- Modify: `apps/apple/project.yml`, `apps/apple/Vigil/VigilApp.swift`, `apps/apple/Vigil/RootView.swift`, `apps/apple/Vigil/Onboarding/AddAccountView.swift`, `apps/apple/Vigil/AppModel.swift`
- Modify: `.github/workflows/apple.yml`

**Interfaces:**
- Consumes: the single-case `LinkSource` from Task 2.
- Produces: an app target whose only destination is iOS. Task 4 assumes no macOS-only code remains.

- [ ] **Step 1: Delete the macOS-only files**

```bash
cd /Users/biscuit/Vigil
git rm apps/apple/Entitlements/Vigil-macOS.entitlements
git rm -r apps/apple/Vigil/MenuBar
git rm apps/apple/Vigil/Onboarding/LocalImportView.swift
git rm packages/VigilKit/Sources/VigilKit/Providers/LocalCredentialDiscovery.swift
git rm packages/VigilKit/Tests/VigilKitTests/LocalCredentialDiscoveryTests.swift
```

- [ ] **Step 2: Make the app target iOS-only in `project.yml`**

- Line ~6 comment: change `multiplatform SwiftUI app (iOS 17 / macOS 14)` to `iOS SwiftUI app (iOS 17)`.
- Delete the `macOS: "14.0"` line from `deploymentTarget` (line ~15).
- Change **both** `supportedDestinations: [iOS, macOS]` (lines ~33 and ~94) to `supportedDestinations: [iOS]`.
- Delete the `"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": Entitlements/Vigil-macOS.entitlements` line (~55).
- Delete the now-stale comment about running the test bundle under `xctest` on macOS (~103).

- [ ] **Step 3: Remove the macOS scenes from `VigilApp.swift`**

Delete the entire `#if os(macOS) ... #endif` block containing the `Settings { ... }` scene and the `MenuBarExtra { ... }` scene. The `body` must end after the iOS `WindowGroup`.

- [ ] **Step 4: Remove `menuBarTitle` from `AppModel.swift`**

Delete the `menuBarTitle` computed property (its only consumer was the `MenuBarExtra` label removed in Step 3).

- [ ] **Step 5: Collapse the `#if os(macOS)` branches in `RootView.swift`**

Three sites (lines ~31, ~45, ~132). In each, keep the `#else` / iOS body and delete the macOS branch plus the `#if` / `#else` / `#endif` scaffolding. Specifically:
- the `selection` property keeps the `VIGIL_TAB` environment-driven initializer
- `body` keeps the iOS `TabView`, dropping the `NavigationSplitView`
- delete the macOS-only `destinationView(_:)` helper entirely

- [ ] **Step 6: Collapse the `#if os(macOS)` branches in `AddAccountView.swift`**

Remove `localImportCard` from the `body` `VStack` and delete the `localImportCard` property. For the intro/help copy at lines ~115, ~311 and ~319, keep the iOS string and delete the macOS variant and its `#if`/`#else`/`#endif`.

- [ ] **Step 7: Move the CI test lane to an iOS Simulator**

In `.github/workflows/apple.yml`, replace the macOS test step with a simulator run. Discover the device rather than pinning a name, so the workflow survives Xcode image changes:

```yaml
      - name: Test app (iOS Simulator)
        run: |
          DEVICE=$(xcrun simctl list devices available \
            | grep -oE 'iPhone [0-9]+[^(]*' | head -1 | xargs)
          echo "Testing on: $DEVICE"
          xcodebuild -project Vigil.xcodeproj -scheme Vigil \
            -destination "platform=iOS Simulator,name=$DEVICE" \
            test CODE_SIGNING_ALLOWED=NO
        working-directory: apps/apple
```

Leave the existing iOS Simulator *build* step and the VigilKit `swift test` step untouched.

- [ ] **Step 8: Verify VigilKit still builds and tests on the host**

```bash
cd /Users/biscuit/Vigil && swift test --package-path packages/VigilKit 2>&1 \
  | grep -E "error:|Executed [0-9]+ tests" | tail -2
```
Expected: all tests pass. **`packages/VigilKit/Package.swift` must still declare `.macOS(.v14)`** — that is the host platform for `swift test`, not the app target. If you removed it, restore it.

- [ ] **Step 9: Build and test the iOS app**

```bash
cd apps/apple && xcodegen generate && \
  DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9]+[^(]*' | head -1 | xargs) && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST"
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 10: Assert macOS is gone**

```bash
cd /Users/biscuit/Vigil
grep -rn "os(macOS)\|MenuBar\|LocalImport\|LocalCredentialDiscovery\|macosx" \
  --include="*.swift" --include="*.yml" apps/apple packages/VigilKit/Sources packages/VigilKit/Tests \
  | grep -v "/build/"
```
Expected: **no output.**

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Remove the macOS target — iOS only

Deletes the menu-bar surface, the macOS Settings scene, macOS entitlements,
Import from this Mac, and LocalCredentialDiscovery (whose only consumer was the
Mac import view). The app target now supports a single destination.

App tests move from the macOS destination to an iOS Simulator, discovered at
run time so the workflow survives Xcode image changes. VigilKit keeps
.macOS(.v14) in Package.swift — that is the host platform for swift test, not
an app destination."
```

---

## Task 4: Delete the CLI and the QR protocol

**Files:**
- Delete: `cli/`, `protocol/qr-vectors/`, `docs/qr-protocol.md`
- Delete: `packages/VigilKit/Sources/VigilKit/Linking/` (contains only `QRDecoder.swift`, which also defines `LinkPayload`)
- Delete: `packages/VigilKit/Tests/VigilKitTests/QRVectorTests.swift`
- Delete: `.github/workflows/cli.yml`

**Interfaces:**
- Consumes: Tasks 2 and 3 must be complete — after them nothing references `QRDecoder` or `LinkPayload`.
- Produces: a repo with one implementation. Task 5 documents that.

- [ ] **Step 1: Confirm nothing still references the QR types**

```bash
cd /Users/biscuit/Vigil
grep -rn "QRDecoder\|LinkPayload\|QRDecodeError" --include="*.swift" apps packages | grep -v "/build/" \
  | grep -v "packages/VigilKit/Sources/VigilKit/Linking/" \
  | grep -v "packages/VigilKit/Tests/VigilKitTests/QRVectorTests.swift"
```
Expected: **no output.** If anything appears, fix it before deleting — otherwise the build breaks.

- [ ] **Step 2: Delete everything**

```bash
git rm -r cli
git rm -r protocol/qr-vectors
git rm docs/qr-protocol.md
git rm -r packages/VigilKit/Sources/VigilKit/Linking
git rm packages/VigilKit/Tests/VigilKitTests/QRVectorTests.swift
git rm .github/workflows/cli.yml
```

- [ ] **Step 3: Verify VigilKit builds and tests**

```bash
cd /Users/biscuit/Vigil && swift test --package-path packages/VigilKit 2>&1 \
  | grep -E "error:|Executed [0-9]+ tests" | tail -2
```
Expected: all tests pass, with the QR vector tests gone from the count.

- [ ] **Step 4: Verify the app builds and tests**

```bash
cd apps/apple && xcodegen generate && \
  DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9]+[^(]*' | head -1 | xargs) && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|TEST"
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Confirm the registry and fixtures survived**

```bash
cd /Users/biscuit/Vigil
test -f protocol/providers.json && echo "registry OK"
ls protocol/fixtures/*.json | wc -l
```
Expected: `registry OK` and a non-zero fixture count. These are the app's registry and its mapper tests — deleting them is a mistake.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Delete the vigil-link CLI and the vigil1 QR protocol

Removes the TypeScript package, the QR test vectors, the protocol spec, the
Swift decoder (which also defined LinkPayload), the QR vector parity tests, and
the CLI CI workflow.

The Swift mapper is now the sole implementation; protocol/fixtures still pin it.
What is lost is the cross-language check between the two mappers — accepted
deliberately, because with one implementation that class of divergence stops
existing rather than going undetected."
```

---

## Task 5: Rewrite the docs and supersede the ADRs

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/getting-started.md`, `docs/troubleshooting.md`, `docs/provider-spec.md`, `docs/architecture.md`, `docs/threat-model.md`, `docs/faq.md`, `docs/release.md`, `docs/privacy.md`
- Delete: `docs/mac-checklist.md`
- Modify: `docs/decisions/0003-plaintext-qr.md`, `0004-stateless-cli.md`, `0005-mint-dont-copy.md`, `0006-vigil-link-name.md`, `0007-hand-rolled-prompts.md`

**Interfaces:**
- Consumes: the finished state from Tasks 2-4.
- Produces: documentation matching the shipped product. No later task depends on it.

- [ ] **Step 1: Find every stale reference**

```bash
cd /Users/biscuit/Vigil
grep -rn "vigil-link\|vigil1\|npx \|QR\|menu bar\|menu-bar\|macOS\|Import from this Mac" \
  --include="*.md" . | grep -v node_modules | grep -v CHANGELOG.md | grep -v docs/superpowers/
```
Keep this list — it is the work queue for Steps 2-4.

- [ ] **Step 2: Rewrite `CLAUDE.md`**

This is a genuine rewrite, not a find-and-replace: three sections are built on the CLI's existence.
- **"What Vigil is"** — an iOS app; every credential is provisioned on the phone (Sign in with Claude, Sign in with Codex, or paste a provider key). Delete the `vigil1` QR handoff paragraph.
- **"Commands"** — delete the entire CLI section. Keep the VigilKit `swift test` command. Update the Apple section to iOS-only, replacing the macOS build line with the simulator test command from Task 3 Step 9.
- **"Architecture: one contract, two implementations"** — retitle to a single implementation. `protocol/providers.json` remains the source of truth; the Swift `ProviderRegistry` mirror and `SpecParityTests` remain; delete the fixture-parity-across-languages and QR-vector-parity bullets.
- **Invariants** — delete "The CLI is credential-stateless" and the QR protocol section. Keep the poll floor, honest freshness, persistence, and the Claude `User-Agent` requirement. Reword "VigilKit stays UI-free" (still true).

- [ ] **Step 3: Sweep the remaining docs**

Work the Step 1 list. Delete the obsolete file:

```bash
git rm docs/mac-checklist.md
```

For each remaining doc, remove CLI/QR/Mac setup paths and leave the three phone-native paths. `docs/threat-model.md` needs the macOS sandbox-exception section deleted — those entitlements no longer exist. `docs/release.md` loses its macOS distribution section.

- [ ] **Step 4: Add status headers to the superseded ADRs**

Do not delete these files; the rationale is worth keeping. Insert immediately under each title:

`docs/decisions/0003-plaintext-qr.md`, `0004-stateless-cli.md`, `0006-vigil-link-name.md`, `0007-hand-rolled-prompts.md`:
```markdown
> **Status: superseded (2026-07-21).** Vigil is iOS-only and phone-native; the
> `vigil-link` CLI and the `vigil1` QR protocol were removed. Kept for the
> historical rationale.
```

`docs/decisions/0005-mint-dont-copy.md`:
```markdown
> **Status: amended (2026-07-21).** The principle stands and now governs the
> on-device sign-in: Vigil mints its own token and never auto-refreshes a
> credential it did not create. The CLI-copy context is historical — the CLI and
> the Mac import path have been removed.
```

- [ ] **Step 5: Verify no stale references remain**

```bash
cd /Users/biscuit/Vigil
grep -rn "vigil-link\|vigil1\|npx " --include="*.md" . \
  | grep -v node_modules | grep -v CHANGELOG.md | grep -v docs/decisions/ | grep -v docs/superpowers/
```
Expected: **no output.** CHANGELOG, ADRs, and this plan/spec keep their historical references by design.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Docs: rewrite for an iOS-only, phone-native Vigil

Rewrites CLAUDE.md around a single platform and a single implementation, sweeps
every vigil-link / QR / Mac setup path from the docs, deletes the obsolete mac
checklist, and marks ADRs 0003/0004/0006/0007 superseded and 0005 amended —
status headers rather than deletions, so the rationale survives."
```

---

## Task 6: Deprecate the npm package (user-run)

**Files:** none in this repo.

- [ ] **Step 1: Ask the user to run the deprecation**

This needs npm credentials the agent does not have. Unpublishing is unavailable after 72 hours, so deprecation is the lever; existing installs keep working and every new install warns.

```sh
npm deprecate vigil-link \
  "vigil-link is retired. Vigil is now iOS-only and sets up entirely on the phone — sign in to Claude and ChatGPT/Codex in the app, or paste a provider key. No CLI needed."
```

- [ ] **Step 2: Confirm it took effect**

```bash
npm view vigil-link deprecated
```
Expected: the deprecation message prints.

---

## Final verification

- [ ] **Full suite green**

```bash
cd /Users/biscuit/Vigil && swift test --package-path packages/VigilKit 2>&1 | tail -3
cd apps/apple && xcodegen generate && \
  DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9]+[^(]*' | head -1 | xargs) && \
  xcodebuild -project Vigil.xcodeproj -scheme Vigil \
    -destination "platform=iOS Simulator,name=$DEVICE" test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

- [ ] **Acceptance criteria from the spec**

```bash
cd /Users/biscuit/Vigil
# no CLI, no QR, no Mac anywhere outside history
grep -rn "vigil-link\|vigil1" --include="*.swift" --include="*.yml" --include="*.json" . \
  | grep -v node_modules | grep -v "/build/" | grep -v CHANGELOG
# no camera permission, no URL scheme
grep -n "NSCameraUsageDescription\|CFBundleURLTypes" apps/apple/project.yml
# iOS only
grep -n "supportedDestinations" apps/apple/project.yml
```
Expected: the first two produce no output; the third shows only `[iOS]`.

- [ ] **On-device confirmation** — adding a Claude account, a Codex account, and an API-key provider all succeed on a phone with no computer involved.

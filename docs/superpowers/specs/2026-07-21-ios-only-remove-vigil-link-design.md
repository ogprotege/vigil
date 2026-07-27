# Design: iOS-only Vigil — remove vigil-link, the QR protocol, and the macOS target

> **Historical and superseded as active instruction.** The iOS-only removal was
> completed on 2026-07-21. This file preserves the approved design and its
> original sequencing assumptions. It is not a current implementation plan.
> See the [documentation index](../../index.md),
> [product contract](../../product-contract.md), and
> [development guide](../../development/development.md).

Date: 2026-07-21
Status: approved (design), pending implementation plan

## Goal

Vigil becomes a single-platform, phone-native product: an **iOS app** that sets up
every account **on the phone**, with no companion CLI, no computer handoff, and no
Mac. The `vigil-link` npm package, the `vigil1` QR protocol, and the macOS app
target are removed entirely.

The premise of Vigil has always been "set up on the phone." Today that is true in
principle but hedged everywhere by a CLI fallback, a QR transport, and a Mac import
path. Those hedges cost real surface area — a whole TypeScript package, a bespoke
chunked-QR protocol on both sides, a camera permission, a URL scheme, cross-language
parity CI — and they let the phone-native path stay unproven. Removing them makes
the phone path the only path, which is both the product intent and the forcing
function for making it solid.

## Relationship to PR #17 (audit remediation)

This branch is cut from `main`, which does **not** yet contain PR #17. That PR
fixes four Swift-mapper defects (fractional-second ISO-8601, non-array aggregate
root, absent aggregate leaf, Cc+Cf sanitizing), a poll-floor leak on cancelled
fetches, and adds the Swift tests that pin them. Those fixes are app-side and
matter after the CLI is gone.

PR #17 also modifies `cli/`, which this work deletes. The overlap resolves
trivially — deletion wins — but the ordering must be deliberate:

**Merge PR #17 first, then rebase this work onto `main`.** Doing it the other way
would either drop the Swift mapper fixes or force them to be re-applied by hand.
If #17 is rejected instead, its Swift-side fixes must be cherry-picked into this
branch before the CLI is deleted, because after deletion there is no TypeScript
implementation left to compare against.

## Non-goals

- Changing how usage is fetched, mapped, or displayed. The registry
  (`protocol/providers.json`), the Swift mapper, the poll-floor scheduler, widgets,
  and every provider integration are untouched.
- Adding new providers or new setup methods.
- Re-architecting the app. This is subtraction plus a documentation rewrite.
- Shipping to the App Store. TestFlight remains the distribution channel.

## The verification gate (blocking, and it needs you)

After this change there is **no other way** to add a Claude or ChatGPT/Codex
account than the on-device sign-in. Today's proven path is the CLI mint
(live-verified in Phase 1); the phone-native `ClaudeAuth` (OAuth + PKCE) and
`CodexAuth` (device code) have unit tests but **have never completed a real
sign-in against a live endpoint on a device**.

Deleting the fallback before proving the replacement works would risk an app in
which no Claude or Codex account can be added at all.

**What can be verified without a device or user:**

- The Claude authorize URL is well-formed and accepted by the live endpoint.
- The Codex device-authorization POST returns a real device code + user code
  (initiating the flow needs no approval).
- Request shapes, PKCE derivation, and header construction match what the
  live endpoints expect.

**What cannot, and needs ~5 minutes from the user:** the browser-approval step.
Both flows require a human to authorize and return a code. Full end-to-end
certification therefore requires one real **Sign in with Claude** and one real
**Sign in with Codex** on a build that still has the fallback.

**Sequencing:** verification is Phase 1 and gates everything else. If the phone
mint turns out broken, the project changes: fix the mint first, delete second.
The deletion must not merge until both sign-ins have succeeded on-device.

Explicitly **not** an acceptable verification: exercising `TokenRefresher` against
the user's existing Claude Code refresh token. That would rotate a credential Vigil
does not own and race Claude Code's rotation — precisely what ADR-0005 forbids.

## Scope

### Deleted

**1. The `vigil-link` CLI (`cli/`, ~3.8k LOC + 17 test files)**
The entire package: `status`, `doctor`, `link`, `wizard`, the OAuth mint, the
TypeScript mapper, TypeScript discovery, the QR encoder, and the terminal UI.

**2. The `vigil1` QR protocol, both sides**
- `protocol/qr-vectors/`
- `docs/qr-protocol.md`
- `packages/VigilKit/Sources/VigilKit/Linking/QRDecoder.swift`
- `packages/VigilKit/Tests/VigilKitTests/QRVectorTests.swift`
- The QR-vector parity CI check

**3. The app's computer-handoff surface**
- `apps/apple/Vigil/Onboarding/ScanView.swift` (camera QR scanner)
- `apps/apple/Vigil/Onboarding/PasteCodeView.swift`
- `computerPairingCard` in `AddAccountView.swift`
- `LinkPayload` handling in `AppModel` (`addAccounts(from:)`)
- The `vigil1:` deep link (`.onOpenURL`) in `VigilApp.swift`
- From `project.yml`: the `vigil1` `CFBundleURLTypes` entry and
  `NSCameraUsageDescription` — the camera permission disappears entirely, which is
  a genuine privacy win (one fewer prompt, one fewer entitlement to justify).

**4. The macOS target**
- `supportedDestinations: [iOS, macOS]` → `[iOS]` (app and test targets); the
  `macOS: "14.0"` deployment target
- `apps/apple/Entitlements/Vigil-macOS.entitlements` (including the sandbox
  temporary-exception for `.claude/` and `.codex/` added for Mac import)
- `apps/apple/Vigil/MenuBar/` — `MenuBarContentView.swift`, `MenuBarLockedView.swift`
- The `MenuBarExtra` and macOS `Settings` scenes in `VigilApp.swift`;
  `AppModel.menuBarTitle`
- `apps/apple/Vigil/Onboarding/LocalImportView.swift` ("Import from this Mac")
- `packages/VigilKit/Sources/VigilKit/Providers/LocalCredentialDiscovery.swift`
  and its tests — verified to be used **only** by `LocalImportView`, so it leaves
  cleanly with no other consumer
- `#if os(macOS)` branches in `AddAccountView.swift` and `RootView.swift`

**5. The npm package**
Unpublishing is not available after 72 hours, so deprecation is the real lever.
**This step requires the user's npm credentials and is theirs to run:**

```sh
npm deprecate vigil-link \
  "vigil-link is retired. Vigil is now iOS-only and sets up entirely on the phone — sign in to Claude and ChatGPT/Codex in the app, or paste a provider key. No CLI needed."
```

Deprecation keeps existing installs working while warning on every new install.
The package is not unpublished, so anyone mid-migration is not broken.

### Kept

- The iOS app and its widgets.
- `VigilKit`, minus `QRDecoder` and `LocalCredentialDiscovery`.
- `protocol/providers.json` and `protocol/fixtures/` — the registry the app reads
  and the fixtures that validate the Swift mapper.
- All three phone-native setup paths: **Sign in with Claude** (OAuth), **Sign in
  with Codex** (device code), and **Paste a provider key** (all 14 providers).
- The poll-floor scheduler, snapshot/observation stores, notifications, app lock.

## Architecture after

CLAUDE.md's central "**one contract, two implementations**" story collapses to one
implementation. The consequences, which the rewrite must state plainly:

- The Swift mapper becomes the **sole** mapper. `protocol/fixtures/` still pins it
  against expected outputs; what disappears is the cross-language check that the
  TypeScript and Swift mappers agree.
- This is a real loss of a safety net. The recent audit found four TS/Swift
  divergences that only existed *because* there were two implementations — but the
  cross-check is also what caught them. With one implementation the class of bug
  disappears rather than going undetected, so the net is positive, but the Swift
  fixture suites become more load-bearing, and any comment referring to "the CLI"
  as a reference implementation must be rewritten.
- Spec parity (`providers.json` ↔ `ProviderRegistry.swift`) **remains** and stays
  enforced — that mirror is app-internal and unrelated to the CLI.

### ADR disposition

Rationale trails are preserved, not deleted. Each gets a status header:

| ADR | Disposition |
|---|---|
| 0001 on-device-only | **Keep** — more true than before |
| 0002 xcodegen | **Keep** |
| 0003 plaintext-qr | **Superseded** — QR protocol removed |
| 0004 stateless-cli | **Superseded** — CLI removed |
| 0005 mint-dont-copy | **Amended** — the principle survives for phone OAuth (Vigil mints its own token); the CLI-copy context is historical |
| 0006 vigil-link-name | **Superseded** — tool removed |
| 0007 hand-rolled-prompts | **Superseded** — CLI terminal prompts removed |

## CI

- Delete `.github/workflows/cli.yml` entirely.
- `apple.yml`: drop the `-destination 'platform=macOS'` test lane and run the app
  tests on an **iOS Simulator** destination instead. This is slower (simulator boot)
  but is the only option once the app no longer supports macOS.
- `swift test --package-path packages/VigilKit` is unaffected — it is a Swift
  package test running on the host, not an app-target test.
- Keep the fixture-parity and spec-parity Swift tests; delete QR-vector parity.

## Documentation

Sweep every vigil-link / QR / Mac reference from: `README.md`, `CLAUDE.md`,
`docs/getting-started.md`, `docs/troubleshooting.md`, `docs/provider-spec.md`,
`docs/architecture.md`, `docs/threat-model.md`, `docs/faq.md`, `docs/release.md`,
`docs/privacy.md`, and `docs/mac-checklist.md` (which becomes obsolete).

`CLAUDE.md` needs a genuine rewrite, not a find-and-replace: its "What Vigil is",
"Commands", and "Architecture: one contract, two implementations" sections are all
built around the CLI's existence.

## Risks

| Risk | Mitigation |
|---|---|
| Phone sign-in is broken and the fallback is gone | Phase 1 verification gate; do not merge until one real Claude and one real Codex sign-in succeed on-device |
| Deleting the macOS target strands the app test lane | Move app tests to an iOS Simulator destination and confirm green before deleting the macOS destination |
| Losing the TS↔Swift mapper cross-check | Accepted deliberately; the Swift fixture suite is retained and strengthened, and the divergence class disappears with the second implementation |
| npm package still installable by old docs | `npm deprecate` with a message pointing at the iOS app; strip every `npx vigil-link` reference from docs |
| Someone currently relies on the QR handoff | It is already badged "Last resort" in-app; users re-add accounts with on-device sign-in, which is the point of the change |

## Phases

1. **Verify phone-native auth** (gate). Prove endpoint reachability and request
   shapes here; get one real on-device Claude sign-in and one Codex sign-in from
   the user. Nothing is deleted in this phase.
2. **Remove the QR/computer-handoff surface from the app.** ScanView, PasteCodeView,
   the pairing card, `LinkPayload`, the deep link, URL scheme, camera permission.
3. **Remove the macOS target.** Menu bar, Settings scene, entitlements,
   LocalImportView, LocalCredentialDiscovery, `#if os(macOS)` branches; move the
   test lane to iOS Simulator.
4. **Delete `cli/` and the QR protocol.** Package, qr-vectors, QRDecoder,
   QRVectorTests, `cli.yml`.
5. **Rewrite the docs and ADRs.** CLAUDE.md rewrite, doc sweep, ADR status headers.
6. **Deprecate the npm package** (user-run command).

## Acceptance criteria

- No file in the repo references `vigil-link`, `vigil1`, `npx `, or the QR protocol
  except historical CHANGELOG and superseded ADR entries.
- `apps/apple` builds for iOS only; no macOS destination, no camera permission,
  no `vigil1` URL scheme.
- App tests run green on an iOS Simulator destination in CI.
- VigilKit tests green with `QRVectorTests` and `LocalCredentialDiscoveryTests`
  removed and every other suite intact.
- Adding a Claude account, a Codex account, and an API-key provider all succeed on
  a device with no computer involved.
- `CLAUDE.md` describes a single-platform, single-implementation product.

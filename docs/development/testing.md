# Testing guide

- Status: Current
- Last reviewed: 2026-07-26
- Review again: whenever test targets, CI, simulator requirements, or live probes change

This guide owns the repository test commands. Run project generation and local setup from the [development guide](development.md) first.

## Test layers

| Layer | What it proves |
|---|---|
| `VigilKitTests` | Provider mapping, contract parity, provenance, auth helpers, scheduling, thresholds, persistence, history, and retention |
| `VigilTests` | App model behavior, provider presentation, history conversion, diagnostics, privacy policy, reliability, and UI-facing truth rules |
| `VigilUITests` | Accessibility behavior and privacy-lock presentation in a simulator |
| Opt-in live auth probes | Current Claude authorization URL and Codex device-code request acceptance |
| Physical-device checks | Signed entitlements, Keychain/App Group sharing, browser approval, notifications, background work, and widgets |

Fixture tests prove mapping against committed data. They do not prove that an upstream endpoint is live or unchanged.

## Core package tests

Run from the repository root:

```sh
swift test --package-path packages/VigilKit
```

Two live authentication tests skip by default. A normal successful package run can therefore report skips.

## Documentation checks

Run before code tests so stale setup or release instructions fail early:

```sh
scripts/check-docs.sh
```

This validates required current files, local Markdown links, review metadata, balanced code fences, canonical link targets, and the version/build identity.

Useful focused package gates are:

```sh
swift test --package-path packages/VigilKit --filter SpecParityTests
swift test --package-path packages/VigilKit --filter FixtureParityTests
swift test --package-path packages/VigilKit --filter FixtureProvenanceTests
```

## Complete Xcode scheme

Generate the project, select the first available iPhone simulator, and run both app test targets:

```sh
xcodegen generate --spec apps/apple/project.yml

VIGIL_TEST_DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
test -n "$VIGIL_TEST_DEVICE_UDID"

xcodebuild \
  -project apps/apple/Vigil.xcodeproj \
  -scheme Vigil \
  -destination "platform=iOS Simulator,id=$VIGIL_TEST_DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

The scheme runs `VigilTests` and `VigilUITests`. Do not treat a package-only pass as the complete iOS gate.

## Property-list and entitlement lint

Run from the repository root:

```sh
plutil -lint \
  apps/apple/Vigil/Info.plist \
  apps/apple/VigilWidgets/Info.plist \
  apps/apple/Vigil/Resources/PrivacyInfo.xcprivacy \
  apps/apple/VigilWidgets/PrivacyInfo.xcprivacy \
  apps/apple/Entitlements/Vigil-iOS.entitlements \
  apps/apple/Entitlements/VigilWidgets.entitlements
```

This catches syntax errors. It does not prove that a signed archive contains the expected entitlements or privacy manifests.

## Opt-in live auth probes

The live probes contact real provider authentication endpoints. They do not complete browser approval and do not read usage. Run them only when current endpoint verification is needed:

```sh
VIGIL_LIVE_AUTH=1 swift test \
  --package-path packages/VigilKit \
  --filter LiveAuthVerificationTests
```

These tests return a real Codex device code in test output. Do not attach raw output to public issues. The code is short-lived, but it is still unnecessary authentication data.

## Provider fixture expectations

Provider changes must pass all three evidence gates:

1. `SpecParityTests` confirms that the Swift runtime mirror matches `protocol/providers.json`.
2. `FixtureParityTests` confirms that every mapped input produces the hand-authored expected windows and metrics.
3. `FixtureProvenanceTests` confirms that every fixture is classified and tied to a declared source.

Add hostile and partial-shape cases for fields that must fail closed. A 200 response with missing required output must not remain `ok`.

## Diagnostic export expectations

`DiagnosticExportTests` verify an allow-list boundary. They seed credential-like strings in account keys, labels, provider-controlled IDs, labels, units, and app metadata, then assert that none appears in the JSON.

When the diagnostic schema changes:

- Increment `schemaVersion` for an incompatible consumer-facing change.
- Update [Diagnostic schema](diagnostic-schema.md).
- Add a test for every newly exported field.
- Prove that arbitrary labels, raw provider bodies, credentials, headers, and cookies remain absent.

## Physical-device release checks

Simulator tests cannot prove these behaviors:

- Claude browser approval and code exchange
- Codex device authorization after enabling the account security setting
- Shared Keychain access between the signed app and widget
- Shared App Group snapshots, history, and polling ledger
- Face ID or Touch ID behavior
- Local notification authorization and threshold delivery
- Opportunistic `BGAppRefreshTask` execution
- System, Light, and Dark appearance on supported iOS runtimes
- Usage-alert disablement and generic notification copy
- Widget configuration, refresh, value redaction, and paused-automatic-check behavior
- OpenAI Admin history with an authorized organization account

Use dedicated test credentials. Never capture or commit raw tokens, cookies, Admin API keys, or unsanitized provider bodies.

## CI parity

The `apple` workflow runs on macOS and performs these gates on every branch push and pull request:

1. Validate the current documentation set.
2. Reject tracked signing credentials and profiles.
3. Run all `VigilKit` tests.
4. Install XcodeGen and generate the project.
5. Build the app for a generic iOS simulator without signing.
6. Run the complete Vigil scheme on an available iPhone simulator.
7. Lint app and widget plists, privacy manifests, and entitlements.

Local validation should match those gates before a pull request is declared ready.

## Related documentation

- [Development guide](development.md)
- [Architecture](architecture.md)
- [Provider contribution](provider-contribution.md)
- [Diagnostic schema](diagnostic-schema.md)

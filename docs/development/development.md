# Development guide

- Status: Current
- Last reviewed: 2026-07-26
- Review again: whenever the XcodeGen manifest, deployment target, Swift toolchain, or CI workflow changes

This guide owns the local setup, project-generation, and build commands. The [testing guide](testing.md) owns test commands. Provider work should link to these guides instead of copying command blocks.

## Requirements

- A Mac with the current Xcode command-line tools
- Xcode 16 or later for the generated project format used by current CI
- Swift 5.10 or later
- XcodeGen

Vigil targets iOS 17 and later. `VigilKit` also declares macOS 14 so its UI-free tests can run on a Mac.

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

Confirm the tools selected on the Mac:

```sh
xcodebuild -version
swift --version
xcodegen --version
```

## Generate the Xcode project

Run from the repository root:

```sh
xcodegen generate --spec apps/apple/project.yml
```

Then open the generated project:

```sh
open apps/apple/Vigil.xcodeproj
```

`apps/apple/project.yml` is canonical. `apps/apple/Vigil.xcodeproj` is generated and ignored. Do not make lasting project changes only in Xcode's generated project editor.

Regenerate after changing targets, sources, build settings, bundle metadata, entitlements, package dependencies, or scheme configuration.

## Build for the simulator

Generate the project first, then run:

```sh
xcodebuild \
  -project apps/apple/Vigil.xcodeproj \
  -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

The app, unit-test bundle, UI-test bundle, and widget are declared in `project.yml`. The `Vigil` scheme includes both test bundles.

## Repository layout

```text
apps/apple/
  project.yml             XcodeGen source
  Vigil/                  iOS app
  VigilTests/             app tests
  VigilUITests/           UI tests
  VigilWidgets/           WidgetKit extension

packages/VigilKit/
  Sources/VigilKit/       UI-free core
  Tests/VigilKitTests/    package tests

protocol/
  providers.json          reviewable provider contract
  fixture-provenance.json fixture evidence ledger
  fixtures/               input and expected-output files
```

See [Architecture](architecture.md) for component and data-flow ownership.

## Configuration rules

- Keep bundle identifiers, version, build number, signing settings, entitlements, Info.plist properties, and target membership in `apps/apple/project.yml`.
- Keep provider request and mapping intent in `protocol/providers.json` and its Swift mirror.
- Keep fixture evidence in `protocol/fixture-provenance.json`.
- Never commit `.p8`, `.p12`, or `.mobileprovision` files. CI rejects tracked signing material.
- Do not add production credentials, provider response bodies with personal data, raw authorization headers, or browser cookies to tests.
- Preserve the iOS-only product boundary. A macOS package platform does not authorize a desktop app target.

## Signing behavior

Simulator builds disable signing. Device and App Store builds use the manual distribution profiles declared for the app and widget in `project.yml`.

Do not add provisioning-update flags to ordinary simulator work. Distribution work must use the repository release procedure and verify the signed archive before any upload.

## Common failures

### Xcode project missing

Run the XcodeGen command again. The project is intentionally not tracked.

### Xcode opens an unsupported project format

Confirm that the selected Xcode is version 16 or later. Current CI uses a macOS 15 runner because older hosted Xcode versions cannot open the generated format.

### App Group unavailable in an unsigned build

Unsigned previews and some local simulator configurations can lack the signed App Group container. Vigil falls back to Application Support and reports degraded cross-process sharing. That fallback is useful for local UI work, but it does not verify production entitlements.

### Provider changes compile but parity fails

The JSON contract and Swift runtime mirror differ. Update both intentionally, then update fixtures and provenance. Follow the [provider contribution guide](provider-contribution.md).

## Before opening a pull request

1. Run `scripts/check-docs.sh`.
2. Regenerate the Xcode project.
3. Run the complete package and Xcode test gates in [Testing](testing.md).
4. Lint the property lists, privacy manifests, and entitlements.
5. Confirm no credential or signing file is tracked.
6. Update the canonical provider or developer documentation when behavior changed.

## Related documentation

- [Architecture](architecture.md)
- [Testing](testing.md)
- [Provider contribution](provider-contribution.md)
- [Provider support matrix](../providers/support-matrix.md)

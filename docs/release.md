# Release runbook: TestFlight and App Store

This runbook covers the iOS app and widget extension. The repository no longer builds or publishes a desktop app or command-line package. The legacy `vigil-link@0.2.0` npm artifact remains installable until the authenticated deprecation step below is completed.

The first live TestFlight upload occurred on 2026-07-18. The examples below target version **0.14.0**, build **15**.

## One-time setup

- Apple Developer team: `4KBWH9KYSD`.
- App bundle ID: `app.vigil.app`.
- Widget bundle ID: `app.vigil.app.widgets`.
- App Group: `group.app.vigil.shared`.
- App Store Connect app: **Vigil - AI Usage Monitor**, Apple ID `6792373775`, SKU `vigil-001`.
- Internal TestFlight group: **Internal**, with automatic build distribution enabled.

The App Store Connect API key belongs under `~/private_keys/` on the release machine. Signing material must never live inside the repository.

Device and App Store builds use manual distribution signing because this team has no registered development devices. `apps/apple/project.yml` scopes those settings to `[sdk=iphoneos*]`, so Simulator builds remain signing-free.

Required profiles:

- `Vigil AppStore` for `app.vigil.app`;
- `VigilWidgets AppStore` for `app.vigil.app.widgets`.

If signing material must be recreated:

```sh
umask 077
fastlane cert \
  --development false \
  --api_key_path ~/private_keys/asc-key-inline.json \
  --team_id 4KBWH9KYSD \
  --output_path ~/private_keys/vigil-signing/certs

fastlane sigh \
  --app_identifier app.vigil.app \
  --provisioning_name "Vigil AppStore" \
  --api_key_path ~/private_keys/asc-key-inline.json \
  --team_id 4KBWH9KYSD \
  --output_path ~/private_keys/vigil-signing/profiles

fastlane sigh \
  --app_identifier app.vigil.app.widgets \
  --provisioning_name "VigilWidgets AppStore" \
  --api_key_path ~/private_keys/asc-key-inline.json \
  --team_id 4KBWH9KYSD \
  --output_path ~/private_keys/vigil-signing/profiles
```

Use `0700` directories and `0600` files for local signing backups.

## Preflight

1. Confirm the working tree contains only intended release changes.
2. Confirm `MARKETING_VERSION: 0.14.0` and `CURRENT_PROJECT_VERSION: 15` in `apps/apple/project.yml`.
3. Confirm no signing secret is tracked.
4. Run the full local gate.

```sh
swift test --package-path packages/VigilKit

cd apps/apple
xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
test -n "$DEVICE_UDID"
echo "Testing on simulator: $DEVICE_UDID"
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

## Archive and upload 0.14.0 (15)

```sh
cd apps/apple

VIGIL_RELEASE_VERSION=0.14.0
VIGIL_RELEASE_BUILD=15
VIGIL_ARCHIVE_PATH="build/Vigil-0.14.0-15.xcarchive"
VIGIL_EXPORT_PATH="build/export-0.14.0-15"
VIGIL_ASC_KEY_PATH="$HOME/private_keys/AuthKey_YOUR_KEY_ID.p8"
VIGIL_ASC_KEY_ID="YOUR_KEY_ID"
VIGIL_ASC_ISSUER_ID="YOUR_ISSUER_ID"

test ! -e "$VIGIL_ARCHIVE_PATH"
test ! -e "$VIGIL_EXPORT_PATH"

xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS' \
  archive \
  -archivePath "$VIGIL_ARCHIVE_PATH"

test "$(/usr/libexec/PlistBuddy \
  -c 'Print:ApplicationProperties:CFBundleShortVersionString' \
  "$VIGIL_ARCHIVE_PATH/Info.plist")" = "$VIGIL_RELEASE_VERSION"

test "$(/usr/libexec/PlistBuddy \
  -c 'Print:ApplicationProperties:CFBundleVersion' \
  "$VIGIL_ARCHIVE_PATH/Info.plist")" = "$VIGIL_RELEASE_BUILD"

codesign --verify --deep --strict \
  "$VIGIL_ARCHIVE_PATH/Products/Applications/Vigil.app"

env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  xcodebuild -exportArchive \
  -archivePath "$VIGIL_ARCHIVE_PATH" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$VIGIL_EXPORT_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$VIGIL_ASC_KEY_PATH" \
  -authenticationKeyID "$VIGIL_ASC_KEY_ID" \
  -authenticationKeyIssuerID "$VIGIL_ASC_ISSUER_ID"
```

Never reuse an archive or export directory from an earlier build. A build-number collision must fail.

`Uploaded package is processing.` means Apple accepted the upload. Processing usually takes 5 to 30 minutes. `ITSAppUsesNonExemptEncryption: false` answers the export-compliance question for this app.

## Retire the legacy npm artifact

This one-time step requires an authenticated npm account that owns `vigil-link`:

```sh
npm deprecate vigil-link "vigil-link is retired. Vigil is now iOS-only and sets up entirely on the phone. Sign in to Claude and ChatGPT/Codex in the app, or paste a provider key. No CLI is needed."
npm view vigil-link version deprecated
```

Do not describe the npm artifact as deprecated until the second command returns the retirement message.

## Release verification

After processing:

1. Confirm version 0.14.0 and build 15 in App Store Connect.
2. Confirm the build entered the Internal group.
3. Install it from TestFlight on a clean device or after removing the prior build.
4. Add Claude through phone-native browser approval.
5. Add Codex through device authorization.
6. Add one pasted-key provider.
7. Confirm Home shows plan-wide windows and Models shows only genuine model lanes.
8. Confirm stale, rate-limit, and provider-drift states do not display as Live.
9. Confirm app and widget share the selected account and poll ledger.
10. Confirm account removal deletes the credential and local observations.

## Known release gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `Your team has no devices from which to generate a provisioning profile` | Automatic development signing needs a registered device | Use the committed manual distribution settings or register a device |
| `conflicting provisioning settings` | A code-sign identity was forced while style remained Automatic | Keep manual settings scoped to `[sdk=iphoneos*]` |
| `exportArchive Copy failed` with rsync option errors | Homebrew rsync shadowed the system tool | Sanitize `PATH` during export |
| Upload rejects missing orientations | Required orientation keys are absent | Keep all iPhone and iPad orientations in `project.yml` |
| CI cannot open project format 77 | Runner Xcode is too old for current XcodeGen output | Use `macos-15` or later |
| Fastlane command returns session or retired-endpoint errors | Some commands require interactive session authentication | Use `cert` and `sigh` only; manage the app record in App Store Connect |

## External TestFlight and App Store

External distribution still requires current screenshots, listing copy, Beta App Review details, and final privacy answers. The intended privacy label is **Data Not Collected**, supported by each target's `PrivacyInfo.xcprivacy` and the direct-to-provider architecture.

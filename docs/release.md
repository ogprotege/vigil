# Release runbook — TestFlight / App Store

How a Vigil iOS build gets from this repo to TestFlight. First executed
2026-07-18 (build 0.9.0 (1)); every gotcha below was hit live.

## One-time setup (already done for this team)

- **Team:** `4KBWH9KYSD` (Apple Developer Program, Individual).
- **App Store Connect API key** (role: Admin) lives at
  `~/private_keys/AuthKey_<KEYID>.p8` on the release machine, with a
  fastlane-format JSON (key id, issuer id, inline key) at
  `~/private_keys/asc-key-inline.json`. Neither is in the repo — find the key
  id and issuer id in App Store Connect → Users and Access → Integrations.
- **Identifiers:** `app.vigil.app` (app), `app.vigil.app.widgets` (widget
  extension), app group `group.app.vigil.shared` — all registered under the
  team, App Groups capability assigned on both bundle ids.
- **Signing (manual, deliberately):** the team has no registered devices, so
  automatic *development* signing cannot mint profiles. Device/App Store
  builds use manual distribution signing — an Apple Distribution certificate
  plus the profiles **"Vigil AppStore"** and **"VigilWidgets AppStore"**,
  wired into `apps/apple/project.yml` under `[sdk=iphoneos*]` settings so
  simulator and macOS builds stay signing-free.

  **Signing material never lives under the repo tree.** The exported
  certificate (`.p12`), CSR, and profile files live in
  `~/private_keys/vigil-signing/` (`0700` directories, `0600` files) — a repo
  checkout must stay safe to tar, back up, or `git add -f` without carrying a
  distribution private key. The build itself only needs the cert in the login
  keychain and the profiles installed under
  `~/Library/MobileDevice/Provisioning Profiles/` (fastlane installs them);
  the files on disk are backups. Recreate them any time with (the `umask` and
  output paths are load-bearing — without them fastlane drops world-readable
  keys into the current directory):

  ```sh
  umask 077
  fastlane cert --development false --api_key_path ~/private_keys/asc-key-inline.json --team_id 4KBWH9KYSD --output_path ~/private_keys/vigil-signing/certs
  fastlane sigh --app_identifier app.vigil.app         --provisioning_name "Vigil AppStore"        --api_key_path ~/private_keys/asc-key-inline.json --team_id 4KBWH9KYSD --output_path ~/private_keys/vigil-signing/profiles
  fastlane sigh --app_identifier app.vigil.app.widgets --provisioning_name "VigilWidgets AppStore" --api_key_path ~/private_keys/asc-key-inline.json --team_id 4KBWH9KYSD --output_path ~/private_keys/vigil-signing/profiles
  ```

- **App Store Connect record:** "Vigil — AI Usage Monitor", App ID
  `6792373775`, SKU `vigil-001`, bundle `app.vigil.app`. TestFlight internal
  group **Internal** has automatic build distribution enabled. (App records
  cannot be created via the public API — that one step is UI-only.)

## Cutting a build

```sh
cd apps/apple

# 1. Bump the version/build in project.yml if needed:
#    MARKETING_VERSION (user-facing) / CURRENT_PROJECT_VERSION (build number).
#    ExportOptions.plist sets manageAppVersionAndBuildNumber, so Apple will
#    auto-bump colliding build numbers on upload.

# 2. Generate + archive (manual distribution signing from project.yml):
xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS' archive -archivePath build/Vigil.xcarchive

# 3. Export + upload. PATH is sanitized because Xcode's IPA step spawns a
#    server-side rsync via PATH, and Homebrew's rsync 3.4.4 rejects Apple's
#    flags ("Copy failed"). The API key authenticates the upload.
env PATH="/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild -exportArchive \
  -archivePath build/Vigil.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/private_keys/AuthKey_<KEYID>.p8 \
  -authenticationKeyID <KEYID> \
  -authenticationKeyIssuerID <ISSUER_ID>
```

"Uploaded package is processing." means Apple has it. Processing takes
5–30 min; because the Info.plist carries
`ITSAppUsesNonExemptEncryption: false`, the export-compliance question is
auto-answered and the build lands directly in the Internal group, ready to
install from the TestFlight app.

## Gotchas (all hit live on 2026-07-18)

| Symptom | Cause | Fix |
|---|---|---|
| `Your team has no devices from which to generate a provisioning profile` | Automatic dev signing needs ≥1 registered device | Manual distribution signing (above) — or register a device |
| `conflicting provisioning settings` | `CODE_SIGN_IDENTITY` forced while style is Automatic | Use the committed `[sdk=iphoneos*]` manual-signing settings |
| `exportArchive Copy failed` + rsync `--extended-attributes: unknown option` | Homebrew rsync shadows the system one for Xcode's spawned rsync server | Sanitize `PATH` for the export step |
| Upload rejected: `No orientations were specified` | Missing `UISupportedInterfaceOrientations` | Declared (all four, iPhone + iPad) in `project.yml` |
| CI: `future Xcode project file format (77)` | XcodeGen ≥ 2.46 emits Xcode 16 format; macos-14 tops out at 15.4 | `apple.yml` runs on `macos-15` |
| `produce`/`pilot` auth or 410 errors | Some fastlane commands need session auth or hit retired endpoints | Only `cert`/`sigh` are needed; do ASC-record work in the browser |

## Not yet wired

- **macOS distribution** (menu bar build is source-only): add the macOS
  platform to the same ASC app record, sign with Developer ID or App Store
  signing, upload the same way.
- **External TestFlight / App Store review:** needs screenshots, description,
  and Beta App Review — the privacy label is "Data Not Collected"
  (`PrivacyInfo.xcprivacy` substantiates it).

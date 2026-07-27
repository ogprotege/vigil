# iOS release runbook

This is the authoritative procedure for creating and delivering a Vigil iOS
release. It covers the app and widget extension. Vigil has no desktop or CLI
release.

> Status: current
>
> Last reviewed: 2026-07-26
>
> Review again: after any signing, CI, archive, upload, or App Store Connect change

The procedure is fail-closed. A missing check, stale archive, unresolved CI
failure, or unclear approval stops the release. Do not substitute an earlier
archive because its version and build happen to match.

## Release identities

These product identifiers are stable:

| Item | Value |
|---|---|
| App Store Connect app | Vigil - AI Usage Monitor |
| Apple ID | `6792373775` |
| Team ID | `4KBWH9KYSD` |
| App bundle ID | `app.vigil.app` |
| Widget bundle ID | `app.vigil.app.widgets` |
| App Group | `group.app.vigil.shared` |
| Internal TestFlight group | `Internal` |

The release version, build, commit, and simulator change between releases.
Declare them explicitly in a clean shell:

```zsh
set -euo pipefail

VIGIL_VERSION="${VIGIL_VERSION:?set the marketing version, for example 0.15.0}"
VIGIL_BUILD="${VIGIL_BUILD:?set the build number, for example 16}"
VIGIL_RELEASE_COMMIT="${VIGIL_RELEASE_COMMIT:?set the full 40-character Git commit}"
VIGIL_SIMULATOR_ID="${VIGIL_SIMULATOR_ID:?set the validated iPhone simulator UDID}"

VIGIL_REPO_ROOT="$(git rev-parse --show-toplevel)"
VIGIL_REPO_ROOT="$(CDPATH= cd -- "$VIGIL_REPO_ROOT" && pwd -P)"
VIGIL_SHORT_COMMIT="${VIGIL_RELEASE_COMMIT[1,12]}"
VIGIL_RELEASE_ROOT="$VIGIL_REPO_ROOT/apps/apple/build/releases/$VIGIL_VERSION-$VIGIL_BUILD-$VIGIL_SHORT_COMMIT"
VIGIL_DERIVED_PATH="$VIGIL_RELEASE_ROOT/DerivedData"
VIGIL_ARCHIVE_PATH="$VIGIL_RELEASE_ROOT/Vigil-$VIGIL_VERSION-$VIGIL_BUILD-$VIGIL_SHORT_COMMIT.xcarchive"
VIGIL_RESULT_PATH="$VIGIL_RELEASE_ROOT/Vigil-$VIGIL_VERSION-$VIGIL_BUILD-tests.xcresult"
VIGIL_EXPORT_PATH="$VIGIL_RELEASE_ROOT/upload"
```

Use the same shell for every later command. Each section repeats critical
assertions so a partially copied procedure fails.

## 1. Establish the exact candidate

Fetch the remote state. Then bind the release to one clean commit.

```zsh
cd "$VIGIL_REPO_ROOT"
git fetch --prune origin

test "${#VIGIL_RELEASE_COMMIT}" -eq 40
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
git merge-base --is-ancestor "$VIGIL_RELEASE_COMMIT" origin/main
test -z "$(git status --porcelain=v1 --untracked-files=all)"
git diff --check "$VIGIL_RELEASE_COMMIT^" "$VIGIL_RELEASE_COMMIT"
test -z "$(git ls-files | rg '\.(p8|p12|mobileprovision)$')"
```

Record the full artifact commit in `docs/releases/<version>-<build>.md`. If app
code, configuration, tests, canonical procedures, or user-facing claims change
later, select a new artifact commit and begin again. A previously created
archive becomes stale immediately.

An evidence-only follow-up may update `docs/releases/` or `dev/releases/` after
a gate runs. It does not change the artifact commit when it only records exact
results and changes no product, test, configuration, or canonical procedure.
The evidence commit must name the artifact commit it describes.

## 2. Validate local signing material

Archive creation uses the installed distribution identity and profiles. It
does not require the App Store Connect API key used for upload. Keep upload
credentials out of the shell until the explicit approval gate has passed.

Required installed distribution profiles are:

- `Vigil AppStore` for `app.vigil.app`;
- `VigilWidgets AppStore` for `app.vigil.app.widgets`.

The committed project uses manual distribution signing for device archives.
Do not add `-allowProvisioningUpdates` to the archive or upload commands. A
missing or expired profile is a signing repair task, not permission to let the
release command change signing state.

Before spending a build number, complete two external preflight checks:

1. Confirm [Apple Developer System Status](https://developer.apple.com/system-status/)
   and [Apple System Status](https://www.apple.com/support/systemstatus/) show no
   relevant App Store Connect, TestFlight, or developer-service outage. Pause
   the release if status is degraded or cannot be confirmed.
2. In App Store Connect, open Apple ID `6792373775` and confirm that the declared
   version and build do not already exist, including uploaded, processing,
   invalid, expired, or distributed records. Build numbers cannot be reused.

Record the check time and result in the release record. Repeat both checks
immediately before upload because external state can change after archiving.

## 3. Verify version and build settings

Create a new release directory and generated project. Resolve build settings
from Xcode instead of trusting a prose release note.

```zsh
cd "$VIGIL_REPO_ROOT"
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test ! -e "$VIGIL_RELEASE_ROOT"

umask 077
mkdir -p "$VIGIL_RELEASE_ROOT"
xcodegen generate --spec apps/apple/project.yml
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

xcodebuild \
  -project apps/apple/Vigil.xcodeproj \
  -scheme Vigil \
  -configuration Release \
  -showBuildSettings \
  -json > "$VIGIL_RELEASE_ROOT/build-settings.json"

test "$(plutil -extract 0.buildSettings.MARKETING_VERSION raw -o - "$VIGIL_RELEASE_ROOT/build-settings.json")" = "$VIGIL_VERSION"
test "$(plutil -extract 0.buildSettings.CURRENT_PROJECT_VERSION raw -o - "$VIGIL_RELEASE_ROOT/build-settings.json")" = "$VIGIL_BUILD"
test "$(plutil -extract 0.buildSettings.VALIDATE_PRODUCT raw -o - "$VIGIL_RELEASE_ROOT/build-settings.json")" = YES
```

If `xcodegen generate` changes a tracked file, stop. The project manifest is the
source of truth and generated project output must not create an unreviewed
candidate.

## 4. Run the local gate

Use a named simulator UDID that has already been checked for the intended iOS
runtime. Do not select the first simulator returned by `simctl`.

```zsh
cd "$VIGIL_REPO_ROOT"
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test ! -e "$VIGIL_RESULT_PATH"

swift test --package-path packages/VigilKit

xcodebuild \
  -project apps/apple/Vigil.xcodeproj \
  -scheme Vigil \
  -destination "platform=iOS Simulator,id=$VIGIL_SIMULATOR_ID" \
  -resultBundlePath "$VIGIL_RESULT_PATH" \
  test CODE_SIGNING_ALLOWED=NO

xcrun xcresulttool get test-results summary \
  --path "$VIGIL_RESULT_PATH" \
  --compact

plutil -lint \
  apps/apple/Vigil/Info.plist \
  apps/apple/VigilWidgets/Info.plist \
  apps/apple/Vigil/Resources/PrivacyInfo.xcprivacy \
  apps/apple/VigilWidgets/PrivacyInfo.xcprivacy \
  apps/apple/Entitlements/Vigil-iOS.entitlements \
  apps/apple/Entitlements/VigilWidgets.entitlements
```

Record the simulator model, iOS runtime, counts, skips, failures, and result
bundle path in the release record. A passing run on one runtime does not erase
a failing required CI run on another runtime.

## 5. Require green CI for the same commit

The release commit must have at least one reported check, and every reported
check must be complete and successful. This gate treats missing, pending,
cancelled, neutral, skipped, timed-out, and failed checks as blocking.

```zsh
cd "$VIGIL_REPO_ROOT"
VIGIL_CHECKS_PATH="$VIGIL_RELEASE_ROOT/github-checks.json"

gh api \
  -H 'Accept: application/vnd.github+json' \
  "repos/ogprotege/vigil/commits/$VIGIL_RELEASE_COMMIT/check-runs?per_page=100" \
  > "$VIGIL_CHECKS_PATH"

test "$(plutil -extract total_count raw -o - "$VIGIL_CHECKS_PATH")" -gt 0
test "$(plutil -extract total_count raw -o - "$VIGIL_CHECKS_PATH")" -le 100
test "$(jq '[.check_runs[] | select(.status != "completed" or .conclusion != "success")] | length' "$VIGIL_CHECKS_PATH")" -eq 0
```

Do not archive while this gate fails. Fix the code or the test, create a new
commit, rerun local validation, and wait for CI on that new commit.

## 6. Create a new signed archive

The archive path contains the exact commit prefix. Existing output is a hard
failure. Never overwrite or silently reuse a same-version archive.

```zsh
cd "$VIGIL_REPO_ROOT"
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test ! -e "$VIGIL_ARCHIVE_PATH"
test ! -e "$VIGIL_DERIVED_PATH"

umask 077
xcodebuild \
  -project apps/apple/Vigil.xcodeproj \
  -scheme Vigil \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$VIGIL_DERIVED_PATH" \
  -archivePath "$VIGIL_ARCHIVE_PATH" \
  VALIDATE_PRODUCT=YES \
  clean archive
```

The clean working tree and exact `HEAD` assertion bind the archive operation to
the declared source commit. Xcode does not place the Git commit in the archive,
so the release record must preserve this evidence.

## 7. Verify the archive

```zsh
cd "$VIGIL_REPO_ROOT"
test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -d "$VIGIL_ARCHIVE_PATH"

scripts/verify-ios-archive.sh \
  "$VIGIL_ARCHIVE_PATH" \
  "$VIGIL_VERSION" \
  "$VIGIL_BUILD"
```

The verifier checks the archived app and widget for:

- version, build, bundle IDs, team, and `arm64` architecture;
- strict code-signature validity;
- signed App Group and Keychain entitlements;
- distribution profiles, profile names, expiration, and beta entitlement;
- privacy manifests, no declared tracking or collected data, and required
  reason codes;
- the encryption declaration;
- app and widget dSYM UUID matches.

This verification stops at the signed `.xcarchive`. It does not verify an
exported IPA, App Store Connect processing, Apple's server-side transformations,
TestFlight group assignment, installation, or physical-device behavior. The
committed `ExportOptions.plist` uses `destination=upload`, so the later
`-exportArchive` command uploads directly and may not leave a local IPA to
inspect. Post-upload processing checks and a TestFlight installation are
therefore mandatory.

Update the release record with the archive path, creation time, exact commit,
and verifier result. Then stop.

## 8. Explicit approval gate

Archive creation and verification are local actions. Upload and TestFlight
distribution are external mutations. They require a fresh approval after the
exact archive passes every earlier gate.

Present this sentence with real values:

> Approve App `6792373775`, version `<version>`, build `<build>`, from commit
> `<full commit>`, for upload and distribution to Internal TestFlight.

Do not infer approval from a request to prepare, archive, verify, fix CI, or
open a pull request. If the version, build, commit, archive, destination, or
group changes, request approval again.

## 9. Upload only after approval

The next command crosses the upload boundary. Confirm the committed export
options before running it. Use one credential directory. Do not split API keys
and signing backups across several home-directory paths. The directory must be
absolute, outside the repository, and owner-only. The `.p8` key must be a
direct child and readable only by its owner.

Immediately before running the block, repeat the Apple status and build-
collision checks from step 2. Stop if either result changed or cannot be
confirmed.

```zsh
cd "$VIGIL_REPO_ROOT"
VIGIL_KEY_DIR="${VIGIL_KEY_DIR:?set one absolute credential directory outside the repository}"
VIGIL_ASC_KEY_ID="${VIGIL_ASC_KEY_ID:?set the App Store Connect API key ID}"
VIGIL_ASC_ISSUER_ID="${VIGIL_ASC_ISSUER_ID:?set the App Store Connect issuer ID}"

test "${VIGIL_KEY_DIR#/}" != "$VIGIL_KEY_DIR"
test -d "$VIGIL_KEY_DIR"
test ! -L "$VIGIL_KEY_DIR"
VIGIL_KEY_DIR_REAL="$(CDPATH= cd -- "$VIGIL_KEY_DIR" && pwd -P)"
test "$VIGIL_KEY_DIR" = "$VIGIL_KEY_DIR_REAL"
VIGIL_ASC_KEY_PATH="$VIGIL_KEY_DIR_REAL/AuthKey_$VIGIL_ASC_KEY_ID.p8"

case "$VIGIL_KEY_DIR_REAL/" in
  "$VIGIL_REPO_ROOT/"*)
    print -u2 "credential directory must be outside the repository"
    false
    ;;
esac

test "$(git rev-parse HEAD)" = "$VIGIL_RELEASE_COMMIT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test -d "$VIGIL_ARCHIVE_PATH"
test ! -e "$VIGIL_EXPORT_PATH"
test "$(stat -f '%Lp' "$VIGIL_KEY_DIR_REAL")" = 700
test -f "$VIGIL_ASC_KEY_PATH"
test ! -L "$VIGIL_ASC_KEY_PATH"
test "$(stat -f '%Lp' "$VIGIL_ASC_KEY_PATH")" = 600
test "$(plutil -extract destination raw -o - apps/apple/ExportOptions.plist)" = upload
test "$(plutil -extract method raw -o - apps/apple/ExportOptions.plist)" = app-store-connect
test "$(plutil -extract manageAppVersionAndBuildNumber raw -o - apps/apple/ExportOptions.plist)" = false
test "$(plutil -extract signingStyle raw -o - apps/apple/ExportOptions.plist)" = manual
test "$(plutil -extract teamID raw -o - apps/apple/ExportOptions.plist)" = 4KBWH9KYSD
test "$(plutil -extract provisioningProfiles.app\\.vigil\\.app raw -o - apps/apple/ExportOptions.plist)" = 'Vigil AppStore'
test "$(plutil -extract provisioningProfiles.app\\.vigil\\.app\\.widgets raw -o - apps/apple/ExportOptions.plist)" = 'VigilWidgets AppStore'

scripts/verify-ios-archive.sh \
  "$VIGIL_ARCHIVE_PATH" \
  "$VIGIL_VERSION" \
  "$VIGIL_BUILD"

env PATH='/usr/bin:/bin:/usr/sbin:/sbin' \
  xcodebuild -exportArchive \
  -archivePath "$VIGIL_ARCHIVE_PATH" \
  -exportOptionsPlist apps/apple/ExportOptions.plist \
  -exportPath "$VIGIL_EXPORT_PATH" \
  -authenticationKeyPath "$VIGIL_ASC_KEY_PATH" \
  -authenticationKeyID "$VIGIL_ASC_KEY_ID" \
  -authenticationKeyIssuerID "$VIGIL_ASC_ISSUER_ID"
```

There is intentionally no `-allowProvisioningUpdates`. If export cannot use
the verified signing state, stop and repair signing separately.

The second archive-verifier pass prevents a changed archive from crossing the
approval boundary unnoticed.

`Uploaded package is processing` means Apple accepted the upload transport. It
does not mean processing passed or Internal TestFlight distribution completed.

## 10. Verify processing and Internal distribution

Use App Store Connect to bind every observation to Apple ID `6792373775`, the
declared version, and the declared build.

1. Wait until processing finishes successfully.
2. Confirm the displayed version and build match the release record.
3. Review export compliance and any processing warnings.
4. Confirm the build is assigned to the `Internal` TestFlight group. Automatic
   distribution is configured, but the release is incomplete until verified.
5. Record processing and distribution timestamps in the release record.
6. If Apple rejects processing or reports a different identity, stop. Do not
   upload another binary with the same build number.

## 11. Test the delivered build

Install the processed build from TestFlight on a physical iPhone. At minimum:

1. Complete clean first launch.
2. Link Claude through the phone-native flow.
3. Link ChatGPT/Codex through device authorization.
4. Add one pasted-key provider.
5. Confirm Home urgency order and complete account-detail windows.
6. Confirm observed history persists across app and widget readings.
7. Confirm provider imports are labeled separately from observed history.
8. Confirm credentials never appear in diagnostics.
9. Confirm app lock, privacy cover, notifications, App Group sharing, and
   widget reconciliation.
10. Remove an account during active refresh work and confirm it does not return.
11. On a disposable install, run the confirmed full local reset and confirm
    accounts, credentials, history, widget state, and Vigil notifications are
    gone.

Provider endpoints and iOS scheduling remain external dependencies. Record any
unperformed live check instead of converting it into a pass.

## Failure rules

- Never reuse a stale archive.
- Never overwrite an archive, result bundle, derived-data directory, or upload
  directory.
- Never release from a dirty tree or an unrecorded commit.
- Never treat a local pass as a replacement for required CI.
- Never treat upload acceptance as processing or distribution success.
- Never upload without approval for the exact app, version, build, commit, and
  destination.
- Never place signing credentials, provider credentials, raw provider bodies,
  or diagnostic exports in Git.

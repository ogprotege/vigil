#!/bin/zsh

set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 <archive-path> <marketing-version> <build-number>"
  exit 64
fi

archive_path=$1
release_version=$2
release_build=$3
team_id=4KBWH9KYSD
app_path="$archive_path/Products/Applications/Vigil.app"
widget_path="$app_path/PlugIns/VigilWidgets.appex"

plist_value() {
  plutil -extract "$2" raw -o - "$1"
}

signed_value() {
  codesign -d --entitlements :- "$1" 2>/dev/null |
    plutil -extract "$2" raw -o - -
}

profile_value() {
  security cms -D -i "$1" |
    plutil -extract "$2" raw -o - -
}

expect_equal() {
  if [[ "$1" != "$2" ]]; then
    print -u2 "Expected '$2', got '$1'"
    return 1
  fi
}

expect_privacy_reason() {
  local manifest=$1
  local reason=$2
  plutil -convert json -o - "$manifest" | grep -Fq "\"$reason\""
}

[[ -d "$archive_path" ]]
[[ -d "$app_path" ]]
[[ -d "$widget_path" ]]

expect_equal \
  "$(plist_value "$archive_path/Info.plist" ApplicationProperties.CFBundleShortVersionString)" \
  "$release_version"
expect_equal \
  "$(plist_value "$archive_path/Info.plist" ApplicationProperties.CFBundleVersion)" \
  "$release_build"
expect_equal \
  "$(plist_value "$archive_path/Info.plist" ApplicationProperties.CFBundleIdentifier)" \
  app.vigil.app
expect_equal \
  "$(plist_value "$archive_path/Info.plist" ApplicationProperties.Team)" \
  "$team_id"
expect_equal \
  "$(plist_value "$archive_path/Info.plist" ApplicationProperties.Architectures.0)" \
  arm64

expect_equal "$(lipo -archs "$app_path/Vigil")" arm64
expect_equal "$(lipo -archs "$widget_path/VigilWidgets")" arm64

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$widget_path"

for bundle_path in "$app_path" "$widget_path"; do
  privacy_manifest="$bundle_path/PrivacyInfo.xcprivacy"
  plutil -lint "$bundle_path/Info.plist" "$privacy_manifest"

  expect_equal \
    "$(plist_value "$bundle_path/Info.plist" CFBundleShortVersionString)" \
    "$release_version"
  expect_equal \
    "$(plist_value "$bundle_path/Info.plist" CFBundleVersion)" \
    "$release_build"
  expect_equal \
    "$(plist_value "$bundle_path/Info.plist" VigilKeychainAccessGroup)" \
    "$team_id.app.vigil.shared"
  expect_equal \
    "$(signed_value "$bundle_path" 'com\.apple\.developer\.team-identifier')" \
    "$team_id"
  expect_equal \
    "$(signed_value "$bundle_path" 'com\.apple\.security\.application-groups.0')" \
    group.app.vigil.shared
  expect_equal \
    "$(signed_value "$bundle_path" 'keychain-access-groups.0')" \
    "$team_id.app.vigil.shared"
  expect_equal \
    "$(signed_value "$bundle_path" get-task-allow)" \
    false
  expect_equal \
    "$(plist_value "$privacy_manifest" NSPrivacyTracking)" \
    false
  expect_equal \
    "$(plist_value "$privacy_manifest" NSPrivacyCollectedDataTypes)" \
    0
  expect_privacy_reason "$privacy_manifest" CA92.1
  expect_privacy_reason "$privacy_manifest" C617.1
done

expect_equal \
  "$(plist_value "$app_path/Info.plist" CFBundleIdentifier)" \
  app.vigil.app
expect_equal \
  "$(plist_value "$app_path/Info.plist" ITSAppUsesNonExemptEncryption)" \
  false
expect_equal \
  "$(signed_value "$app_path" application-identifier)" \
  "$team_id.app.vigil.app"

expect_equal \
  "$(plist_value "$widget_path/Info.plist" CFBundleIdentifier)" \
  app.vigil.app.widgets
expect_equal \
  "$(plist_value "$widget_path/Info.plist" NSExtension.NSExtensionPointIdentifier)" \
  com.apple.widgetkit-extension
expect_equal \
  "$(signed_value "$widget_path" application-identifier)" \
  "$team_id.app.vigil.app.widgets"

for bundle_path in "$app_path" "$widget_path"; do
  profile_path="$bundle_path/embedded.mobileprovision"
  expect_equal \
    "$(profile_value "$profile_path" 'Entitlements.com\.apple\.security\.application-groups.0')" \
    group.app.vigil.shared
  expect_equal \
    "$(profile_value "$profile_path" Entitlements.get-task-allow)" \
    false
  expect_equal \
    "$(profile_value "$profile_path" Entitlements.beta-reports-active)" \
    true

  expiration="$(profile_value "$profile_path" ExpirationDate)"
  [[ "$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s')" -gt "$(date '+%s')" ]]
done

expect_equal \
  "$(profile_value "$app_path/embedded.mobileprovision" Name)" \
  "Vigil AppStore"
expect_equal \
  "$(profile_value "$app_path/embedded.mobileprovision" Entitlements.application-identifier)" \
  "$team_id.app.vigil.app"
expect_equal \
  "$(profile_value "$widget_path/embedded.mobileprovision" Name)" \
  "VigilWidgets AppStore"
expect_equal \
  "$(profile_value "$widget_path/embedded.mobileprovision" Entitlements.application-identifier)" \
  "$team_id.app.vigil.app.widgets"

expect_equal \
  "$(xcrun dwarfdump --uuid "$app_path/Vigil" | awk '{print $2}')" \
  "$(xcrun dwarfdump --uuid "$archive_path/dSYMs/Vigil.app.dSYM" | awk '{print $2}')"
expect_equal \
  "$(xcrun dwarfdump --uuid "$widget_path/VigilWidgets" | awk '{print $2}')" \
  "$(xcrun dwarfdump --uuid "$archive_path/dSYMs/VigilWidgets.appex.dSYM" | awk '{print $2}')"

print "Archive verification passed for Vigil $release_version ($release_build)."

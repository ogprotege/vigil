# Vigil 1.0 public-release code review

Last Updated: 2026-08-09

## Executive Summary

The settings and Liquid Glass implementation fits Vigil's existing architecture:
preferences remain in the Apple presentation layer, the app and widget share only
non-sensitive values through App Group `UserDefaults`, VigilKit remains UI-free,
provider cooldown and lifecycle safeguards remain authoritative, and the original
dark palette is preserved beside System and Light choices.

No critical architecture or data-safety defect was found. The functional alert
edge case, verification gap, background-task hardening, and portable screenshot
configuration identified by this review were approved and resolved. The complete
local scheme now passes 177/177 tests, VigilKit passes 206 tests with two
explicitly opt-in live tests skipped, and fresh generic Debug and unsigned
Release simulator builds pass.

## Critical Issues (must fix)

None found.

## Important Improvements (should fix)

### 1. Resolved — enabling alerts later requests notification authorization

`AppModel.preferencesDidChange()` removes notifications when alerts are disabled,
but does not call `requestAuthorizationIfNeeded()` when alerts become enabled.
Authorization is currently requested while saving an account only when alerts are
already enabled. A user who disables alerts before linking, links an account, and
then enables alerts can therefore reach a threshold without ever seeing the iOS
permission request.

Resolution: the usage-alert change path is now explicit. Enabling requests
authorization; disabling removes owned notifications and consumes pending events.
The recording notification manager proves that presentation changes do not prompt
and enabling alerts does. The focused and complete suites pass.

### 2. Resolved — the pause promise has a provider-request behavior test

The implementation guards automatic `refreshAll` calls and widget fetches, and
manual refresh passes `bypassPollFloor: true`. Current new tests verify preference
persistence and the paused report message, but do not prove that an automatic
refresh makes zero provider requests while a manual refresh remains available.

Resolution: a deterministic AppModel test now proves the paused automatic path
issues zero requests while a user pull still performs a successful provider fetch
and persists the resulting observation.

## Minor Suggestions (nice to have)

### Resolved — stop renewing an already-scheduled background task while paused

`VigilApp` avoids scheduling new background work when the app enters the
background while paused, and `refreshAll` prevents a provider request. However,
an older scheduled `BGAppRefreshTask` previously renewed a chain of no-op tasks.
The handler now checks the App Group preference before continuing that chain. It
still completes the already-delivered task without making a provider request.

### Resolved — screenshot automation configuration is portable

`.asc/screenshots.json` and `.asc/shots.settings.json` now use `"booted"` instead
of one machine's simulator UDID. A specific device remains selectable through
the command-line `--udid` override without editing tracked files.

### Add a focused widget-privacy presentation test when a stable seam exists

The widget privacy branch compiles and was inspected, but the current automated
suite does not directly assert the hidden small/circular widget copy. A future
snapshot or view-model test would guard against numeric values returning to the
privacy state.

## Architecture Considerations

- `VigilPreferences` is correctly owned by the app/widget layer and does not
  introduce UI state into VigilKit.
- App Group defaults contain preferences only; credentials remain in the shared
  ThisDeviceOnly Keychain and usage data remains in existing protected stores.
- Automatic checks still pass through the existing durable scheduler, and the
  pause only subtracts work; it does not shorten cooldowns or bypass backoff.
- Alert disabling handles durable pending events instead of leaving surprise
  notifications for later re-enablement.
- Native navigation and toolbar chrome is system-owned, which is the appropriate
  forward-compatible Liquid Glass adoption. Opaque usage cards retain contrast.
- Centralized privacy/support links and generic notification copy improve release
  maintainability without creating another network or data-collection boundary.
- App Store/provider-rights, public-URL, reviewer-access, China availability, and
  publication-toolchain blockers are release concerns tracked separately in
  `dev/releases/1.0.0-23/app-store-preflight.md`.

## Next Steps

1. Stage only the reviewed release candidate, excluding unrelated `.claude/` and
   `dev/active/suspension-guard-0xdead10cc/` files.
2. Push only after GitHub authentication is repaired, and require green GitHub CI
   before any signed archive or TestFlight action.

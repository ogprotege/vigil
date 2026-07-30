# Settings revamp design — Vigil 1.0.0

> Status: approved design, pre-implementation
>
> Last reviewed: 2026-07-30
>
> Review again: if any section changes during implementation planning

Approved by the repo owner on 2026-07-30 after a sectioned design review.
This spec defines the scope; the implementation plan sequences the work.

## Context and goal

Vigil's Settings page is functional but sparse: one Face ID toggle, privacy
and recovery actions, two static refresh rows (one stale — it still says
"5 min + jitter" after build 19 moved the floor to 60 seconds), and About.
The app is dark-only by construction: `VigilPalette` hardcodes a dark color
set and the root forces `.preferredColorScheme(.dark)`.

The revamp gives users the controls a mature app carries — appearance,
alerts, refresh behavior, accessibility, widget options — without weakening
any honesty invariant. The scale of the change (an app-wide theme system
plus user-facing behavior controls) graduates the version to **1.0.0**.

## Non-negotiable invariants

- No preference can shorten any polling interval. Pause flags only subtract
  work. The 60-second floor and 429 backoff are untouchable.
- Retained or paused data always ages visibly. Pausing polling never freezes
  the display of time.
- Status colors keep their meanings in both themes, and status is never
  encoded by hue alone (unconditional labels, see Accessibility).
- VigilKit stays UI-free and preference-free: the app passes preference
  values into kit APIs; the kit never reads defaults.
- Every behavioral default reproduces current shipped behavior, with three
  deliberate, named exceptions that are the point of the 1.0.0 graduation:
  appearance changes from pinned-dark to system-following, confirmation
  haptics are added (default on, with the off switch), and status labels
  beside colors appear unconditionally. Nothing else changes for a user who
  never opens Settings — alert levels, polling, staleness, and widget
  content all behave exactly as today.

## 1. Preferences store

`VigilPreferences`: an `@Observable` type in the app target, owned by
`AppModel` (the same exposure pattern as `lockEnabled`), persisting each
value to App Group `UserDefaults` (`group.app.vigil.shared`) under
namespaced keys. App Group placement is required because the widget (theme,
redaction) and the shared polling machinery (pause flags) live outside the
app process.

| Key | Type | Default | Consumer |
|---|---|---|---|
| `prefs.appearance` | `system` \| `light` \| `dark` | `system` | root scene, widget |
| `prefs.alertLevels` | `[Int]`, each 1–99, sorted unique | `[80, 95]` | `UsageService` → `ThresholdEngine` |
| `prefs.accountAlertOverrides` | `[accountKey: [Int]]` | `[:]` | `UsageService` per-account resolution |
| `prefs.pauseAllPolling` | Bool | `false` | scheduler, widget fetch path |
| `prefs.pausedAccountKeys` | [String] | `[]` | scheduler, widget fetch path |
| `prefs.staleAfterMinutes` | 15 \| 30 \| 60 | `30` | `SnapshotFreshness` (app target) |
| `prefs.reduceProminentAnimations` | Bool | `false` | dial/refresh animations |
| `prefs.hapticsEnabled` | Bool | `true` | confirmation haptics |
| `prefs.widgetRedactedWhenLocked` | Bool | `false` | widget rendering |
| `prefs.widgetsFollowThemeOverride` | Bool | `true` | widget rendering |

Rules: unknown or corrupt stored values fall back to defaults, never fail.
`lockEnabled` stays in standard `UserDefaults` — it is app-only state and
migration buys nothing.

## 2. Appearance system

- Every `VigilPalette` color becomes adaptive: a light/dark pair resolved
  through the SwiftUI environment. The dark half is today's values,
  bit-for-bit. The light half is designed at implementation time (with the
  ui-ux-pro-max design pass) and must hold WCAG AA contrast for all four
  status colors (`safe`, `caution`, `critical`, `signal`) against their
  surfaces — enforced by computed-contrast unit tests, not eyeballs.
- The root replaces the hardcoded `.preferredColorScheme(.dark)` with the
  preference: `nil` for System, `.light`/`.dark` for overrides.
- Widgets resolve the same adaptive colors and read the same App Group key,
  honoring `prefs.widgetsFollowThemeOverride`.
- Status colors keep their semantics and relative weights in both themes.

## 3. Alerts

Full user control, resolved per account. `UsageService` resolves each
account's effective levels and passes them into
`ThresholdEngine.crossings(_:thresholds:)`, whose parameter already exists;
VigilKit does not change.

- **Global levels**: the four familiar presets — 50, 80, 90, 95 percent —
  as toggles (defaults 80 and 95 on, today's behavior), plus **Add custom
  level**: a typed whole percentage from 1 to 99, validated on entry,
  stored sorted and deduplicated, deletable like any level. At most 8
  active levels total, so a misconfiguration cannot become notification
  spam.
- **Per-account overrides**: each linked account uses the global set unless
  overridden — an account can carry its own level set or be muted entirely
  (empty override). A missing entry means "use global." Removing an account
  removes its override.
- All levels off (globally or per account) is allowed and labeled plainly:
  "No usage alerts will fire."
- Changing levels never retracts delivered notifications and never fires
  retroactively; crossings are evaluated against the effective levels from
  the next comparison onward.

## 4. Refresh and pause

- **Pause all automatic checks** (global toggle) and **per-account pause**
  (compact account rows). Paused means no automatic polling — foreground
  timers, background tasks, and widget-initiated fetches all skip. Manual
  pull-to-refresh still works, and the setting's caption says so. Paused
  cards age visibly like any non-current reading.
- **Stale threshold**: 15 / 30 / 60 minutes, presentation-only, feeding the
  app-target `SnapshotFreshness`. Polling cadence untouched.
- **Corrected info rows**: "Provider minimum: 60 seconds + jitter",
  "Manual refresh: on demand, never interrupts an in-flight check",
  "Background checks: scheduled by iOS".
- **History retention made visible**: info rows stating the shipped
  retention — rolling 400-day archive, per-account caps of 120,000
  observations and 5,000 backfill records — so users can see that history
  and token totals are kept. Retention itself is unchanged by this revamp;
  a user-adjustable retention control would delete data when shortened and
  is deliberately a separate future design if ever wanted.

## 5. Accessibility

- **Status labels beside colors — unconditional, not a setting.** Status
  pills and dials gain a short text/symbol marker so status never depends
  on hue alone.
- **Reduce prominent animations**: system Reduce Motion is respected
  unconditionally; the in-app toggle additionally calms dial/refresh
  animations for users who do not use the system setting.
- **Haptics on/off** for the app's confirmation haptics.

## 6. Widget options

- **Redact widget when locked**: with app lock on, widgets show provider
  name and status without percentages.
- **Widgets follow theme override**: on by default; off means widgets
  always follow the system appearance.

## 6b. Liquid Glass adoption (iOS 26+)

Explicitly requested by the repo owner for the modern-OS wave. All Liquid
Glass APIs require iOS 26; Vigil's deployment target stays iOS 17, so every
adoption site is `#available(iOS 26, *)`-gated with the current flat
surfaces as the fallback — older devices see exactly today's design.

- Adoption surfaces, in order of value: card and inset surfaces
  (`vigilInsetSurface` and the card backgrounds), toolbars, and the linking
  overlay — using `glassEffect` and its container/button styles per the
  SwiftUI expert skill's Liquid Glass reference.
- The adaptive theme system (section 2) is a prerequisite: glass resolves
  over the theme's surfaces in both light and dark.
- Accessibility is non-negotiable: Reduce Transparency falls back to the
  opaque surfaces, and the WCAG contrast tests for status colors must pass
  over glass backgrounds too — if glass cannot hold contrast somewhere,
  that surface stays opaque.
- Verification note, recorded honestly: CI simulators run iOS 17.5, which
  exercises only the fallback path. Glass rendering is verified on an
  iOS 26 simulator or device and recorded in the release walk.

## 7. Page information architecture

Section order, most-touched first, keeping the existing card language and
Dynamic Type-adaptive rows:

1. Appearance — System / Light / Dark segmented control
2. Alerts — preset toggles, custom-level entry, per-account overrides,
   notification-privacy caption
3. Refresh — pause-all, per-account pause list, stale-threshold picker,
   corrected info rows, retention info rows
4. Security — existing Face ID toggle, unchanged
5. Accessibility — reduce prominent animations, haptics
6. Widgets — redact when locked, follow theme override
7. Privacy — existing rows, unchanged
8. About — existing rows

Every new control gets a `vigil.settings.*` accessibility identifier and a
pinned spoken surface.

## 8. Testing

- Store: defaults reproduce current behavior; corrupt values fall back;
  round-trips.
- Behaviors: per-account level resolution (global, override, muted,
  removed-account cleanup); custom-level validation (bounds, dedup, sort,
  the 8-level cap); pause skips automatic fetches but never manual pull;
  staleness parameterization. Red/green per behavior.
- Liquid Glass: the iOS 17 fallback path is exercised by the full CI suite;
  glass rendering and Reduce Transparency fallback are verified on an
  iOS 26 runtime and recorded.
- Theme: palette-resolution tests for both themes including computed WCAG
  contrast assertions for status colors on their surfaces.
- UI walks: Settings at default and accessibility-XXXL sizes; spoken labels
  for every new control; dialog actions via `presenting:` only.
- PR-0 (pre-existing fixes below) lands first with its own red/green tests.

## 9. Delivery

- **Version identity**: 1.0.0, build 22 (the global build counter stays
  monotonic; App Store Connect never reuses build numbers).
- **PR sequence**, one chunk per PR:
  - **PR-0 — SwiftUI sweep fixes** (pre-existing bugs, independent of the
    revamp): unstructured sign-in tasks that survive dismissal and can link
    a cancelled account (`CodexSignInView.swift`, `ClaudeSignInView.swift`);
    history rows whose accessibility label hides the reading
    (`ObservedHistorySection.swift`); the linking overlay's dropped spoken
    copy and missing modal trait (`AddAccountView.swift`); the circular
    widget's unlabeled unlinked fallback (`VigilWidgets.swift`).
  - **PR-1** — preferences store + appearance system (palette, root, widget
    theme).
  - **PR-2** — alerts (presets, custom levels, per-account overrides) +
    refresh/pause/staleness.
  - **PR-3** — accessibility extras + widget options.
  - **PR-4** — Settings page assembly + corrected info and retention rows.
  - **PR-5** — Liquid Glass adoption on iOS 26+ with fallback.
- Docs update in the same PR as each behavior change (maintenance rule):
  reading-limits staleness wording, product-contract freshness claims gain
  the configurability caveat, troubleshooting where states change.
- **Release**: 1.0.0 (22) through the standard runbook after all six PRs
  merge; the physical-device walk gains theme, pause, alert-level, and
  (on iOS 26 hardware) Liquid Glass checks.

## Out of scope

- No user-adjustable history-retention control. Retention itself is
  unchanged (rolling 400 days, per-account caps) and becomes visible in
  Settings; a knob that can delete data is a separate future design.
- No macOS surface.
- No change to credential handling, polling floors, or honesty rules.

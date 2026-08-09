# App Store preflight — Vigil 1.0.0 (23)

> Audited: 2026-08-09
>
> Status: source, CI, signed archive, listing assets, canonical metadata, live
> App Store Connect checks, and Internal TestFlight delivery pass; external
> submission blockers remain. Submitting in the current state would be
> premature.

This report covers the iOS app, widget, canonical en-US metadata, privacy
manifests, entitlements, icon, screenshots, live App Store Connect state, and
current release evidence.

## Rejection blockers (3)

### 1. Guideline 2.1 — App Review cannot yet reach live functionality

- **Evidence:** Vigil creates no app account and meaningful readings require a
  third-party provider credential. The production build has no reviewer-facing
  demo mode. Protected demo fields are populated, but their provider flow and
  viability have not been verified against the delivered build. No physical-
  device recording is attached.
- **Resolution:** prove the protected credential is a dedicated, revocable
  provider test account, keep it active for at least two weeks, write precise
  reviewer steps, and attach the recording specified in
  [`app-review-notes.md`](app-review-notes.md). Do not commit secrets.
- **Why this blocks:** Apple's current Guideline 2.1 requires an active demo
  account for account-based functionality, or a full demo mode with prior Apple
  approval when a demo account cannot be provided.

### 2. Guideline 5.2.2 — Third-party service permission needs owner evidence

- **Evidence:** OpenRouter, DeepSeek, Moonshot, OpenAI organization APIs, GitHub
  Copilot billing, and xAI Management API use documented provider contracts.
  Claude consumer usage, ChatGPT/Codex consumer usage, MiniMax Coding Plan,
  Grok Build billing, Z.ai Coding Plan, Cursor, and Kimi K3 include undocumented
  or consumer-service endpoints. Vigil labels the least stable paths
  Experimental, but stability labeling is not permission to redistribute a
  third-party client.
- **Grok-specific evidence:** xAI now publicly documents Grok Build, browser and
  device-code authentication, and embedding through ACP. Vigil's direct mobile
  use of the Grok CLI OAuth client and billing endpoint is still not a documented
  third-party mobile API grant.
- **Resolution:** the owner must verify each included integration against the
  current provider terms and retain written authorization where required.
  Remove any integration that cannot be supported under its provider terms.
- **Why this blocks:** Apple may require proof that an app is specifically
  permitted to access or display data from third-party services.

### 3. EU Digital Services Act classification is incomplete

- **Evidence:** App Store Connect displays **Complete Compliance Requirements**
  and requires an explicit trader/non-trader selection before EU distribution.
- **Resolution:** the owner must choose the legally accurate classification and
  complete any verification Apple requires. Do not infer this status from app
  pricing, company size, or repository ownership.
- **Why this blocks:** the app is currently enabled in EU territories, and Apple
  requires a completed DSA declaration for EU App Store distribution.

## Warnings and owner decisions (2)

1. **Xcode 27 / iOS 27 gate unavailable.** The current Mac has Xcode 26.6 and an
   iOS 26.5 simulator. Repeat Liquid Glass and full-scheme validation with the
   publication toolchain before public submission.
2. **Physical devices.** TestFlight acceptance must cover a physical iPhone and
   iPad, widgets, notifications, background work, appearance, app lock, account
   deletion, and the dedicated Grok Build flow.

## Passed checks (16)

1. App name is 24/30 characters and subtitle is 26/30.
2. Keywords are 97/100 characters, functional, non-duplicative with the title
   and subtitle, and no longer packed with provider trademarks.
3. Metadata contains no competing mobile-platform terms or price claims.
4. The description accurately counts all 15 compiled provider specs and labels
   experimental integrations.
5. Six iPhone and six iPad screenshots use fictional accounts and pass current
   App Store size validation with no errors or warnings.
6. Static screenshots may use device frames; no app preview video is staged.
7. The app icon is original abstract artwork with no Apple logo, device
   silhouette, copied system icon, or provider logo.
8. The app and widget include valid privacy manifests declaring UserDefaults
   and file-timestamp required-reason APIs, no tracking, and no collected-data
   types.
9. The app and widget declare only the shared App Group and shared Keychain
   access group, both used by shipped functionality.
10. The app has no third-party SDK dependency, analytics, advertising, crash
    reporting, social login for a Vigil account, IAP, subscription, UGC, or
    unrestricted web browser.
11. Sign in with Apple is not required because provider authorization does not
    create or authenticate a primary Vigil account.
12. The native app provides substantial functionality beyond a web wrapper:
    local history, ranking, widgets, alerts, refresh coordination, privacy
    controls, biometric surface lock, and deletion.
13. The Utilities category matches the product's function, and App Store
    Connect reports a 4+ / all-none age questionnaire.
14. Local package, app, UI, documentation, plist, privacy-manifest, metadata,
    and screenshot validation passed with the evidence recorded in
    [`docs/releases/1.0.0-23.md`](../../../docs/releases/1.0.0-23.md).
15. Merged-main artifact commit `7e0803a97b1a79445207e913fc8a41bc13b0a3af`
    passed public GitHub `apple` workflow run `31322413383`; its signed archive
    passed `scripts/verify-ios-archive.sh` for version `1.0.0`, build `23`.
16. The exact archive was owner-approved, uploaded, processed `VALID`, and
    assigned to the one-tester all-builds `Internal` group. The upload is
    `COMPLETE`, the beta state is `IN_BETA_TESTING`, release-specific en-US test
    notes are present, and strict TestFlight validation reports zero findings.

## Required order from here

1. Complete physical iPhone and iPad acceptance, including the dedicated
   reviewer credential and recording.
2. Resolve provider rights and complete the legally accurate DSA declaration.
3. Repeat Xcode 27/iOS 27 validation when that publication toolchain is
   available.
4. Recheck mainland-China exclusion and all mutable App Store Connect state,
   run final strict App Store validation, and obtain separate exact submission
   approval before submitting.

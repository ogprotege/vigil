# App Store preflight — Vigil 1.0.0 (23)

> Audited: 2026-08-09
>
> Status: submitted to App Review on 2026-08-09. Source, CI, signed archive,
> listing assets, canonical metadata, live App Store Connect checks, Internal
> TestFlight delivery, the DSA declaration, reviewer access, and final strict
> validation pass. Residual review risks are recorded below.

This report covers the iOS app, widget, canonical en-US metadata, privacy
manifests, entitlements, icon, screenshots, live App Store Connect state, and
current release evidence.

## Resolved submission gates (2)

### 1. Guideline 2.1 — Dedicated reviewer access

- **Evidence:** The owner confirmed that App Store Connect's protected sign-in
  fields identify a dedicated Grok Build reviewer account. The submitted review
  notes identify the provider and give the full device-code authorization,
  returned usage/credit, refresh, Settings, and local account-removal path.
- **Control:** Keep the account active and monitored throughout review. Never
  commit or place its credentials in public metadata.

### 2. EU Digital Services Act declaration

- **Evidence:** The owner declared non-trader status. App Store Connect shows
  the Digital Services Act requirement as **Active** for 27 countries/regions,
  updated 2026-08-09, and reports all regulatory requirements complete.

## Residual App Review risks (2)

### 1. Guideline 5.2.2 — Third-party service permission evidence

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
- **Risk treatment:** The owner directed submission. Retain current provider
  terms or written authorization where available and be ready to answer an
  App Review request. Remove an integration in a future build if its use cannot
  be supported.
- **Why this matters:** Apple may require proof that an app is specifically
  permitted to access or display data from third-party services.

### 2. Physical-device and publication-toolchain evidence

- **Evidence gap:** The repository does not contain a physical iPhone/iPad
  acceptance record or reviewer recording. The release machine had Xcode 26.6
  and an iOS 26.5 simulator, not the future Xcode 27/iOS 27 publication
  toolchain discussed during planning.
- **Risk treatment:** The owner directed submission with these gaps understood.
  Keep Internal TestFlight available for physical-device follow-up, and repeat
  Liquid Glass plus the full scheme on Xcode 27 for the next update.

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

## Submission evidence

1. Build `23` remained `VALID`, App Store eligible, and attached to iOS version
   `1.0.0`.
2. Mainland China (`CHN`) was the sole unavailable territory out of 175;
   `availableInNewTerritories=false` remained set.
3. Canonical validation, strict submission validation, and review health checks
   returned zero errors, warnings, or blockers. A fresh dry run returned
   `wouldSubmit=true`.
4. App Store Connect submission `fc84c9c4-104d-4039-9c9f-48cb61b491ae`
   entered `WAITING_FOR_REVIEW` at 2026-08-09 19:30:31 UTC. The API and web UI
   independently show iOS 1.0.0 as Waiting for Review.

## Post-submission controls

1. Keep the dedicated Grok Build account active and monitor its sign-in path.
2. Watch App Store Connect for reviewer questions, rejection, approval, or
   release-state changes and respond promptly.
3. Preserve provider-rights evidence and the territory exclusion.
4. Run the physical-device and Xcode 27 checks for the next update even if this
   version is approved.

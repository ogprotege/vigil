# App Store preflight — Vigil 1.0.0 (23)

> Audited: 2026-08-09
>
> Status: local binary and listing assets pass; external submission blockers
> remain. Submitting in the current state would be premature.

This report covers the iOS app, widget, canonical en-US metadata, privacy
manifests, entitlements, icon, screenshots, and current release evidence. It
does not claim that inaccessible App Store Connect state has passed.

## Rejection blockers (4)

### 1. Guideline 2.1 — App Review cannot yet reach live functionality

- **Evidence:** Vigil creates no app account and meaningful readings require a
  third-party provider credential. The production build has no reviewer-facing
  demo mode. No dedicated review credential or physical-device recording has
  been supplied.
- **Resolution:** provide a dedicated, revocable provider test account in App
  Store Connect's protected demo fields, keep it active for at least two weeks,
  and attach the physical-device recording specified in
  [`app-review-notes.md`](app-review-notes.md). Do not commit secrets.
- **Why this blocks:** Apple's current Guideline 2.1 requires an active demo
  account for account-based functionality, or a full demo mode with prior Apple
  approval when a demo account cannot be provided.

### 2. Guidelines 2.1 and 5.1.1 — Listing URLs are not yet proven public

- **Evidence:** canonical metadata and the shipped app point to privacy and
  support pages under `github.com/ogprotege/vigil`. The repository is not
  publicly discoverable from an unauthenticated web search, so those URLs cannot
  currently be treated as live public release URLs.
- **Resolution:** publish `docs/privacy.md` and `docs/support.md` at stable,
  unauthenticated HTTPS URLs; verify both from a signed-out browser and on a
  physical device; then update both metadata and `VigilLinks.swift` together.
- **Why this blocks:** Apple requires a public privacy-policy URL, an accessible
  in-app policy link, working support information, and fully functional URLs at
  submission.

### 3. Guideline 5.2.2 — Third-party service permission needs owner evidence

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

### 4. Guideline 5 / local law — China mainland availability is unresolved

- **Evidence:** metadata, screenshots, and in-app setup name ChatGPT, Claude,
  Grok, and other AI services. App Store Connect territory availability cannot
  be inspected while `asc` authentication is unavailable.
- **Resolution:** unless documented local compliance exists, exclude China
  mainland before submission and verify the final availability record. This
  report does not authorize that external change.

## Warnings and owner decisions (8)

1. **App Store Connect source of truth unavailable.** Repair `asc` authentication,
   pull the existing record, and compare before applying local metadata.
2. **GitHub source of truth unavailable.** Repair `gh` authentication, push only
   the reviewed candidate, and require the `apple` workflow to pass before an
   archive is made.
3. **Xcode 27 / iOS 27 gate unavailable.** The current Mac has Xcode 26.6 and an
   iOS 26.5 simulator. Repeat Liquid Glass and full-scheme validation with the
   publication toolchain before public submission.
4. **Screenshot approval pending.** Twelve valid, fictional-data images are
   ready, but all twelve remain pending owner approval in the local review
   manifest.
5. **App Privacy attestation.** The architecture and manifests support **Data
   Not Collected**: the developer has no backend or SDK collection, and local
   values stay on device. The owner must still confirm the declaration against
   current provider request/retention behavior before publishing it.
6. **Content rights declaration.** Select that the app accesses third-party
   service data and keep the provider-permission evidence supporting that
   declaration.
7. **Commercial and legal fields.** The owner must choose price, manual versus
   automatic release, copyright holder, DSA trader status, and monitored review
   contact information. No value is inferred here.
8. **Physical devices.** TestFlight acceptance must cover a physical iPhone and
   iPad, widgets, notifications, background work, appearance, app lock, account
   deletion, and the dedicated Grok Build flow.

## Passed checks (14)

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
13. The Utilities category in `Info.plist` matches the product's function. A
    4+ / all-none age questionnaire is technically consistent, pending remote
    verification.
14. Local package, app, UI, documentation, plist, privacy-manifest, metadata,
    and screenshot validation passed with the evidence recorded in
    [`docs/releases/1.0.0-23.md`](../../../docs/releases/1.0.0-23.md).

## Required order from here

1. Resolve provider rights, reviewer access, public URLs, legal fields, and
   China mainland availability.
2. Repair App Store Connect authentication; pull and diff the remote record.
3. Obtain owner approval for the final listing and all twelve screenshots.
4. Commit the exact candidate, push it, and require green GitHub CI.
5. Repeat Xcode 27/iOS 27 and physical-device checks.
6. Build and verify a signed archive from the exact green commit.
7. Obtain the runbook's exact upload approval before TestFlight upload.
8. Complete Internal TestFlight acceptance.
9. Obtain separate exact App Review submission approval before submitting.

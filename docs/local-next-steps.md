# Local next steps

This is the current release handoff, not a desktop setup guide.

## Where the project stands on 2026-07-26

| Area | State |
|---|---|
| Product | iOS 17+ app and widgets only |
| Account setup | Phone-native Claude and Codex sign-in, plus pasted provider credentials |
| Provider registry | 14 providers with explicit required-output contracts and fixture provenance |
| Provider hardening | Build 12 corrected Claude fractional timestamps and model-scoped percentages and removed false Models fallbacks; build 13 preserved those fixes and added strict required-output detection plus broader provider corrections |
| Current release target | Version 0.15.0, build 16 |
| Reliability | Shared account-level poll leases, visible persistence failures, reset-safe presentation and notifications, protected history, and fail-closed provider drift |

## Before releasing 0.15.0 (16)

1. Run VigilKit and iOS Simulator tests.
2. Confirm `apps/apple/project.yml` supports only iOS destinations.
3. Confirm the app has no camera permission or custom credential URL scheme.
4. Confirm only phone-native account paths remain in onboarding.
5. Verify Claude and Codex sign-in on a physical phone.
6. Add at least one pasted-key provider.
7. Verify Home urgency order, complete account detail, observed history, Accounts, notifications, and widgets against real snapshots.
8. Archive, export, and upload with [Release runbook](release.md).
9. Install the processed TestFlight build and repeat the critical on-device walk.

## Provider validation still matters

Fixture parity proves deterministic mapping. It does not prove an endpoint still returns the fixture shape.

For each opt-in provider, use a dedicated test credential when available. Preserve a sanitized production body only when it can be committed safely. Update `protocol/fixture-provenance.json` with the narrowest true evidence class.

The experimental providers are MiniMax, MiniMax China, Z.ai, Cursor, and Kimi K3. Do not remove their label without both a stable vendor contract or a sanitized Vigil production capture and a completed live UI check.

## Standing invariants

- Never lower the 300-second provider poll floor to make refresh appear faster.
- Never auto-refresh a credential Vigil did not mint.
- Never label a partial required-output result Live.
- Never treat an expected fixture as independent upstream evidence.
- Keep one decisive, most urgent provider window on Home and complete genuine provider lanes in account detail.
- Keep VigilKit UI-free.
- Keep signing credentials outside the repository.

## Remaining release work

- Authenticate as the `vigil-link` package owner, run the npm deprecation command in [Release runbook](release.md#retire-the-legacy-npm-artifact), and verify the registry returns the retirement message.
- Complete physical-device Keychain and account-removal checks.
- Verify app and widget share one ledger in a signed build.
- Verify threshold notifications and background refresh behavior.
- Prepare external TestFlight and App Store screenshots and listing copy.
- Continue provider-by-provider live validation without overstating fixture provenance.

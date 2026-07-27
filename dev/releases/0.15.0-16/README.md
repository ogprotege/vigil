# 0.15.0 (16) working evidence

> Status: active evidence directory
>
> Last reviewed: 2026-07-26
>
> Review again: after every evidence addition or release-state change

The canonical status for this release is
[`docs/releases/0.15.0-16.md`](../../../docs/releases/0.15.0-16.md). Do not put a
second release status or approval decision in this directory.

This directory may hold reviewable development evidence that is too detailed
for the canonical release record, such as:

- sanitized UI screenshots;
- test-result summaries;
- code-review reports;
- provider-fixture provenance notes;
- an index of local archive-verifier output.

Do not commit:

- `.xcarchive`, `.ipa`, `.xcresult`, or DerivedData bundles;
- App Store Connect API keys, certificates, or provisioning profiles;
- provider credentials, cookies, headers, or raw provider responses;
- user diagnostic exports or unsanitized device logs.

Every evidence file must name the exact commit and environment it covers. A
runtime capture from an older commit is historical evidence, not proof for the
current candidate.

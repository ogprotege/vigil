# ADR-0003: v1 QR payloads are compressed plaintext with guardrails

**Status:** accepted (amended 2026-07-19: future-skew rejection is normative)

## Decision

The `vigil1` handoff payload is deflate-compressed, base64url-encoded plaintext. Guardrails: consent prompt before rendering, terminal auto-clear after linking, receivers reject payloads older than 10 minutes **and reject payloads whose issue time is more than 60 seconds in the future** (a forged far-future `iat` would otherwise never age out; 60 s absorbs ordinary clock skew, making the maximum effective validity window 660 s). Both decoders — VigilKit and the CLI's — enforce the same two bounds. An opt-in encrypted variant (`vigil1e`: 6-digit code typed into the CLI → HKDF-SHA256 → ChaCha20-Poly1305) is planned; the version token already reserves it and current decoders reject it as an unsupported variant.

## Context

The QR is displayed on the user's own screen and scanned optically in person; realistic threats are shoulder-surfing and screen recording. Mandatory encryption requires out-of-band key exchange on every link — typing a code from phone to CLI — taxing the #1 product goal (setup ease). The identical tokens already sit unencrypted in `~/.claude/.credentials.json`.

Post-quantum cryptography was considered and rejected as inapplicable: an optical local one-way transfer has no network key exchange for a harvest-now-decrypt-later adversary to attack. If a future networked relay is added, PQC-hybrid belongs on that channel.

## Consequences

- Screen-capture during the ~15 s link window is an accepted risk in v1, mitigated by consent + clear + expiry.
- The `vigil1` version token gives a clean upgrade path; old apps reject unknown variants with "update Vigil".

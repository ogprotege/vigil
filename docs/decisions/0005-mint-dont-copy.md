# ADR-0005: Mint Vigil-owned Claude credentials

**Status:** accepted, amended

| Event | Date |
|---|---|
| Original decision | 2026-07-18 |
| Current iOS amendment | 2026-07-21 |
| Documentation correction | 2026-07-26 |

## Decision

Vigil's guided Claude sign-in creates a credential pair for Vigil. It does not
copy Claude Code credentials, read another app's cache, or import a token from
a computer.

The iOS app performs an authorization-code flow with PKCE:

1. Vigil creates a cryptographically random verifier and S256 challenge.
2. The app opens Claude's authorization page in the system browser.
3. Claude displays an authorization code through its out-of-band callback.
4. The user pastes that code into Vigil.
5. Vigil validates the returned state and exchanges the code on-device.
6. Vigil stores the resulting credential in the device Keychain with source
   `mint`.

Only a credential explicitly marked `mint` is eligible for automatic refresh.
The credential model can represent a manually supplied Claude token, but the
current first-launch and Other Provider flows do not offer that route. If such
a credential enters through a future reviewed path, Vigil does not own its
refresh lifecycle and must never auto-renew it.

The retired `vigil-link` desktop loopback flow and `--copy` fallback are not
part of the current product.

## Context

OAuth refresh tokens may rotate. If Vigil copied a token pair owned by Claude
Code and both clients refreshed independently, one client could invalidate the
other client's refresh token. A Vigil-owned pair keeps lifecycle ownership
unambiguous.

iOS cannot host the old desktop handoff experience. The current out-of-band
flow also avoids a custom callback scheme and a localhost server. Setup happens
on the phone and requires the user to approve access in Claude.

Live validation established several provider-specific request constraints:

- the authorization request includes `code=true`;
- PKCE uses `S256`;
- the PKCE verifier also serves as the expected state;
- the out-of-band callback may return a full callback URL, a code-and-state
  pair, or a bare code;
- an accepted exchange may return both access and refresh tokens.

These are provider integration facts, not a claim that Claude exposes a public
subscription-history API. The credential authorizes the current usage request
that Vigil supports. Vigil cannot reconstruct activity the provider does not
return.

## Consequences

- Guided Claude setup requires browser approval and a code paste.
- The Keychain stores the Vigil-owned access token and any returned refresh
  token.
- A successful refresh may rotate either token. Vigil commits the refreshed
  credential only for the same live account lifecycle.
- Link-time verification does not refresh a credential. It cannot consume a
  rotation before the new credential is durably stored.
- A non-minted token cannot enter the automatic refresh path.
- Removing the account deletes Vigil's credential. It does not alter Claude
  Code, Safari, or another app's credentials.
- The browser session remains system-owned. Vigil's provider session is
  ephemeral, cacheless, and cookieless.

## Rejected alternatives

### Copy Claude Code credentials

Rejected because refresh-token rotation would create shared ownership and
could break either client.

### Read another iOS app's cache or login store

Rejected because iOS application sandboxing does not grant Vigil access. It
would also violate the product's credential boundary.

### Restore the desktop loopback helper

Rejected because Vigil is iOS-only and phone-native. The helper added setup,
security, support, and release surfaces that the current product does not need.

### Auto-refresh every pasted token

Rejected because possession of an access or refresh token does not establish
that Vigil owns its rotation lifecycle.

## Enforcement

Primary implementation:

- `packages/VigilKit/Sources/VigilKit/Providers/ClaudeAuth.swift` constructs
  PKCE requests, parses pasted codes, and creates `mint` credentials.
- `packages/VigilKit/Sources/VigilKit/Providers/TokenRefresher.swift` refuses
  refresh unless the credential source is `mint` and a refresh token exists.
- `packages/VigilKit/Sources/VigilKit/Providers/ProviderSpec.swift` defines the
  current on-device authorization and token endpoints.
- `apps/apple/Vigil/Onboarding/ClaudeSignInView.swift` implements browser
  approval and code paste on iPhone.
- `packages/VigilKit/Sources/VigilKit/Vault/KeychainCredentialsStore.swift`
  stores credentials in the non-synchronizing device Keychain.

Tests for these components must preserve the following invariants:

- PKCE state validation fails closed;
- only `mint` credentials can refresh;
- link-time verification cannot refresh;
- malformed or missing token responses do not create credentials;
- account removal and full reset cannot allow a delayed refresh to restore a
  deleted credential.

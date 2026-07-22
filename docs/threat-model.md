# Threat model and limitations

Vigil is an iOS-only local client. It has no collection server. This document states what it protects, where trust changes hands, and what remains outside the design.

## Assets

- provider access and refresh credentials;
- API keys, management keys, session cookies, and account identifiers;
- usage windows, reset times, balances, spend, and plan labels;
- account index and user-provided labels;
- poll leases, rate-limit state, observation history, and notification events;
- release signing credentials and provisioning profiles used outside the repository.

## Trust boundaries

### iPhone and Keychain

The app stores credentials in Apple Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The app and widget share access through the configured Keychain group.

Keychain protects credentials at rest under Apple's platform security model. Vigil does not add application-layer encryption around Keychain values.

### App Group container

The app and widget share snapshots, account metadata, poll leases, observation history, and notification events through `group.app.vigil.shared`.

These files contain no bearer credential. They can still reveal account relationships, usage, balance, spending, and timing. Apple sandboxing and device data protection guard them.

### Provider authorization pages

Claude and Codex sign-in opens provider-controlled web pages. Credentials, passwords, multifactor prompts, and approval decisions remain inside the provider's authentication surface.

Vigil receives an authorization code or device-authorization result and exchanges it with the provider's token endpoint. It does not receive the user's provider password.

### Provider usage endpoints

The device sends credentials and requests directly to each activated provider over TLS. The provider sees the request and applies its own authentication, retention, and privacy policies.

No request passes through infrastructure operated by Vigil.

### Apple services

iOS, TestFlight, background tasks, notifications, and WidgetKit remain under Apple's platform controls. Vigil cannot guarantee when background work will execute.

## Controls

### Credential handling

- Every credential is minted or entered on the iPhone.
- Vigil refreshes only credentials it minted.
- Manually pasted tokens and keys are treated as externally owned.
- Credentials never enter the App Group snapshot store.
- Account removal requires confirmed Keychain deletion before the UI drops the account.
- Sensitive signing files are excluded from and rejected by repository checks.

### OAuth and device authorization

Claude sign-in uses PKCE. The verifier binds the token exchange to the sign-in attempt that created the challenge.

Codex uses OpenAI device authorization. Vigil displays the user code, opens the provider page, and obeys the server-provided poll interval. The app does not embed a confidential client secret.

Sign-in state is short-lived. Old codes must not be reused.

### Provider mapping

Raw provider bodies pass strict JSON checks. The mapper rejects malformed numbers, invalid percentages, duplicate semantic keys, incompatible wrappers, unsupported collection identities, and incomplete correlated fields.

Required-output contracts prevent a partial response from being labeled Live. Structural drift becomes `schemaChanged`, and the app preserves the last successful snapshot.

### Polling and rate limits

The app and widget share durable account-level leases. Reservation happens before network I/O under an OS file lock. Ledger failure fails closed.

HTTP 429 advances provider-configured backoff. Manual refresh cannot bypass an active lease or backoff.

### Local presentation

- Snapshot age remains visible.
- Countdowns are identified as local projections from the last reset timestamp.
- Experimental providers remain labeled.
- Biometric app lock can reduce casual access while the device is unlocked.

## Accepted risks

### Undocumented provider endpoints

Claude, Codex, and several opt-in integrations use consumer or web endpoints without a stable third-party contract. Providers can change authentication, shape, availability, or terms without notice.

Vigil detects known structural incompatibility. It cannot guarantee advance notice or continued endpoint access.

### Credential authority

Some providers do not offer a read-only usage credential. A supplied API key, Admin key, Management Key, or session cookie may permit broader account action or spending.

Use a dedicated, restricted credential where the provider supports one. Do not reuse an organization-wide administrative credential when a narrower credential exists.

### Clipboard, keyboard, and screen capture

Pasted keys and returned sign-in codes can pass through the clipboard, keyboard extension, screen buffer, or app process memory. Vigil cannot protect a value captured by a malicious keyboard, screen recorder, accessibility process, or unlocked-device observer.

Clear sensitive clipboard content and avoid screen sharing during setup.

### Device compromise

Vigil does not defend against:

- a jailbroken device or hostile operating system;
- malware or debugging tools with sufficient process access;
- an unlocked device in another person's control;
- compromise of the user's Apple ID or TestFlight account;
- malicious provider pages or a compromised provider.

The app lock is a convenience control, not a second hardware-backed credential vault.

### Local metadata

Snapshots and observations are not encrypted by Vigil. They rely on iOS sandboxing and data protection. A device compromise can expose usage and billing metadata even when bearer credentials remain in Keychain.

### Multiple linked accounts

The polling ledger is keyed by account. Several accounts for one provider can each make a request inside the same five-minute period. Vigil enforces each account's floor but does not coordinate a global provider-wide budget.

### Background freshness

iOS and WidgetKit choose when background work runs. Vigil cannot guarantee exact refresh or notification times. A countdown can remain mathematically current relative to a known reset while utilization becomes stale.

### Development fallback

When the App Group container is unavailable, unsigned previews or local builds can fall back to process-private Application Support. App and widget processes then lack shared locking.

This fallback supports development. It is not a production reliability guarantee.

### No certificate pinning

Vigil trusts the operating system's TLS validation. It does not pin provider certificates. This avoids breakage during provider certificate rotation but retains system trust-store risk.

## Out of scope

- proving a provider's reported usage or balance is correct;
- detecting a malicious or compromised provider;
- enforcing organizational billing policy;
- recovering access to a provider account;
- exact-time background monitoring;
- server-side push alerts;
- protecting data after a user logs, exports, screenshots, or shares it;
- monitoring desktop transcript token counts unavailable to the phone.

## Security reporting

Do not include credentials, authorization codes, raw provider bodies, account IDs, billing details, or sensitive screenshots in an issue.

Provide the Vigil version and build, iOS version, provider ID, sanitized error class, HTTP status when safe, and a minimal sanitized response shape when mapping is involved.

Rotate any credential that entered logs, screenshots, an issue, or a commit. See [Security policy](../SECURITY.md).

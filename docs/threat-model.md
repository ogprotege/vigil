# Threat model and limitations

This document defines the security claim Vigil can defend. It does not claim that a compromised computer, jailbroken phone, malicious provider, or recorded screen is safe.

## Assets

- OAuth access and refresh tokens;
- API keys;
- provider account IDs;
- account labels and plan names;
- usage windows, spend, limits, and balances;
- polling timestamps and rate-limit history.

Credentials are the highest-risk assets. Usage and account metadata are less sensitive, but they can reveal work patterns, subscription level, and spending.

## Trust boundaries

Data crosses these boundaries:

1. provider-owned CLI files or macOS Keychain into `vigil-link`;
2. the CLI process into terminal output or a QR image;
3. the QR or paste code into the Vigil app;
4. the app into Apple Keychain and the App Group container;
5. the app or CLI over TLS to the activated provider;
6. the app's App Group container into the widget extension.

Vigil has no application server, account service, telemetry collector, or cloud relay.

## Controls

### Credentials

- Apple credentials use Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `ThisDeviceOnly` prevents iCloud Keychain migration and sync.
- The app and widget share an access group because the widget may perform a gated refresh.
- Removing an account does not update the account index until Keychain confirms credential deletion.
- A rotated refresh token must be saved before Vigil retries the provider request.
- The CLI keeps credentials in process memory and never writes them to its safety cache.

### QR handoff

- The CLI asks for consent before showing credentials.
- Terminal screen and scrollback clearing is best effort.
- Chunks have a session ID and cannot be mixed across sessions.
- Receivers reject payloads older than 10 minutes.
- Receivers reject payloads more than 60 seconds in the future.
- Live verification runs before the app persists a linked credential unless
  the user explicitly accepts an unverified network-failure or local
  safety-cooldown path.
- Receivers bound link chunks, account counts, credential fields, and metadata
  before durable storage.

### Polling and local state

- Apple fetch reservation uses an OS file lock and an expiring owner lease.
- A stale process cannot clear a newer owner's lease.
- Apple ledger failures fail closed and surface in the app.
- CLI reservation uses a cross-process directory lock and writes before network I/O.
- CLI state contains provider ID in the filename, timestamps, and a 429 counter. It contains no credential or usage value.
- Shared-container directories use owner-only permissions. Snapshot, event,
  lock, and ledger files are tightened to owner-only permissions on access.

### Provider failures

- Requests use TLS through system networking.
- Apple and CLI provider attempts have a 15-second timeout.
- Provider failures are isolated.
- Invalid successful responses become `schemaChanged`, not an empty success.
- Scalar metrics preserve their reported unit. Vigil does not silently convert currencies or invent utilization.

## Accepted risks

### Plaintext QR content

`vigil1` compresses credentials but does not encrypt them. Anyone who sees the QR, captures the screen, reads terminal scrollback, or obtains a saved screenshot can recover the credential. Compression is not encryption.

Mitigations reduce exposure time but do not remove this risk. Link in private, avoid screen sharing and recording, and clear the terminal. Revoke the credential if exposure is suspected.

### Provider endpoint stability

Claude and Codex consumer usage endpoints are undocumented. They can change, reject third-party traffic, or disappear. OpenRouter and DeepSeek expose documented endpoints, but their authentication and response policies can still change.

Fixtures detect regressions against known shapes. They do not provide production monitoring or advance warning of vendor drift.

### Credential authority

OAuth tokens and API keys may authorize more than usage reads. Vigil cannot reduce authority that the provider does not expose as a narrower scope. A stolen API key may permit inference or spending.

Use a dedicated, restricted key when the provider supports one. Do not reuse an organization-wide admin key.

### Device and process compromise

Vigil does not defend against:

- malware running as the user on the computer;
- a compromised provider CLI credential file;
- a jailbroken device or hostile OS;
- debugging or memory inspection on a compromised device;
- an unlocked device in another person's control;
- malicious keyboard, accessibility, screen-capture, or terminal software.

The optional app lock reduces casual access. It is not a separate cryptographic boundary around Keychain.

### Local metadata

Snapshots, account indexes, notification events, and polling ledgers live in the App Group container, not Keychain. They do not contain bearer credentials, but they can contain labels, account keys, utilization, balances, and timing metadata. They rely on Apple sandboxing and data protection rather than application-layer encryption.

Snapshot and pending-notification cleanup failures are reported. Poll-ledger cleanup runs asynchronously and raises a storage warning if it fails. Credential deletion remains the privacy-critical gate.

### Background freshness

iOS and WidgetKit decide when background work runs. Vigil cannot guarantee exact refresh times. Countdown rendering can remain current relative to a known reset time while the underlying usage value grows stale.

### Unsigned local fallback

When the App Group container is unavailable, local previews or unsigned builds may use Application Support. App and widget processes then lack a shared ledger. This fallback is for development, not a security or reliability guarantee.

### No certificate pinning

Vigil trusts the operating system's TLS validation. It does not pin provider certificates. This avoids brittle releases when providers rotate infrastructure, but it retains the risks of the system trust store.

## Out of scope

- protecting credentials after a user exports, screenshots, logs, or shares them;
- proving a provider's reported quota or balance is correct;
- detecting a malicious or compromised provider;
- enforcing organization billing policy;
- recovering access to a provider account;
- exact-time background monitoring;
- server-side push alerts.

## Security reporting

Do not include credentials, QR payloads, raw provider responses, account IDs, or billing details in an issue. Provide:

- Vigil and `vigil-link` versions;
- platform and OS version;
- provider ID;
- redacted error class and HTTP status;
- whether the endpoint is documented or internal;
- a minimal sanitized response shape if schema mapping is involved.

Rotate or revoke any credential that entered logs, screenshots, an issue, or a commit.

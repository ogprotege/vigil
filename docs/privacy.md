# Privacy

Vigil has no collection server, Vigil account, analytics SDK, advertising SDK, or cloud synchronization service.

When you activate a provider, the CLI or app sends that provider your credential and a usage request over TLS. The provider can observe the request under its own privacy policy. Vigil does not proxy, collect, sell, or receive that traffic.

## What stays on your devices

### Credentials

Credentials can exist in:

- files or Keychain items created by provider-owned tools on your computer;
- environment variables supplied to `vigil-link`;
- `vigil-link` process memory;
- terminal output, scrollback, or QR pixels during linking;
- the phone's browser and app memory during an on-device sign-in (Sign in with Claude / Sign in with Codex), before the token is stored in Apple Keychain;
- Apple Keychain after the app accepts the account.

The Apple app uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The credentials do not sync through iCloud Keychain. Each device must be linked separately.

The app and widget use an explicit shared Keychain access group. On upgrade,
the app reads the shared item first and can copy a verified legacy app-only
item into that group. The legacy item remains until explicit account removal.

The CLI never writes credentials to its cache.

### Usage and account metadata

The Apple App Group container stores:

- account references and labels;
- current and previous usage snapshots;
- pending threshold events;
- poll timestamps, leases, and 429 counters.

The widget reads this container. These files contain no bearer credential, but they can reveal subscription, usage, spending, balance, and timing information.

The CLI stores only provider-level poll timestamps and 429 counters under the user cache directory. It does not store returned usage values.

## Account removal

Credential deletion is the critical privacy step. Vigil does not remove an account from its index or UI unless Keychain confirms deletion. If deletion fails, the app keeps the account visible and reports the error.

Snapshot, event, and ledger cleanup follows. Snapshot and event deletion failures are reported, and an asynchronous ledger cleanup failure raises the app's storage warning. A stale local usage file is less sensitive than a bearer token, but it is still local metadata and should be considered when disposing of a device or debugging a failed removal.

## QR warning

`vigil1` QR and paste payloads are compressed plaintext. Anyone who can see the screen, capture terminal scrollback, read a pasted payload, or obtain a screenshot can recover the credentials. A 10-minute age check limits replay through Vigil. It does not revoke or encrypt the underlying credential.

Link in private. Do not screen-share, record, save, or reuse the code. Revoke a credential if exposure is suspected.

## App Store privacy label

Vigil itself does not collect data. The intended App Store label is **Data Not Collected** because no data is transmitted to the developer or a Vigil service.

This claim does not mean “no network traffic.” Activated provider requests go directly to Anthropic, OpenAI, OpenRouter, DeepSeek, or another provider added by the user. Those providers receive the request.

See [threat-model.md](threat-model.md) for trust boundaries, accepted risks, and out-of-scope attacks.

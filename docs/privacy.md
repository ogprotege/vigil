# Privacy

Vigil has no collection server, Vigil account, analytics SDK, advertising SDK, or cloud synchronization service.

When a user activates a provider, Vigil sends that provider the required credential and usage request over TLS. The provider can observe the request under its own privacy policy. Vigil does not proxy, collect, sell, or receive that traffic.

## Credentials

Credentials are created or entered on the iPhone:

- Claude browser approval returns a code that Vigil exchanges for its own credentials.
- Codex device authorization returns Vigil's own credentials after the user approves the displayed code.
- Other providers use a key, account identifier, or session credential pasted into the app.

The app stores accepted credentials in Apple Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. They do not sync through iCloud Keychain. Each device must be set up independently.

The app and widget use an explicit shared Keychain access group. During an upgrade, the app can migrate a verified legacy app-only item into that group. The legacy item remains until explicit account removal.

Sign-in codes and pasted credentials can exist briefly in browser, clipboard, keyboard, and app process memory. Avoid third-party keyboards or screen sharing while entering them. Clear a sensitive clipboard after setup.

## Usage and account metadata

The Apple App Group container stores:

- account references and labels;
- current and prior usage snapshots;
- spend and balance observation history;
- pending threshold events;
- poll timestamps, leases, and rate-limit counters.

The widget reads this container. These files contain no bearer credential, but they can reveal subscriptions, usage, spending, balances, and timing.

## Account removal

Credential deletion is the critical privacy step. Vigil does not remove an account from its index or UI unless Keychain confirms deletion. If deletion fails, the account remains visible and the app reports the error.

Snapshot, observation, event, and ledger cleanup follows. Cleanup failures are surfaced because local usage and billing metadata remains sensitive even without a bearer token.

## Network destinations

Vigil contacts only:

- provider authorization and token endpoints used for Claude or Codex sign-in;
- usage or billing endpoints for providers the user activates;
- Apple services used by iOS, TestFlight, notifications, and WidgetKit.

Vigil does not send provider data to a developer-operated service.

## App Store privacy label

The intended App Store privacy label is **Data Not Collected** because no data is transmitted to the developer or a Vigil service.

This does not mean there is no network traffic. Each activated provider receives direct requests and applies its own privacy policy.

See [Threat model](threat-model.md) for trust boundaries, accepted risks, and exclusions.

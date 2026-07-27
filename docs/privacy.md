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

The Apple App Group container `group.app.vigil.shared` stores:

- account references and labels;
- current and prior usage snapshots;
- successful normalized quota and metric history, with observation or provider-import provenance;
- pending threshold events;
- poll timestamps, leases, and rate-limit counters.

The widget reads and writes this container through the same locked stores as the app. These files contain no bearer credential, but they can reveal subscriptions, usage, spending, balances, and timing.

Normalized history lives in a transactional SQLite database in that App Group. History begins when Vigil first observes an account, unless a supported provider returns official historical buckets. Each successful retained fetch is a separate observation, even when its values did not change. Rows remain eligible for up to 400 days. Each linked account has separate caps of 120,000 device observations and 5,000 provider-backfill records. One source cannot evict the other source, and one account cannot consume another account's cap.

**Observed by Vigil** means the app or widget actually received and retained a successful provider reading. It does not prove what happened between readings. iOS controls background execution, so gaps are expected. **Imported from provider** means a documented provider administration API returned the historical bucket. The current import covers OpenAI API-platform organization completion usage and costs, not ChatGPT or Codex subscription activity. A quota percentage is not relabeled as complete token history.

An upgrade can find the retired money-only observation file used by earlier builds. Vigil migrates eligible rows into normalized observed history with their original timestamps and stable identifiers. It removes the retired file only after a successful migration.

## User-initiated export

Vigil can create a diagnostic JSON file for the user to save or share. The export uses per-file account, window, metric, quantity, and history aliases plus allow-listed normalized fields. It omits free-form account and plan labels. Provider-controlled identifiers, labels, and units are aliased or omitted. It excludes bearer credentials, refresh tokens, cookies, authorization headers, Keychain attributes, raw provider bodies, credential-derived account keys, and OpenAI project or API-key identifiers.

The report is not a full database dump. It includes a bounded recent selection per account and provenance source. Its `historyScope` records the total retained sample count, exported sample count, and selection rule so a support reader cannot mistake the subset for complete history.

Provider polling and OAuth token exchanges use an ephemeral URL session with
response caching and cookie persistence disabled. Vigil clears its own legacy
shared-session response cache and cookies left by builds through 0.14. This
does not inspect or delete Safari, ChatGPT, Claude, or another app's cache or
browser cookies.

Once exported, the file leaves Vigil's protected container. The user and the selected destination control its retention and disclosure.

## App lock and screen privacy

The optional app lock uses Apple's device-owner authentication. iOS chooses Face ID, Touch ID, or passcode fallback. Vigil receives only success or failure and stores no biometric data.

While locked, account content cannot receive input and is hidden from accessibility. Whenever Vigil becomes inactive or enters the background, an opaque cover replaces the app content before iOS captures the app-switcher view. This protects the app surface from casual viewing. It does not add a separate encryption layer to Keychain or App Group files, and it does not hide a configured widget.

## Account removal

Credential deletion is the critical privacy step. Vigil does not remove an account from its index or UI unless Keychain confirms deletion. If deletion fails, the account remains visible and the app reports the error.

Vigil tombstones the account before cleanup so an app or widget request already in flight cannot restore it. It removes current and prior snapshots, SQLite history rows, legacy observations, event queues, snapshot and event lock files, queued and delivered notifications, polling metadata, and damaged account-index backups. It prunes retired lifecycle metadata only after the final sweep.

Cleanup failures are surfaced because local usage and billing metadata remains sensitive even without a bearer token. When required cleanup cannot finish, the account remains visible for a retry. If unreadable history blocks removal, the app can offer a separate confirmed action that deletes all local Vigil history before retrying the account removal.

If Vigil cannot safely decode its identity registry or a Keychain payload, it blocks ordinary identity changes. Settings then offers a separately confirmed full local reset. The reset first invalidates every app and widget account generation and waits for already-started account cleanup and notification delivery. It then removes every enumerable Vigil Keychain credential, all account references, snapshots, observed and imported history, pending events, Vigil notifications, polling metadata, legacy network cache and cookie residue, and damaged repair files. It writes verified empty identity stores and performs a final Vigil-notification sweep before setup becomes available again. The reset affects only data controlled by Vigil on this device. It does not delete an account at Claude, OpenAI, or another provider.

New widget configuration identifiers and local notification identifiers contain non-reversible SHA-256 account digests rather than raw provider account IDs. Vigil still recognizes a raw widget identifier created by an earlier beta so the selection can resolve during upgrade. WidgetKit owns that persisted configuration, so removing and recreating an older configured widget is the only way to guarantee that Apple-managed copy is rewritten.

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

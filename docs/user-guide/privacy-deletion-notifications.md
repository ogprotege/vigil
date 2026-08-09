# Privacy, deletion, and notifications

Vigil minimizes where data goes, but local quota and billing data can still be sensitive.

> Last reviewed: 2026-08-09
>
> Review again: for every storage, networking, notification, or export change

## Network requests

Vigil has no collection server. It sends authentication and usage requests directly to providers the user activates. Those providers receive the request under their own privacy and retention policies.

Vigil's provider sessions are ephemeral, do not use an HTTP response cache, and do not keep an app cookie store. The app also clears legacy app-scoped response and cookie data left by older Vigil builds. This cleanup does not inspect or clear Safari or another provider app.

Browser pages used to approve Claude or OpenAI sign-in run in the user's browser. Browser cookies and provider login state remain under the browser and provider's control.

Vigil cannot read private storage belonging to Claude, ChatGPT, Perplexity, or another iOS app.

## Credentials

Credentials are stored in the shared Vigil Keychain access group with Apple's [`AfterFirstUnlockThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly) accessibility class.

This means:

- credentials do not synchronize through iCloud Keychain;
- they are bound to this device and do not migrate to a different device;
- they are unavailable until the first device unlock after a reboot; and
- after that first unlock, the app or widget can access them while the device is locked when iOS permits background work.

That last property allows background and widget checks. It is also an important security boundary. The optional Vigil app lock does not change the Keychain accessibility class.

Some credentials carry broad provider authority. An OpenAI organization Admin API key is the clearest example. Vigil limits its requests to documented Usage and Costs `GET` calls, but it cannot reduce the authority granted to the key itself. Revoke such credentials with the provider when they are no longer needed.

## Local records and Apple backups

Vigil stores normalized account references, snapshots, history, polling records, and pending notification events in the App Group container shared by the app and widget. These files use iOS data protection and owner-only permissions. They are not separately encrypted by Vigil.

The files do not contain bearer credentials. They can still reveal providers, account labels, usage, balances, spend, reset timing, and activity timing.

Vigil does not implement cloud sync. It also does not mark its App Group records as excluded from Apple-managed device backups. Apple explains that [iCloud Backup includes app data unless the system or app excludes eligible files](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup). Therefore, **This device only** must not be read as **never included in a backup**.

## Notifications

When **Usage alerts** is enabled, Vigil can request permission for local alerts after an account is linked. It detects crossings at fixed 80% and 95% utilization. An account already above a threshold at its first accepted reading does not generate a retroactive crossing alert. Turning alerts off also clears Vigil notifications and consumes pending crossings so they do not appear later if alerts are re-enabled.

A notification can show:

- the provider display name;
- the quota window;
- the current utilization percentage; and
- wording that the limit is close.

This information can appear on the Lock Screen or in Notification Center. Enable **Hide notification details** in Vigil Settings to replace it with generic copy containing no provider, account label, quota window, threshold, or utilization. iOS **Settings → Notifications → Vigil** still controls permission and system preview behavior.

Notification identifiers use opaque hashes in current builds. Removing an account also removes queued and delivered Vigil threshold notifications for that account.

## App lock and widgets

**Require Face ID or Touch ID** uses device-owner authentication with passcode fallback. When enabled, Vigil locks after entering the background. The app also places an opaque cover over inactive and background scenes so app-switcher snapshots do not expose account content.

The lock protects the app surface. It does not add another encryption layer to local files and does not automatically change system widgets or notifications. Enable **Hide usage values in widgets** to keep the provider identity and freshness while removing percentages, limits, spend, and balances. Enable **Hide notification details** for generic alert text, or remove/disable those system surfaces entirely.

## Appearance and automatic checks

Settings offers **System**, **Light**, and **Dark** appearance. System follows the device; Dark preserves Vigil's original low-light palette. Appearance is presentation-only and does not change provider data or credential handling.

**Pause automatic checks** stops foreground timer, background-task, and widget network fetches. Pull-to-refresh and account verification remain available. Existing snapshots stay visible with their real freshness state; pausing does not fabricate a new reading or complete history.

## Diagnostic exports

A user-initiated diagnostic report includes generated account aliases, trusted provider identifiers, numeric usage state, dates, statuses, and a bounded recent history subset. It excludes:

- access and refresh tokens;
- cookies and authorization headers;
- Keychain contents and credential fingerprints;
- raw provider responses;
- free-form account and plan labels; and
- provider-controlled window, metric, and quantity labels or units.

The export still contains usage and billing metadata. After it is saved to Files, shared, mailed, or uploaded, it is outside Vigil's container and outside Vigil's control.

## Remove one account

Open **Accounts**, choose the account, and confirm **Remove account**. Vigil removes the credential, linked account entry, snapshots, observed and imported history for that account, polling metadata, local event queues, and its Vigil notifications.

If damaged shared history blocks account-scoped cleanup, Vigil asks before deleting all local history to finish the removal. That second action affects history for every Vigil account.

Account removal does not:

- close or delete the provider account;
- revoke the credential at the provider;
- delete provider-side logs or history;
- erase an Apple-managed backup; or
- delete a diagnostic file already exported from Vigil.

## Full local recovery reset

**Erase Vigil data and start over** appears only when Vigil cannot safely reconcile its local account identity stores. After confirmation, it attempts to remove all recoverable Vigil Keychain credentials, linked accounts, snapshots, observed and imported history, polling metadata, repair backups, app-scoped network residue, and Vigil notifications from the device.

The reset reports failures instead of claiming deletion succeeded. It does not affect provider accounts, provider-side data, existing Apple backups, or prior exports.

## Damaged account-index repair backup

If Vigil repairs a damaged account index, it can preserve the damaged copy for review. **Delete account repair backup** deletes only that copy. It does not remove linked accounts, credentials, snapshots, or history.

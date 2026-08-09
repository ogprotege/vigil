# Vigil Privacy Policy

**Effective and last updated: August 9, 2026**

This policy applies to the Vigil iPhone and iPad app ("Vigil"). Vigil is an
on-device utility for viewing usage, quota, reset, balance, credit, and billing
information returned by AI providers that a user chooses to connect.

## What Vigil's developer collects

Vigil's developer does **not** collect credentials, account identifiers, usage
readings, billing values, diagnostic data, or device identifiers through the
app. Vigil has no developer-operated collection server, account system, cloud
sync, analytics, advertising SDK, crash-reporting SDK, or cross-app tracking.

The app's App Store privacy declaration is therefore **Data Not Collected**.
This statement covers data received by Vigil's developer; it does not override
the independent privacy and retention practices of a provider that the user
chooses to contact.

## Information Vigil handles on the device

To provide its core function, Vigil handles:

- provider credentials and account identifiers supplied or authorized by the
  user;
- provider-returned quota windows, reset times, balances, credits, spend,
  limits, and plan labels;
- bounded local history, refresh timing, and notification state; and
- appearance, privacy, alert, and automatic-check preferences.

Credentials are stored in the device's ThisDeviceOnly Keychain. Normalized
account references, readings, history, and preferences are stored in Vigil's
local App Group container so the app and its widget can share them. Vigil does
not put bearer credentials in that container.

## Direct provider requests

Vigil sends authentication and usage requests directly from the device to only
the providers the user activates. The chosen provider receives the credential,
account identifier, network address, and request data needed to service that
request under its own terms and privacy policy. Vigil's developer cannot read
those requests or responses.

Provider network sessions are ephemeral, use no shared app cookie store, and do
not keep an HTTP response cache. Provider approval pages open in the user's
browser, where browser and provider privacy rules apply.

## Apple system features and backups

If the user enables them, Vigil can place data in local notifications, Home
Screen widgets, and Lock Screen widgets. Vigil provides settings for generic
notification text and hidden widget values. Face ID or Touch ID can protect the
app surface, but does not add a separate encryption layer to stored records.

Vigil does not implement cloud sync. Apple-managed device backups may include
eligible local app-container data. ThisDeviceOnly Keychain credentials do not
synchronize through iCloud Keychain or migrate to another device.

## Diagnostic exports and support

A diagnostic report is created only when the user chooses to export it. It
excludes credentials, authorization headers, cookies, raw provider responses,
and free-form account labels, but can contain provider identifiers, dates,
status, and bounded usage or billing metadata. Once the user saves or shares an
export, the selected destination controls it.

Support requests are made outside the app through the public
[Vigil support page](support.md). Information voluntarily included in a support
request is handled by the selected support service and is not automatically
sent by Vigil. Users should never include API keys, tokens, cookies, or raw
authorization headers in a support request.

## Retention, deletion, and revocation

Vigil retains local account data while that provider connection remains in the
app, subject to its bounded history limits. Removing a connection deletes its
Vigil Keychain credential, account reference, current readings, local history,
polling state, and Vigil notifications from the device. Vigil reports a failed
deletion instead of claiming success.

Removing a connection does not delete the provider account, provider-side
records, an Apple-managed backup, or a diagnostic file the user already
exported. Users can separately revoke a credential or close an account through
the provider. Users who plan to uninstall Vigil should remove their connections
in the app first so deletion can be verified.

The detailed [privacy, deletion, and notification guide](user-guide/privacy-deletion-notifications.md)
documents these boundaries and the recovery-only full local reset.

## Children

Vigil is not directed to children and does not knowingly collect personal data
from children. The app does not contain user-generated or age-restricted
content.

## Changes and contact

This policy will be updated when Vigil's data practices change. The effective
date above identifies the current version. Questions or privacy concerns can be
submitted through [Vigil support](support.md). Security issues should follow the
private-reporting guidance in [SECURITY.md](../SECURITY.md), not a public issue.

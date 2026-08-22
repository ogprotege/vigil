# Security policy

> Status: current
>
> Last reviewed: 2026-08-22
>
> Review again: after any authentication, storage, network, notification, widget, export, or deletion change

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature when **Report a vulnerability** appears under the repository's Security tab.

If no private channel is available, open a minimal public issue asking the maintainers to establish private contact. Do not disclose the vulnerability in that issue.

Never include:

- access or refresh tokens;
- API keys or session cookies;
- provider account IDs;
- raw authentication codes;
- unsanitized provider responses;
- billing or balance details;
- screenshots or logs containing any sensitive value.

Revoke or rotate any credential exposed during testing or reporting.

Include only the minimum safe context:

- affected Vigil version and build;
- iOS version and device model;
- affected provider ID;
- steps using dummy values;
- security impact;
- sanitized error class or response shape.

Do not test against accounts, devices, or provider infrastructure you do not own or have permission to use.

## Security model

Vigil is an iOS-only local client. It has no collection server. Credentials are entered or minted on the phone and stored in Apple Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. They do not sync through iCloud Keychain or migrate to another device. After the first unlock following a reboot, the app and widget can access them while the device is locked when iOS permits background work.

Usage snapshots, history, account labels, poll leases, and notification metadata live in the App Group container. Those files contain no bearer credentials, but they can reveal usage, balance, spending, reset times, and account timing. Vigil does not mark these records as excluded from Apple-managed device backups.

The optional app lock protects the app surface and app-switcher snapshot. It does not hide widgets or notification previews. Local threshold notifications can reveal a provider name, quota window, and utilization.

Provider requests travel directly from the device to the activated provider over operating-system TLS. Vigil does not pin provider certificates. Some providers use undocumented consumer endpoints or broad credentials, so endpoint drift and credential authority remain accepted risks.

Read [the privacy guide](docs/user-guide/privacy-deletion-notifications.md) for user-facing storage and deletion boundaries. Read [docs/threat-model.md](docs/threat-model.md) for the complete assets, trust boundaries, controls, accepted risks, and exclusions.

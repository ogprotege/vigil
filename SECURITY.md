# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature for this repository when the **Report a vulnerability** button is available under the Security tab.

If no private reporting channel is available, open a minimal public issue asking the maintainers to establish private contact. Do not describe the vulnerability in that issue.

Never include:

- access tokens or refresh tokens;
- API keys;
- `vigil1` payloads or QR images;
- provider account IDs;
- raw credential files;
- unsanitized provider responses;
- billing or balance details;
- screenshots or logs containing any of the above.

Revoke or rotate any credential that was exposed during testing or reporting.

Include only the minimum safe context:

- affected Vigil and `vigil-link` versions;
- platform and OS version;
- affected provider ID;
- reproducible steps with dummy values;
- security impact;
- a sanitized error class or response shape.

Do not test against accounts, devices, or provider infrastructure you do not own or have permission to use.

## Security model

Read [docs/threat-model.md](docs/threat-model.md) for assets, trust boundaries, controls, accepted risks, and out-of-scope attacks. Important limits include plaintext QR handoff, undocumented provider endpoints, broad provider credentials, local usage metadata, and operating-system-controlled background freshness.

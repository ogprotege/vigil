# Architecture decision records

These records explain durable technical choices. They do not replace current
product, provider, security, or release documentation.

> Status: current index
>
> Last reviewed: 2026-07-26
>
> Review again: whenever an ADR is accepted, amended, or superseded

## Status meanings

- **Proposed:** under review and not yet authoritative.
- **Accepted:** governs the current implementation.
- **Amended:** still governs, with later constraints recorded in the same ADR.
- **Superseded:** retained only to explain historical code or decisions.

An ADR should state what changed, why it changed, its consequences, and the
code or tests that enforce it. When a decision no longer governs, mark it
superseded. Do not rewrite its original historical rationale as though it never
existed.

## Index

| ADR | Current status | Scope |
|---|---|---|
| [0001](0001-on-device-only.md) | Accepted, amended | On-device provider access with no Vigil backend |
| [0002](0002-xcodegen.md) | Accepted | XcodeGen manifest as the Xcode project source |
| [0003](0003-plaintext-qr.md) | Superseded | Retired desktop QR handoff format |
| [0004](0004-stateless-cli.md) | Superseded | Retired `vigil-link` CLI state policy |
| [0005](0005-mint-dont-copy.md) | Accepted, amended | Vigil-owned Claude OAuth credentials and refresh ownership |
| [0006](0006-vigil-link-name.md) | Superseded | Retired npm package naming decision |
| [0007](0007-hand-rolled-prompts.md) | Superseded | Retired CLI prompt implementation |

ADRs 0003, 0004, 0006, and 0007 are historical. They must not be cited as
instructions for current setup or release work. Vigil is an iOS-only product
with phone-native account setup.

## Creating or changing an ADR

1. Use the next four-digit number.
2. State one decision in the title.
3. Include `Status`, `Date`, `Decision`, `Context`, `Consequences`, and
   `Enforcement` sections.
4. Link directly to primary code and tests.
5. Update this index in the same pull request.
6. If the decision replaces another ADR, mark the earlier record superseded
   and cross-link both records.

Release readiness belongs in `docs/releases/`. Work-in-progress investigation
belongs in `dev/active/`. Completed evidence belongs in `dev/archive/` or a
release evidence directory.

<div align="center">

<img src="assets/icon-256.png" alt="Vigil reserve gauge" width="80" />

# Vigil documentation

### *Use the app. Understand the data. Build and ship it.*

<p>
<a href="../README.md">Back to README</a>
</p>

</div>

> Status: current documentation
>
> Last reviewed: 2026-08-09
>
> Review again: before each release

## Choose your route

| Use Vigil | Understand the data | Build and ship |
|---|---|---|
| [Set up an account](user-guide/setup.md) | [Read limits correctly](user-guide/reading-limits.md) | [Understand the architecture](development/architecture.md) |
| [Review history and imports](user-guide/history-and-imports.md) | [Read the product contract](product-contract.md) | [Set up development](development/development.md) |
| [Control privacy and deletion](user-guide/privacy-deletion-notifications.md) | [Check provider support](providers/support-matrix.md) | [Run the test gates](development/testing.md) |
| [Fix a problem](user-guide/troubleshooting.md) | [Review the threat model](threat-model.md) | [Prepare an iOS release](development/release.md) |

## Use Vigil

These guides describe the current product from the user's side of the screen.

- **[Setup](user-guide/setup.md)** covers the guided Claude and ChatGPT/Codex routes, the supported provider catalog, widgets, re-linking, and removal.
- **[Reading limits](user-guide/reading-limits.md)** explains urgency ranking, percentages, exact amounts, reset handling, freshness, and degraded states.
- **[History and imports](user-guide/history-and-imports.md)** separates local observations from official provider history.
- **[Privacy, deletion, and notifications](user-guide/privacy-deletion-notifications.md)** covers Keychain storage, local files, backups, appearance, automatic checks, alert and widget privacy, app lock, exports, and deletion.
- **[Privacy Policy](privacy.md)** is the public policy linked from the app and App Store listing.
- **[Support](support.md)** routes setup help, credential-free diagnostics, bug reports, and private security reports.
- **[Troubleshooting](user-guide/troubleshooting.md)** gives the correct response for common setup, provider, and storage states.
- **[When a provider changes](user-guide/provider-changes.md)** explains the **Provider changed** state, retained data, unverified saves, and how to report a change so a fix can ship.

## Understand the data

- **[Product contract](product-contract.md)** controls what Vigil promises and what every screen must refuse to imply.
- **[Provider support matrix](providers/support-matrix.md)** is the canonical shipped-provider list, with credentials, data coverage, evidence, and stability.
- **[Provider details](providers/provider-details.md)** records authentication and interpretation rules for each integration.
- **[Unsupported candidates](providers/unsupported-candidates.md)** explains why an unlisted service, including Perplexity, is not silently available through **Other provider**.
- **[Threat model](threat-model.md)** defines security boundaries, protected data, accepted risks, and mitigations.

## Build and ship

- **[Architecture](development/architecture.md)** maps the app, widget, provider client, persistence, scheduling, and diagnostic boundaries.
- **[Development setup](development/development.md)** owns requirements, XcodeGen, local builds, signing behavior, and repository layout.
- **[Testing](development/testing.md)** owns package, simulator, documentation, fixture, and device-only gates.
- **[Provider contribution](development/provider-contribution.md)** is the complete integration checklist.
- **[Diagnostic schema](development/diagnostic-schema.md)** defines the credential-free export boundary.
- **[iOS release runbook](development/release.md)** controls archive, signing, approval, upload, and TestFlight verification.
- **[Current 1.0.0 (25) release record](releases/1.0.0-25.md)** records the exact public-release candidate and every remaining gate.
- **[Architecture decisions](decisions/README.md)** preserves durable technical decisions and their status.
- **[Documentation health](documentation-health.md)** tracks review triggers and known documentation debt.

<details>
<summary><strong>Stable compatibility links</strong></summary>

Older public paths remain available so external links do not break. Each one
points to the canonical current guide instead of maintaining a second copy.

- [Getting started](getting-started.md)
- [FAQ](faq.md)
- [Privacy](privacy.md)
- [Troubleshooting](troubleshooting.md)

</details>

## Documentation authority

> **One claim, one owner.** The product contract controls user-facing promises.
> `protocol/providers.json` controls the reviewable provider contract.
> `apps/apple/project.yml` controls the platform and release identity.

The app ships a compiled `ProviderRegistry` mirror of the JSON provider
contract. `SpecParityTests` require both definitions to match. Fixture parity
tests verify normalized output. Provenance tests verify every fixture's declared
evidence source.

Historical plans, screenshots, and diagnosis reports remain evidence of earlier
work. They are not current setup instructions unless an active document links
to them for a specific reason.

## Current scope

Vigil ships as a native iOS app. The Swift package can run tests on macOS, but
there is no shipped macOS app or desktop credential-transfer utility.

The product centers on current provider limits and provider-reported metrics.
History begins when Vigil successfully observes an account, except for a
supported official provider import. Perplexity is not in the shipped provider
registry.

## Maintenance rule

When behavior changes, update its canonical document in the same pull request.
Compatibility pages should link to that source instead of copying it. Follow
the review triggers and open debt in [Documentation health](documentation-health.md).

Run the documentation gate from the repository root:

```sh
scripts/check-docs.sh
```

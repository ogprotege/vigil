# Vigil documentation

This index is the entry point for current Vigil documentation.

> Status: current documentation
>
> Last reviewed: 2026-07-27
>
> Review again: before each release

## Start here

- [Product contract](product-contract.md): what Vigil promises, what it cannot know, and the rules every screen must follow.
- [Setup](user-guide/setup.md): guided sign-in, supported providers, widgets, re-linking, and account removal.
- [Reading limits](user-guide/reading-limits.md): urgency ranking, percentages, exact amounts, reset handling, and status labels.
- [History and imports](user-guide/history-and-imports.md): local observations, retention, and the separate OpenAI API organization import.
- [Privacy, deletion, and notifications](user-guide/privacy-deletion-notifications.md): credentials, local files, backups, alerts, app lock, exports, and deletion.
- [Troubleshooting](user-guide/troubleshooting.md): common states and the correct response.

## Stable compatibility links

Older links remain available and point to the canonical guides:

- [Getting started](getting-started.md)
- [FAQ](faq.md)
- [Privacy](privacy.md)
- [Troubleshooting](troubleshooting.md)

## Provider references

- [Provider support matrix](providers/support-matrix.md): canonical shipped-provider list, data coverage, evidence, and stability.
- [Provider details](providers/provider-details.md): authentication and interpretation rules for each integration.
- [Unsupported candidates](providers/unsupported-candidates.md): why an unlisted provider, including Perplexity, is not silently available through Other provider.

## Development and release

- [Architecture](development/architecture.md)
- [Development setup](development/development.md)
- [Testing](development/testing.md)
- [Provider contribution](development/provider-contribution.md)
- [Diagnostic schema](development/diagnostic-schema.md)
- [iOS release runbook](development/release.md)
- [Current 0.15.0 (17) release record](releases/0.15.0-17.md)
- [Architecture decisions](decisions/README.md)
- [Documentation health and debt](documentation-health.md)

## Documentation authority

The product contract controls user-facing claims. `protocol/providers.json` is the reviewable provider contract. The app ships the compiled `ProviderRegistry` mirror, and `SpecParityTests` require the two definitions to match. The XcodeGen manifest in `apps/apple/project.yml` controls the current platform and release version.

Historical plans, screenshots, and diagnosis reports are evidence of earlier work. They must not be used as current setup instructions unless an active document links to them for a specific reason.

## Current scope

These guides describe the iOS-only app. The Swift package can run tests on macOS, but Vigil does not ship a macOS app or desktop credential-transfer utility.

The current product centers on present limits and provider-reported metrics. History begins when Vigil starts observing an account, except for a supported official provider import. Perplexity is not in the shipped provider registry.

## Maintenance rule

When behavior changes, update the product contract and the affected guide in the same pull request. Keep one canonical source for each claim and link to it from compatibility pages. Follow the review triggers in [Documentation health](documentation-health.md).

# Documentation health

This page records documentation coverage, review triggers, and known debt. It is not a product roadmap or a release ledger.

> Status: current
>
> Last reviewed: 2026-08-12
>
> Review again: before each release and after any product-boundary change

## Current health

The current documentation set is aligned with Vigil 1.0.0, build 25. The product contract, user guides, provider references, development guides, and release procedure have distinct owners and scopes. Build 25 is the App Review and Internal TestFlight binary: it carries the build 24 lifecycle fix and updates Grok Build to the provider's weekly credits contract. Builds 24 and 23 remain documented as superseded public candidates.

No known critical documentation defect remains open. Historical organization remains explicit debt. The build 25 release record now includes owner-attested physical-device acceptance evidence.

| Area | Canonical source | State | Review trigger |
|---|---|---|---|
| Product claims | [Product contract](product-contract.md) | Current | Any user-facing behavior or data claim |
| Setup and interpretation | [User guides](user-guide/setup.md) | Current | Setup, presentation, history, privacy, or recovery change |
| Provider support | [Support matrix](providers/support-matrix.md) | Current | Registry, mapping, endpoint, credential, or evidence change |
| Architecture and development | [Development architecture](development/architecture.md) | Current | Storage, scheduling, lifecycle, build, or diagnostic change |
| Security and privacy | [Security policy](../SECURITY.md) and [privacy guide](user-guide/privacy-deletion-notifications.md) | Current | Storage, network, Keychain, notification, widget, export, or deletion change |
| Release procedure | [iOS release runbook](development/release.md) | Current | Signing, CI, archive, upload, or App Store Connect change |
| Release evidence | [1.0.0 (25) record](releases/1.0.0-25.md) | Current (App Review waiting; device walk passed) | Every completed or failed release gate |
| Decisions | [ADR index](decisions/README.md) | Current | A durable architectural decision is accepted, amended, or superseded |

## Known documentation debt

| ID | Priority | State | Debt | Completion condition |
|---|---|---|---|---|
| `VIGIL-DOC-001` | Medium | Open | Completed diagnosis and removal plans still live in historical source directories. Entry points identify them as historical, but the full move is deferred to avoid obscuring review history during the 0.15.0 release. | Move them with history into `dev/archive/`, repair links, and update the archive index after the release closes. |
| `VIGIL-DOC-002` | Low | Open | CI validates local links and structural rules, but it does not make network requests to validate external links. | Add a rate-limited external-link job or record a manual external-link check at release time. |
| `VIGIL-DOC-003` | Medium | Resolved 2026-08-12 | Physical-device setup, Keychain, App Group, widget, notification, and background behavior cannot be proven by repository documentation or simulator tests alone. | The active build-25 release record now captures the owner's completed TestFlight device walk. |
| `VIGIL-DOC-004` | Medium | Ongoing | Experimental provider endpoints can change without a repository change. | Recheck evidence before promoting an integration or after a reported provider failure. |

## Review schedule

- Before every release, review the index, product contract, privacy guide, support matrix, release runbook, and active release record.
- With every provider change, review the support matrix, provider details, fixture provenance, and contribution guide.
- With every persistence or lifecycle change, review history, privacy, architecture, diagnostics, and deletion claims.
- With every signing or CI change, review the testing guide, release runbook, and documentation checks.
- After a release closes, archive completed working reports and update this debt table.

## Pull request rule

A behavior change is incomplete until its canonical documentation changes in the same pull request. Compatibility pages should link to canonical material instead of copying it. Historical evidence should receive a dated banner or move to the archive. The documentation check must pass before merge.

## Automated checks

Run from the repository root:

```sh
scripts/check-docs.sh
```

The check validates required current documents, local Markdown links, review metadata, balanced code fences, canonical-path usage, and version/build consistency with `apps/apple/project.yml`.

# Development archive

> Status: current archive policy
>
> Last reviewed: 2026-07-26
>
> Review again: when development evidence is archived

This directory holds completed or superseded development material. Archived
files preserve how a decision was reached. They do not describe the current
product, provider contract, test gate, or release status.

Use the current documentation index for authoritative behavior. Use
`docs/releases/` for release status and `docs/development/release.md` for the
release procedure.

## What belongs here

- completed product diagnoses and implementation reports;
- superseded design specifications and implementation plans;
- old runtime screenshots retained as evidence;
- investigations whose conclusions have been applied elsewhere;
- historical desktop, CLI, QR, or Mac-handoff material.

Unfinished work remains in `dev/active/`. A release's canonical evidence record
remains in `docs/releases/`. Large sanitized supporting evidence may live in
`dev/releases/<version>-<build>/`.

## Required archive banner

Every archived Markdown entry point must begin with a notice like this:

> **Archived on YYYY-MM-DD.** This document is historical. It does not describe
> the current product or release status. See `<current document>`.

The notice must name the current replacement when one exists. Screenshots
should have a sibling README that identifies their source commit, simulator or
device, date, and superseded UI state.

## Archive procedure

1. Identify the current document that replaces the material.
2. Move the directory with `git mv`. Preserve its internal evidence and history.
3. Add the archive banner to its Markdown entry points.
4. Repair incoming and outgoing relative links.
5. Remove archived files from current documentation indexes.
6. Add the destination to this README's archive index.
7. Run the documentation link and stale-reference checks.

Do not silently rewrite historical claims to match current behavior. Add a
banner or a dated correction. This preserves the evidence while preventing an
old plan from becoming an accidental instruction.

## Planned initial moves

These moves require their own reviewed patch. They are not performed merely by
adding this README.

| Current path | Proposed archive path | Current replacement |
|---|---|---|
| `dev/active/vigil-ios-product-diagnosis/` | `dev/archive/2026-07-26-vigil-ios-product-diagnosis/` | Current product, architecture, privacy, provider, and release documentation |
| `docs/superpowers/specs/2026-07-21-ios-only-remove-vigil-link-design.md` | `dev/archive/2026-07-21-ios-only-removal/design.md` | Current architecture and onboarding documentation |
| `docs/superpowers/plans/2026-07-21-ios-only-remove-vigil-link.md` | `dev/archive/2026-07-21-ios-only-removal/plan.md` | Current development and release documentation |

Before moving the diagnosis directory, copy or relocate any release-specific
evidence still needed by `dev/releases/0.15.0-16/`. Do not leave the same report
under both `active` and `archive`.

## Archive index

No moves have been applied yet.

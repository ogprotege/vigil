# ADR-0006: npm package name "vigil-link"

**Status:** accepted

## Decision

The companion CLI publishes as `vigil-link` (unscoped).

## Context

`vigil` and `vigil-cli` are taken on npm (verified July 2026). `vigil-link` is free, unscoped (so `npx vigil-link` works bare), and self-describing — the command's job is linking. Runner-ups considered: `getvigil`, `vigil-monitor`.

## Consequences

- Onboarding copy everywhere uses `npx vigil-link`.
- ~~Publish a 0.0.x placeholder early to reserve the name~~ Done 2026-07-18 — the name was reserved by publishing the real CLI (`vigil-link@0.1.0`, patched to `0.1.1` the same day).

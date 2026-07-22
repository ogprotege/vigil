# ADR-0006: npm package name "vigil-link"

> **Status: superseded (2026-07-21).** Vigil is iOS-only and phone-native; the
> `vigil-link` CLI and the `vigil1` QR protocol were removed. Kept for the
> historical rationale.

**Previous status:** accepted

## Decision

The companion CLI publishes as `vigil-link` (unscoped).

## Context

`vigil` and `vigil-cli` are taken on npm (verified July 2026). `vigil-link` is free, unscoped (so `npx vigil-link` works bare), and self-describing — the command's job is linking. Runner-ups considered: `getvigil`, `vigil-monitor`.

## Consequences

- The `vigil-link` name appears only in the optional computer-handoff flow;
  primary onboarding is on-device sign-in (Sign in with Claude / Sign in with
  Codex / paste an API key), which never mentions the CLI.
- ~~Publish a 0.0.x placeholder early to reserve the name~~ Done 2026-07-18 — the name was reserved by publishing the real CLI (`vigil-link@0.1.0`, patched to `0.1.1` the same day).

# ADR-0004: The CLI is credential-stateless

> **Status: superseded (2026-07-21).** Vigil is iOS-only and phone-native; the
> `vigil-link` CLI and the `vigil1` QR protocol were removed. Kept for the
> historical rationale.

**Previous status:** accepted, amended 2026-07-18

## Decision

`vigil-link` never writes credentials or provider usage values to disk. Every invocation rediscovers or re-mints credentials.

The CLI does persist the minimum state required to prevent accidental rapid polling:

- last attempt timestamp;
- next allowed timestamp;
- consecutive 429 count.

This state is provider-level and contains no credential, account ID, usage value, spend, balance, label, or response body.

State location priority:

1. `VIGIL_STATE_DIR`
2. `$XDG_CACHE_HOME/vigil-link`
3. `~/.cache/vigil-link`

## Context

A tool that handles OAuth tokens and API keys must remain easy to audit. Credential persistence is unnecessary for a link tool.

Pure process statelessness created a separate safety defect. Repeated `status`, `doctor --live`, and link verification commands could bypass provider poll floors because each process started with an empty scheduler. Claude can impose hard 429 responses without `Retry-After`.

A timestamp-only cache preserves the important credential boundary while enforcing poll policy across CLI processes.

## Consequences

- `status`/`doctor` always reflect the live credential files, never a stale cache.
- The mint flow's tokens exist only in process memory and the rendered QR.
- The CLI creates an owner-only cache directory and atomic JSON state files.
- A cross-process directory lock serializes reservation.
- Reservation is written before network I/O.
- If safety state cannot be read or written, the live request is deferred.
- Deleting the cache can cause an extra provider request and is not a supported way to bypass rate limits.

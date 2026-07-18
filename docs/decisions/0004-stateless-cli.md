# ADR-0004: The CLI is stateless

**Status:** accepted

## Decision

`vigil-link` never writes credentials (or anything else) to disk. No `~/.vigil` directory exists. Every invocation rediscovers or re-mints credentials.

## Context

A tool that asks users to trust it with OAuth tokens must be trivially auditable. "It has no persistence layer — read the source" is the strongest possible trust story, and the cost (occasional re-auth on repeat runs) is small for a tool used at link time.

## Consequences

- `status`/`doctor` always reflect the live credential files, never a stale cache.
- The mint flow's tokens exist only in process memory and the rendered QR.

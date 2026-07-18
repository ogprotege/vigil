# ADR-0001: On-device only — no Vigil servers

**Status:** accepted

## Decision

Vigil has no backend. The app talks directly to provider endpoints with the user's own credentials; credentials live only in the device Keychain; the CLI is a transient linking tool.

## Context

A cloud relay would give true push freshness, but means user OAuth tokens on someone else's server, a privacy story to defend, hosting costs, and an account system — all antithetical to "simple, efficient, trustworthy". iOS background limits are real but survivable: client-computed countdowns keep the UI live between fetches, and the macOS menu bar app (always-running) becomes the near-realtime surface.

## Consequences

- App Store privacy label is "Data Not Collected", truthfully.
- Freshness on iOS is bounded by widget budget + BGAppRefreshTask opportunism; we are honest about this in-product.
- A future *user-owned* relay (Mac companion pushing to the phone) can be added without breaking this ADR — the trust boundary stays the user's own hardware.

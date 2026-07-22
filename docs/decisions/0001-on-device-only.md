# ADR-0001: On-device only — no Vigil servers

**Status:** accepted (amended 2026-07-22 for the iOS-only product)

## Decision

Vigil has no backend. The iOS app talks directly to provider endpoints with the user's own credentials. Credentials live only in the device Keychain and every account is provisioned on the phone.

## Context

A cloud relay would give true push freshness, but it would place user credentials on someone else's server and require hosting plus an account system. That conflicts with the product's privacy goal. iOS background limits are real but survivable. Client-computed countdowns keep the UI useful between opportunistic app and widget refreshes.

## Consequences

- App Store privacy label is "Data Not Collected", truthfully.
- Freshness on iOS is bounded by widget budget + BGAppRefreshTask opportunism; we are honest about this in-product.
- A future user-owned relay would require a new product and security decision. It is not part of the current Vigil architecture.

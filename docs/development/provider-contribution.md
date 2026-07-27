# Provider contribution guide

- Status: Current
- Last reviewed: 2026-07-26
- Review again: whenever the provider registry, mapper vocabulary, fixture policy, or onboarding catalog changes

Adding a provider is a contract change, a security change, and a user-facing truth claim. A provider is not complete when one sample response renders.

Read the [architecture](architecture.md), [testing guide](testing.md), and [support matrix](../providers/support-matrix.md) before editing provider code.

## 1. Prove the data source

Start with an account-specific endpoint that returns at least one of these:

- Reset-based quota utilization
- Exact used, limit, or remaining allowance
- Balance
- Spend
- Counted usage suitable for official history

A subscription page or published plan ceiling is not live account usage. Do not derive a current denominator from a plan name.

Do not design an integration around another iOS app's private container, Keychain item, browser cookie database, or response cache. Vigil can use only credentials the user authorizes for Vigil and data the provider returns to Vigil.

Record one evidence class:

- `live_sanitized`
- `vendor_example`
- `community_research`
- `synthetic_derived`

If the endpoint is undocumented or supported only by community research, set `experimental: true`. The app derives its setup and account warning from that flag.

## 2. Decide the authentication owner

Prefer a provider-supported phone authorization flow when it can mint a credential for Vigil.

For a direct credential:

- State exactly what the user must create or copy.
- State any required account identifier.
- Use a secure field in setup.
- Verify before saving when the endpoint is reachable.
- Mark manually entered credentials with `source: manual`.
- Never rotate a manual refresh token.

If a new guided flow mints a refreshable pair, use `source: mint` only after the complete exchange is verified. Add pure request and parsing helpers to `VigilKit`, then keep browser presentation and polling in the app target.

Account identifiers are required when `{account_id}` appears in the URL or a header template. `RequestBuilder` refuses to construct that request without the value.

## 3. Add the reviewable contract

Add the provider to `protocol/providers.json`.

At minimum, define:

- Stable lowercase provider ID
- Display name
- Authentication shape
- HTTP method, URL template, and headers
- Poll floor, jitter, and rate-limit backoff
- A registry guidance string required by current parity and presentation tests, even if a guided provider does not expose a manual route
- Windows, metrics, or metric collections
- Required-output rules
- Capabilities
- Experimental status when applicable

Use the generic registry vocabulary before adding provider-specific parsing code.

### Window rules

A window needs a stable ID, a utilization path or exact used/limit values, reset format, primary or secondary status, and duration when known.

Use `conditions`, `anyConditions`, or duration rules when a collection contains several record types. Use `exhaustiveCollections` when an unknown identity, duplicate required identity, or unsupported duration must invalidate the response.

Use `requiredWhenPresent` for optional collections whose eligible entries must map completely when the collection exists.

### Metric rules

Choose the semantic kind that matches the provider field:

- `balance`
- `spend`
- `limit`
- `remaining`

Declare the unit and any scale explicitly. A money response must prove whether the value is dollars, cents, minor units with an exponent, or another currency representation.

Use `requires`, `requiresPresent`, `equalFields`, `requiresPositive`, and `incompleteWhenAnyRequiredPresent` to prevent partial money or allowance pairs from looking valid.

### Required-output rules

An HTTP 200 must not become Live merely because one unrelated value mapped.

Use the narrowest complete contract:

- Minimum windows and primary windows
- Required window IDs
- Minimum metrics and required metric IDs
- Required paths or conditions
- Typed conditions required only when an optional wrapper is present
- Paths that must be absent or null
- Recognized empty states for a valid unlimited or empty account

When a new response shape cannot be interpreted safely, prefer `schemaChanged` over partial success.

## 4. Add the Swift runtime mirror

Add the matching `ProviderSpec` to `ProviderRegistry` in:

`packages/VigilKit/Sources/VigilKit/Providers/ProviderSpec.swift`

Then add it to `ProviderRegistry.all`. The JSON and Swift values must match exactly. `SpecParityTests` check request configuration, mappings, required-output rules, conditions, OAuth values, and manual guidance.

Do not read `protocol/providers.json` from the shipping app. The compiled Swift mirror is intentional.

## 5. Add fixtures and provenance

For each accepted shape, add:

- `protocol/fixtures/<provider>-<case>.json`
- `protocol/fixtures/<provider>-<case>-expected.json`

The expected file is a hand-authored oracle. Do not generate it from the mapper being tested.

Add each input to `protocol/fixture-provenance.json` with:

- Evidence class
- Source ID
- Verification date
- A precise note about capture, sanitation, modeling, and limits

Add each referenced source to the `sources` object. Use a durable vendor page, commit, or pinned public implementation where possible.

Never commit an unsanitized response. Remove account identifiers, balances that could identify a user, tokens, cookies, headers, names, and opaque IDs. Preserve only the structure needed to prove mapping behavior.

## 6. Cover failure boundaries

Add fixtures or unit tests for the boundaries relevant to the provider:

- 401 or 403 authentication failure
- 429 rate limit
- Provider-specific error envelope
- Missing required field
- Partial money pair
- Wrong currency or denomination metadata
- Null optional window
- Unknown collection identity
- Duplicate required identity
- Unsupported or hostile duration
- Non-finite, negative, or out-of-range number
- Pagination that would make a current aggregate incomplete
- Valid unlimited or empty account

The classifier may retain diagnostic partial output internally. Shipping surfaces preserve the last accepted snapshot and show the degraded status.

## 7. Add presentation and setup

Direct-credential providers appear automatically in `ProviderCatalogView` through `ProviderRegistry.all`, except for the explicitly guided Claude and Codex entries.

Update `ProviderPresentation` when the new provider needs:

- A symbol or tint
- A special credential label
- A provider-specific account-ID label
- A credential-authority warning

Keep policy derived from the spec when possible. Do not create another provider list in a view.

Add presentation tests for provider count, experimental status, account-ID requirement, setup label, and warning copy. Verify that the provider can be selected, linked, re-linked, removed, and fully reset.

## 8. Protect history and diagnostics

Every accepted current snapshot enters observed history. Confirm that the provider's IDs, labels, units, reset timestamps, exact values, and secondary flags survive the normalized history conversion.

If the provider offers official history, keep imported records under `providerBackfill`. Add a dedicated client and conversion layer. Do not label a provider bucket as a device observation.

Diagnostic export does not expose provider-controlled labels, units, or identifiers. A new provider ID is exported only because it becomes a trusted registry ID. Add hostile diagnostic values and prove that secrets cannot cross the allow-list boundary.

## 9. Update documentation

Update these canonical files:

- [Provider support matrix](../providers/support-matrix.md)
- [Provider details](../providers/provider-details.md)
- [Unsupported candidates](../providers/unsupported-candidates.md), when promoting a listed candidate

Do not copy the full provider table into another guide.

## 10. Run the gates

Run every command in [Testing](testing.md). A provider change requires the package suite, complete Xcode scheme, and property-list/entitlement lint.

When authentication endpoints changed, run the opt-in live auth probes if the new flow has a credential-free starting request. Complete the human browser and physical-device checks before release.

## Review checklist

- [ ] Account-specific data source is identified.
- [ ] Evidence class and durable source are recorded.
- [ ] Experimental status matches the evidence.
- [ ] Authentication ownership is explicit.
- [ ] No other app's private storage is required.
- [ ] JSON contract and Swift mirror match.
- [ ] Exact amounts are provider-supplied or losslessly derived.
- [ ] Money denomination and scaling are proven.
- [ ] Required-output rules reject partial success.
- [ ] Accepted, empty, partial, and hostile fixtures exist.
- [ ] Expected files were hand-authored.
- [ ] Fixtures are sanitized and have provenance.
- [ ] Setup, re-link, removal, and reset are covered.
- [ ] Observed history retains the normalized data.
- [ ] Diagnostic export remains credential-free.
- [ ] Canonical provider documentation is updated.
- [ ] Package, app, UI, and lint gates pass.

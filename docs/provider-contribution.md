# Provider contribution guide

A provider is complete only when Vigil can accept its credential safely, map supported responses honestly, render meaningful output, and fail without contaminating other accounts. Editing `protocol/providers.json` is one part of the work.

## 1. Establish a supportable source

Record these facts before writing code:

- What meaningful value does the provider expose: reset window, spend, limit, remaining credit, or balance?
- Is the endpoint documented and intended for the user's account type?
- Which credential is required, and what authority does it grant?
- Can the credential be limited to read-only usage or billing access?
- Does the provider permit a local third-party client?
- What rate limit or `Retry-After` behavior is published or observed?
- Can a refresh credential rotate, and which client owns it?
- What supports the response shape: sanitized Vigil capture, vendor example, community research, or a synthetic derivation?

Do not derive a utilization percentage from unrelated values. If the provider exposes only a balance, map a balance metric.

New providers should remain opt-in until they have real-account validation, fixtures, phone UI review, and clear activation instructions.

Use `experimental: true` when the endpoint lacks both a stable vendor contract and a sanitized Vigil production capture.

## 2. Extend the registry

Add the provider to `protocol/providers.json`.

Typical policy includes:

- stable lowercase provider ID;
- display name;
- experimental state when required;
- request method, URL, query, and header templates;
- poll floor, jitter, and rate-limit backoff;
- manual-entry guidance;
- static and dynamic window mappings;
- scalar or collection metric mappings;
- response-envelope rules;
- required-output and structural contracts;
- capabilities.

Never place a credential, private client secret, real account ID, or unsanitized production body in the registry.

`protocol/providers.json` is canonical in intent. The app ships Swift constants, so the same runtime fields must be reflected in `ProviderRegistry`.

## 3. Implement phone activation

Every provider must have an iPhone setup path.

### Pasted credentials

Use the generic manual-entry flow when the provider accepts an API key, management key, session cookie, or similar credential.

Specify:

- the exact field label;
- where the user obtains it;
- whether a second account identifier is required;
- whether the credential is broad or can be read-only;
- whether it expires;
- whether regional hosts require different credentials.

Do not save the account until required fields are present and the Keychain write succeeds.

### OAuth or device authorization

Add a VigilKit authentication adapter when a provider needs a public-client flow.

Keep request and response construction UI-free and unit-testable. The app target owns browser presentation, user instructions, pending state, cancellation, and error copy.

Mint a credential owned by Vigil. Mark it with source `mint`. Refresh only that credential.

Never rotate a token pair pasted from another client. Refresh-token rotation can invalidate the owning client.

Do not embed a confidential client secret in the app.

## 4. Implement request and response mapping

Prefer registry-driven mapping:

- `windows` for known reset-based buckets;
- `sourceContainer`, ordered `sourceKeys`, typed `conditions`, and `omitWhen` for bounded alternatives;
- per-window `fields.used` and `fields.limit` when the provider supplies counts;
- `additionalWindows` for provider-defined dynamic collections;
- `additionalWindows.entryWindows` when one record contains nested primary and secondary windows;
- `metricMappings` for fixed scalar balances, spend, limits, or remaining amounts;
- `metricCollectionMappings` for arrays such as balances by currency;
- `responseEnvelope` for failures carried inside HTTP 2xx;
- `requiredPaths`, `absentOrNullPaths`, and `requiredConditions` for body-level contracts;
- `exhaustiveCollections` when every array identity or duration must be understood;
- `requiredOutputs` and `requiredWhenPresent` so partial output cannot become Live.

Direct percentages outside 0 through 100 are invalid. Ratio windows require nonnegative used values and a positive limit. Document any legitimate over-limit behavior.

Use root-relative field paths when a nested bucket shares a response-root reset or billing date.

Money requires explicit denomination handling. Use a validated exponent or scale. Never infer dollars from an unlabeled integer. Never combine currencies.

Raw-body validation rejects malformed UTF-8, duplicate semantic keys, non-finite decoded numbers, lone surrogates, and excessive depth or size. Add tests for any parser boundary exposed by the provider.

If generic mapping cannot express a required shape, add the smallest Swift adapter and document why. Unknown fields can be ignored only when the contract does not declare the collection or family exhaustive.

A successful response that fails required outputs becomes `schemaChanged`, even when another value maps. Partial output can remain diagnostic. The app must preserve the last successful snapshot rather than label the partial response Live.

## 5. Mirror the Swift registry

Update `packages/VigilKit/Sources/VigilKit/Providers/ProviderSpec.swift`.

Then update `SpecParityTests` decoding and assertions if the contract gained a new runtime field.

The parity test must compare every field that changes request behavior, mapping, required outputs, product labeling, or manual-entry guidance.

A JSON-only provider edit is incomplete because the shipped app does not load the repository JSON at runtime.

## 6. Add fixtures and provenance

Add fixture pairs under `protocol/fixtures/`:

```text
provider-case.json
provider-case-expected.json
```

Cover the contract, not only the happy path:

- normal response;
- optional and null fields;
- string decimal values when supported;
- multiple currencies or secondary windows;
- malformed present values;
- wrong object or array wrappers;
- missing required IDs or metrics;
- incomplete eligible dynamic entries;
- unknown or duplicate exhaustive identities;
- incomplete correlated money families;
- a response that must become `schemaChanged`.

Expected files are hand-authored normalized outputs. Never generate them with the mapper under test.

Sanitize tokens, emails, account IDs, request IDs, and distinctive production values.

List each input and expected file in [fixture-provenance.json](../protocol/fixture-provenance.json). Choose the narrowest true evidence class:

- `live_sanitized`: production body captured by Vigil and sanitized before commit;
- `vendor_example`: vendor-published response example;
- `community_research`: maintained independent client at a pinned revision;
- `synthetic_derived`: hand-authored case derived from another source.

A successful authorization request or HTTP 200 does not prove the body shape. Mapper parity does not create upstream evidence.

If a production body cannot be committed safely, leave the fixture modeled and record the live check separately without overstating provenance.

## 7. Review every iOS surface

Check:

- Add account picker, form labels, hints, validation, and experimental badge;
- Keychain write, update, migration, and deletion behavior;
- Home window and metric presentation;
- Models inclusion rules;
- Connections status, plan label, and freshness;
- threshold notifications;
- widget behavior for providers without percentage windows;
- multi-account identity and collision behavior;
- authentication, network, provider-drift, and storage-error copy.

Do not fill Models with an ordinary plan-wide row when no model-specific lane exists.

If a provider exposes only metrics, ensure percentage-only widgets fail honestly rather than inventing a gauge.

## 8. Update documentation

Update:

- [Provider registry and support](provider-spec.md);
- [Getting started](getting-started.md);
- [Troubleshooting](troubleshooting.md);
- [Threat model](threat-model.md) when credential authority changes;
- [README](../README.md);
- [Changelog](../CHANGELOG.md).

State endpoint stability and fixture provenance separately. Do not use "fixture-covered" as a synonym for live-validated.

## 9. Run the complete gate

```sh
swift test --package-path packages/VigilKit

cd apps/apple
xcodegen generate

xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO

DEVICE_UDID=$(xcrun simctl list devices available \
  | awk -F '[()]' '/^[[:space:]]+iPhone/ { print $2; exit }')
test -n "$DEVICE_UDID"
echo "Testing on simulator: $DEVICE_UDID"

xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  test CODE_SIGNING_ALLOWED=NO
```

Then test the provider on a physical phone with an account you own:

1. Add the credential through the intended onboarding path.
2. Confirm the first accepted snapshot contains every required output.
3. Confirm Home, Models, Connections, and widgets behave correctly.
4. Confirm one provider failure does not stop other accounts.
5. Confirm rate limiting and expired authentication produce the right state.
6. Remove the account and confirm credential and observation cleanup.

Never place a live credential in test output, shell history, screenshots, issue trackers, or committed fixtures.

## Definition of done

A provider is ready when:

- phone activation is implemented and documented;
- request policy obeys the provider poll floor and timeout;
- the Swift registry mirror matches `protocol/providers.json`;
- mapping handles normal, optional, malformed, and partial responses;
- required outputs prevent false-Live partial mapping;
- fixtures and expected outputs pass;
- every fixture has honest provenance;
- Home, Models, Connections, notifications, and widgets were reviewed;
- credentials and production account data stayed out of the repository;
- endpoint stability and experimental state are accurate;
- physical-device validation was completed when the release claims live support.

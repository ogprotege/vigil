# Provider contribution guide

A provider is complete only when Vigil can obtain credentials safely, map real responses honestly, render the result, and fail without affecting other providers. Editing `protocol/providers.json` is one part of that work.

## 1. Establish a supportable source

Record these facts before writing code:

- What value does the provider expose: reset window, spend, limit, remaining credit, or balance?
- Is the endpoint documented and intended for the user's account type?
- Which credential is required, and what authority does it grant?
- Can the credential be scoped to read-only usage?
- Does the provider permit local third-party clients?
- What are the published rate limits and `Retry-After` rules?
- Can a refresh token rotate, and which client owns it?
- What evidence supports the response shape: a sanitized Vigil capture, a vendor example, or community research?

Do not derive a fake utilization percentage from unrelated values. If the provider reports only a balance, map a `balance` metric.

Mark a provider opt-in with `"defaultEnabled": false` until it has real-account validation, fixtures, UI review, and clear activation instructions.

## 2. Extend the registry

Add the provider under `protocol/providers.json`.

Required policy usually includes:

- stable lowercase provider ID;
- display name and default-enabled state;
- request method, URL, and header templates;
- poll floor, jitter, and 429 backoff;
- discovery metadata;
- manual-entry guidance;
- window and/or metric mappings;
- capabilities.

Never put a credential, private client secret, real account ID, or production response in the registry.

## 3. Implement credential activation

The CLI routes discovery by `discovery.adapter`.

- Reuse `environment` for a user-supplied API key.
- Add a discovery adapter when credentials live in a provider-owned file or Keychain item.
- Add an OAuth mint adapter only for a public-client flow that has been verified.
- For an OAuth provider, also add an on-device sign-in implementation in VigilKit (pure request/response construction with no UI, unit-tested, minting its own token pair with source `"mint"`) alongside any CLI mint adapter, so the phone can provision the credential without a computer — this is the primary path (see `ClaudeAuth`/`CodexAuth`).
- Do not refresh credentials copied from another client if refresh-token rotation could invalidate that client.

Credential discovery must isolate failures. A broken provider must not stop the remaining `status`, `doctor`, or link report.

## 4. Implement response mapping

Use the generic mapping fields when possible:

- `windows` plus `responseFields` for reset-based utilization;
- exact `sourceContainer` plus `sourceKeys`, typed `conditions`, and `omitWhen` for compatible wrappers and selected array entries;
- per-window `fields.used` and `fields.limit` when the provider supplies counts instead of a percentage;
- `metricMappings` with `presencePaths`, paired requirements, equality checks, and denomination metadata for fixed scalar paths;
- `metricCollectionMappings` for arrays such as balances by currency;
- `additionalWindows.entryWindows` for provider-defined collections where one entry fans into nested windows;
- `responseEnvelope` for provider errors carried inside HTTP 2xx bodies;
- `requiredPaths`, `absentOrNullPaths`, and `requiredConditions` for body-level contracts;
- `exhaustiveCollections` when every array identity and duration must be understood;
- `requiredOutputs`, including primary-window minimums, and `requiredWhenPresent` so partial mapping cannot masquerade as Live.

Direct percentages outside 0 through 100 are invalid. Ratio windows require a nonnegative used value and a positive limit. If a provider can legitimately exceed its cap, document whether the UI caps that ratio at 100. Never silently clamp an impossible direct percentage.

The raw-body gate rejects malformed UTF-8, duplicate semantic object keys, leading `U+FEFF` inside strings, non-finite decoded numbers, lone surrogates, and excessive depth or size. Add mirrored TypeScript and Swift tests for any parser edge case a provider exposes.

If the schema needs provider-specific code, keep it small and document why generic mapping cannot express it. Unknown fields must be ignored. Invalid values must be skipped. A successful response that fails the provider's required-output contract must become `schemaChanged`, even when an unrelated window or metric still maps. Retain partial output at the classifier boundary for diagnosis; Apple surfaces must preserve the last successful snapshot instead of labeling the partial response Live.

Keep TypeScript and Swift behavior equal:

- TypeScript mapping and normalized types under `cli/src/providers/`;
- Swift models and mapping under `packages/VigilKit/Sources/VigilKit/`;
- Swift `ProviderRegistry` constants, which hand-mirror the JSON for runtime independence.

## 5. Add fixtures and provenance

Add fixture pairs under `protocol/fixtures/`:

```text
provider-case.json
provider-case-expected.json
```

Target at least two cases for a provider that will be called supported. Cover:

- a normal response;
- optional or `null` fields;
- string-encoded decimal values if applicable;
- multiple currencies or secondary windows if applicable;
- malformed data that should be skipped;
- the case where nothing valid maps and `schemaChanged` is expected.
- partial mapping where a required ID or eligible dynamic entry disappears.
- wrong object/array wrappers, duplicate identities, malformed typed flags, and incomplete correlated families.
- mixed-currency aggregate leaves and denomination mismatches when money is summed.

Expected files are hand-authored normalized outputs. Do not generate expected data with the mapper being tested.

Remove tokens, email addresses, account IDs, request IDs, and distinctive production amounts from fixtures.

Add every input and expected pair to [fixture-provenance.json](../protocol/fixture-provenance.json). Choose the narrowest evidence class that is true:

- `live_sanitized`: captured by Vigil from production, then sanitized. Record the observation date and a durable repository evidence link.
- `vendor_example`: copied from, or mechanically reduced from, a vendor-published example. Link the exact page or source revision.
- `community_research`: based on a maintained independent client. Pin the source revision, not a moving branch URL.
- `synthetic_derived`: hand-authored from another evidence source to test a boundary or inferred contract.

Do not call a fixture live because an authorization request succeeded, an endpoint returned 200, or both mappers agree. Live provenance requires the response body itself. If a real body cannot be committed safely, keep the fixture modeled and record the provider-level live check separately.

The expected file is a normalization oracle, not upstream evidence. Hand-author it from the product contract and review it separately from the mapper.

## 6. Review every surface

Check more than the core mapper:

- CLI `status` labels and scalar formatting;
- `doctor` activation guidance;
- QR and paste payload size;
- on-device OAuth sign-in view + flow (ClaudeAuth/CodexAuth-style) for OAuth providers;
- Apple manual-entry hint and required fields;
- dashboard rendering for windows and metrics;
- menu-bar fallback for providers without a session window;
- widget behavior for providers without `session` and `weekly`;
- account identity and multi-account collision behavior;
- storage-error and authentication-error copy.

If a surface cannot represent the provider yet, document that limitation instead of showing an empty success state.

## 7. Update documentation

Update:

- [provider-spec.md](provider-spec.md), including the support matrix and official reference;
- [troubleshooting.md](troubleshooting.md);
- [threat-model.md](threat-model.md) when a credential introduces new authority;
- [../README.md](../README.md) if the provider is user-facing;
- [../CHANGELOG.md](../CHANGELOG.md).

State the endpoint's documentation status and the fixture evidence class separately. Link the corresponding provenance entry. Never use "fixture-covered" as a synonym for live-validated.

## 8. Run the complete gate

```sh
cd cli
npm run typecheck
npm run build
npm test
npm pack --dry-run

cd ..
swift test --package-path packages/VigilKit

cd apps/apple
xcodegen generate
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'platform=macOS' \
  test CODE_SIGNING_ALLOWED=NO
```

Then run explicit live checks with a test account:

```sh
npx vigil-link doctor --provider <id> --live
npx vigil-link status --provider <id>
```

Do not place live credentials in test output, issue trackers, screenshots, shell history, or committed fixtures.

## Definition of done

A provider is ready when:

- authentication and activation are documented;
- one provider failure cannot abort another;
- requests obey the provider's poll policy and timeout;
- both language implementations produce the same normalized result;
- fixtures cover normal, optional, and malformed data;
- relevant Apple and terminal surfaces render a meaningful value;
- no credential or production account data entered the repository;
- every committed fixture and expected output has a validated provenance entry;
- any live-validation claim identifies the captured body that supports it;
- the support matrix states the actual stability level.

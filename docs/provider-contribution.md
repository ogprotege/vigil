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
- Do not refresh credentials copied from another client if refresh-token rotation could invalidate that client.

Credential discovery must isolate failures. A broken provider must not stop the remaining `status`, `doctor`, or link report.

## 4. Implement response mapping

Use the generic mapping fields when possible:

- `windows` plus `responseFields` for reset-based utilization;
- `metricMappings` for fixed scalar paths;
- `metricCollectionMappings` for arrays such as balances by currency;
- `additionalWindows` for provider-defined window collections.

If the schema needs provider-specific code, keep it small and document why generic mapping cannot express it. Unknown fields must be ignored. Invalid values must be skipped. A successful response with no valid output must become `schemaChanged`.

Keep TypeScript and Swift behavior equal:

- TypeScript mapping and normalized types under `cli/src/providers/`;
- Swift models and mapping under `packages/VigilKit/Sources/VigilKit/`;
- Swift `ProviderRegistry` constants, which hand-mirror the JSON for runtime independence.

## 5. Add proof fixtures

Add at least two sanitized fixture pairs under `protocol/fixtures/`:

```text
provider-case.json
provider-case-expected.json
```

Cover:

- a normal response;
- optional or `null` fields;
- string-encoded decimal values if applicable;
- multiple currencies or secondary windows if applicable;
- malformed data that should be skipped;
- the case where nothing valid maps and `schemaChanged` is expected.

Expected files are hand-authored normalized outputs. Do not generate expected data with the mapper being tested.

Remove tokens, email addresses, account IDs, request IDs, and distinctive production amounts from fixtures.

## 6. Review every surface

Check more than the core mapper:

- CLI `status` labels and scalar formatting;
- `doctor` activation guidance;
- QR and paste payload size;
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

State whether the endpoint is documented, live-validated, fixture-only, or internal.

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
- the support matrix states the actual stability level.

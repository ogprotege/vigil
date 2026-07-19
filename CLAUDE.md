# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Vigil is

An on-device AI usage monitor. It polls Claude and ChatGPT/Codex subscription windows, plus opt-in OpenRouter and DeepSeek gateway metrics, directly from the user's phone or Mac. There is **no Vigil server**. Credentials move from the computer to the phone via the `vigil1` QR protocol and live in the device Keychain (ADR-0001).

## Commands

### CLI (`cli/` — TypeScript, Node ≥20, ESM)

```sh
cd cli
npm install
npm run build        # tsc + copies protocol/providers.json into dist/
npm test             # vitest run (all tests)
npx vitest run test/mappers.test.ts     # single test file
npx vitest run -t "partial name"        # single test by name
npm run typecheck
npm run gen-vectors  # rebuild + regenerate protocol/qr-vectors/ (only if encode output changes)
node dist/index.js status|doctor        # run the CLI after building
```

TS source imports use `.js` extensions (ESM). `cli/src/spec/registry.ts` loads `providers.json` from `dist/` (packaged) or falls back to `../../protocol/` (repo) — hence the copy step in `build`.
### Swift (`packages/VigilKit/`)

```sh
swift test --package-path packages/VigilKit
```

Swift tests locate the repo root via `#filePath` and read `protocol/` fixtures directly — run them from a full checkout, not a copied package.

### Apple app (`apps/apple/`)

```sh
cd apps/apple && xcodegen generate   # no checked-in .xcodeproj (ADR-0002)
xcodebuild -project Vigil.xcodeproj -scheme Vigil \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Vigil.xcodeproj -scheme Vigil -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Device/App Store builds use **manual distribution signing** scoped to `[sdk=iphoneos*]` in `project.yml` (the team has no registered devices, so automatic development signing cannot mint profiles). TestFlight releases: `docs/release.md` — note the sanitized-`PATH` requirement on `-exportArchive` (Homebrew rsync breaks Xcode's IPA step).

CI: `.github/workflows/cli.yml` uses Node 22 and runs typechecking, build, tests, a full high-severity dependency audit, and a package dry-run. `apple.yml` uses `macos-15`, runs VigilKit tests, builds the iOS Simulator app, and runs the app reliability suite on macOS. Device-only Keychain, background-task, camera, notification, and WidgetKit scheduling behavior still requires the on-device release walk.

## Architecture: one contract, two implementations

`protocol/providers.json` is the source of truth for provider endpoints, headers, OAuth metadata, poll policy, discovery metadata, window mappings, and scalar metric mappings. **Policy is data, not code.** TypeScript loads this file at runtime. Swift hand-mirrors the runtime constants because VigilKit cannot depend on a repository-relative file after packaging. CI enforces lockstep three ways:

1. **Fixture parity** — for every pair in `protocol/fixtures/` (`foo.json` + `foo-expected.json`), both mappers must produce the expected normalized output.
2. **Spec parity** — Swift's `ProviderRegistry` hand-mirrors `providers.json` constants for runtime independence; `SpecParityTests` fails CI if either side drifts.
3. **QR vector parity** — `protocol/qr-vectors/`: the CLI asserts the encode direction, VigilKit asserts decode.

**Adding or changing a provider is not registry-only work.** It may require a discovery adapter, a mint adapter, response mapping support, fixtures, Swift mirrored constants, manual-entry copy, widget and menu-bar behavior, and support-matrix updates. Follow `docs/provider-contribution.md`.

### Normalized model and error taxonomy

A `ProviderSnapshot` can contain:

- `UsageWindow`: percent utilization from 0 to 100, with an optional reset time.
- `UsageMetric`: a scalar `balance`, `spend`, `limit`, or `remaining` value with an optional unit.

Its provider status is `ok | authExpired | rateLimited | schemaChanged | network`. The CLI also has a local-only `deferred` status when its poll gate refuses a request. Taxonomy: 401 or 403 means `authExpired`; 429 means `rateLimited` plus backoff; a successful response with no valid window or metric means `schemaChanged`; anything else means `network`. A mapper must not throw on bad input.

## Invariants (do not "fix" these)

- **Never poll Claude faster than 5 minutes.** Do not lower `minSeconds` in `providers.json`. Apple fetches reserve an expiring lease under an OS file lock before network I/O. App and widget processes share the App Group ledger. A scheduler storage error fails closed and must be surfaced.
- **The CLI is credential-stateless** (ADR-0004): it never writes credentials or usage values. It does write provider-level poll timestamps and 429 counters under `VIGIL_STATE_DIR`, `$XDG_CACHE_HOME/vigil-link`, or `~/.cache/vigil-link`. Do not remove that safety state casually.
- **Mint, don't copy** (ADR-0005): the default link flow mints Vigil its own Claude OAuth token pair via PKCE. Never auto-refresh credentials copied from Claude Code's files — refresh-token rotation would race Claude Code's own.
- **Honest freshness**: countdowns tick client-side from `resets_at` with zero network. Staleness and failure states remain visible.
- **Claude usage requests require `User-Agent: claude-code/<ver>`**. Without it they land in an aggressively limited bucket.
- **Persistence failures are product failures.** Credential rotation, Keychain deletion, account-index writes, snapshot writes, and scheduler-ledger failures must not be ignored. Keep the app's visible storage alert path intact.
- **One failed provider must not abort a multi-provider CLI report.** Network requests have a 15-second per-attempt timeout and provider failures degrade independently.
- **VigilKit stays UI-free**; all app UI lives in `apps/apple/`.

## QR protocol (`vigil1`)

Envelope per code: `vigil1:<index>/<total>:<sid>:<data>` where data is a ≤700-character slice of `base64url(deflateRaw(JSON))`. Receivers reject payloads older than 10 minutes, reject payloads more than 60 seconds in the future, and refuse to mix session IDs. v1 payloads are compressed plaintext by design. Details are in `docs/qr-protocol.md`.

## Key docs

- `docs/architecture.md` — system overview, reliability mechanisms, fetch triggers
- `docs/provider-spec.md` — registry field reference, verified endpoint facts, provider expansion map
- `docs/provider-contribution.md`: required work and validation for adding a provider
- `docs/troubleshooting.md`: provider, linking, polling, widget, and storage failures
- `docs/threat-model.md`: assets, trust boundaries, controls, and accepted limitations
- `docs/qr-protocol.md` — payload/envelope format, security posture
- `docs/decisions/` — ADRs 0001–0006 (the rationale behind the invariants above)
- `docs/local-next-steps.md` — status ledger of the executed milestones (M1–M8 shipped); the living docs are `docs/mac-checklist.md` (on-device walk) and `docs/release.md` (TestFlight releases)

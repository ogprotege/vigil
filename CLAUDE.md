# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Vigil is

An on-device AI usage monitor: it polls Claude and ChatGPT/Codex subscription usage endpoints directly from the user's phone/Mac. There is **no Vigil server** — credentials move from the computer to the phone via the `vigil1` QR protocol and live only in the device Keychain (ADR-0001).

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

CI: `.github/workflows/cli.yml` (Node 22) and `apple.yml` (macos-15 — XcodeGen emits Xcode-16 project format; runs `swift test` + a simulator build) run on every push.

## Architecture: one contract, two implementations

`protocol/providers.json` is the single source of truth for provider endpoints, headers, OAuth config, poll policy, and response→window mappings. **Policy is data, not code.** The TypeScript CLI (`cli/src/providers/`) and Swift VigilKit (`Sources/VigilKit/Providers/`) each implement only a thin mapper over it. CI enforces lockstep three ways:

1. **Fixture parity** — for every pair in `protocol/fixtures/` (`foo.json` + `foo-expected.json`), both mappers must produce the expected normalized output.
2. **Spec parity** — Swift's `ProviderRegistry` hand-mirrors `providers.json` constants for runtime independence; `SpecParityTests` fails CI if either side drifts.
3. **QR vector parity** — `protocol/qr-vectors/`: the CLI asserts the encode direction, VigilKit asserts decode.

**Adding/changing a provider** therefore always touches: `protocol/providers.json` → ≥2 fixtures + hand-written `-expected.json` → both thin mappers → the Swift mirrored constants. See `docs/provider-spec.md` for the field reference and verified provider facts.

### Normalized model and error taxonomy

Everything maps to `UsageWindow` (utilization 0–100, optional `resetsAt`) inside a `ProviderSnapshot` whose status is `ok | authExpired | rateLimited | schemaChanged | network`. Taxonomy: 401 → refresh once → retry → else `authExpired`; 429 → `rateLimited` + ledger backoff; 2xx-but-unparseable → `schemaChanged` (a mapper must **never throw on bad input** — it degrades); anything else → `network`. A `null`/missing response bucket produces no window, not an error; a response where no window resolves is `schemaChanged`.

## Invariants (do not "fix" these)

- **Never poll Claude faster than 5 minutes.** The endpoint 429-jails aggressive pollers with no `Retry-After`; this is the failure mode of the monitors Vigil replaces. All fetches go through `FetchScheduler`, whose ledger (persisted in the App Group container) is shared by app + widgets so they can't double-spend the budget. Don't lower `minSeconds` in `providers.json`.
- **The CLI is stateless** (ADR-0004): it never writes credentials to disk.
- **Mint, don't copy** (ADR-0005): the default link flow mints Vigil its own Claude OAuth token pair via PKCE. Never auto-refresh credentials copied from Claude Code's files — refresh-token rotation would race Claude Code's own.
- **Honest freshness**: countdowns tick client-side from `resets_at` with zero network; staleness is tinted, never hidden; failure states are shown, not papered over.
- **Claude usage requests require `User-Agent: claude-code/<ver>`** — without it they land in an aggressively-limited bucket.
- **VigilKit stays UI-free**; all app UI lives in `apps/apple/`.

## QR protocol (`vigil1`)

Envelope per code: `vigil1:<index>/<total>:<sid>:<data>` where data is a ≤700-char slice of `base64url(deflateRaw(JSON))`. Receivers reject payloads older than 10 minutes and refuse to mix session ids. v1 payloads are compressed plaintext by design (ADR-0003 — consent prompt + terminal clear are the guardrails). Details in `docs/qr-protocol.md`. Committed QR vectors pin the **decode** direction byte-exactly; encode is only round-trip tested, because different Node/zlib builds emit different valid DEFLATE bytes. Regenerate vectors (`npm run gen-vectors`) only when the payload shape or envelope format changes.

## Key docs

- `docs/architecture.md` — system overview, reliability mechanisms, fetch triggers
- `docs/provider-spec.md` — registry field reference, verified endpoint facts, provider expansion map
- `docs/qr-protocol.md` — payload/envelope format, security posture
- `docs/decisions/` — ADRs 0001–0006 (the rationale behind the invariants above)
- `docs/local-next-steps.md` — status ledger of the executed milestones (M1–M8 shipped); the living docs are `docs/mac-checklist.md` (on-device walk) and `docs/release.md` (TestFlight releases)

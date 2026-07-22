# ADR-0007: hand-rolled CLI prompts, no interactive-prompt dependency

> **Status: superseded (2026-07-21).** Vigil is iOS-only and phone-native; the
> `vigil-link` CLI and the `vigil1` QR protocol were removed. Kept for the
> historical rationale.

**Previous status:** accepted

## Decision

The `vigil-link` guided wizard (`cli/src/ui/prompts.ts`) implements its own terminal prompts — a numbered multi-select, a strict yes/no, a masked text input, single/any-key reads — over an injected input stream. It does **not** add `@clack/prompts`, `inquirer`, `prompts`, `enquirer`, or any other prompt framework. The CLI's runtime dependency footprint stays at one package (`qrcode-terminal`).

## Context

The wizard needs a small, closed set of interactions, and the happy path is "everything found is preselected — press Enter." A prompt framework would buy widget polish that this flow barely uses.

Against that thin benefit sits a real cost: `vigil-link` handles live credentials and is run via `npx`, so end users get a fresh, semver-resolved install every time — the repo lockfile does not protect them. `@clack/prompts@1.7.0` pulls **5 transitive packages**; each is a potential credential-exfiltration vector in a tool whose whole job is moving OAuth tokens and API keys. Keeping the runtime supply chain at a single, long-lived package is a genuine, marketable security property (consistent with the on-device-only and stateless-CLI posture of ADR-0001/ADR-0004) and keeps the CI `npm audit --audit-level=high` surface flat.

The interaction set is also more unit-testable hand-rolled: `InputManager` is driven by an injected stream, so every prompt (including the masked-input no-echo guarantee) is asserted against a `PassThrough` in `cli/test/prompts.test.ts`, without fighting a framework's own stdin ownership.

## Consequences

- New prompt behaviors live in `cli/src/ui/prompts.ts` and are covered by `cli/test/prompts.test.ts`. Adding a prompt type is a local change, not a dependency bump.
- `InputManager` owns stdin for the process lifetime; line prompts and raw-mode reads pull from one shared buffer, so they cannot fight over the stream. Raw mode is guarded by an `isTTY && setRawMode` capability check so non-TTY and test streams are safe.
- If a future flow genuinely needs richer TUI widgets, revisit this: pin `@clack/prompts` exactly and ship an `npm-shrinkwrap.json` so `npx` consumers get pinned transitive versions, then supersede this ADR.

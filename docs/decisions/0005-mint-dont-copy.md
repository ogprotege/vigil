# ADR-0005: Mint Vigil its own Claude token pair (don't copy Claude Code's)

**Status:** accepted

## Decision

`vigil-link` defaults to running its own browser OAuth flow (PKCE, Anthropic's public client_id, loopback redirect on 127.0.0.1:54545) to obtain a dedicated access/refresh token pair for Vigil. Copying Claude Code's existing pair is a fallback (`--copy`).

## Context

If the phone copies the computer's token pair and both later refresh independently, refresh-token rotation can invalidate one side — breaking either the user's Claude Code login or Vigil silently. A dedicated pair (like a second Claude Code install) removes the contention entirely and lets Vigil request only the `user:profile` scope it needs.

Unverified specifics (validated live at the M2 smoke step): the exact allowed loopback redirect URIs for the public client, and whether `user:profile` alone is grantable. Fallback ladder if assumptions miss: manual code-paste redirect → `--copy`.

**Live validation (2026-07-18):** every open question above is resolved, and mint is verified end-to-end (browser consent → loopback code → token exchange at platform.claude.com → usage fetch 200 with the minted token). Findings: the loopback redirect works with the literal host `localhost` on an arbitrary port (54545 verified) — `http://127.0.0.1:<port>/callback` is rejected as unsupported; `user:profile` alone is not grantable — request the full triple, and the issued grant narrows to `user:inference user:profile`; the authorize query requires `code=true`; and `state` must be the PKCE verifier itself — a separate short random state fails the consent grant with "invalid request format".

## Consequences

- One extra browser-approve step at link time (only for mint; copy remains instant).
- Vigil-side 401s never require touching the computer's Claude Code install.

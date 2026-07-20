# vigil1 QR handoff protocol

Moves credentials from the computer (where CLIs like Claude Code and Codex keep them) to the phone, optically, in seconds. Designed so multiple accounts transfer in one scan session, oversized payloads chunk across multiple codes, and future variants (encryption) can be introduced without breaking old apps.

## Payload (inner JSON, before encoding)

```json
{
  "v": 1,
  "iat": 1784408400,
  "accounts": [
    {
      "p": "claude",
      "label": "Max — you@example.com",
      "c": { "at": "sk-ant-oat01-…", "rt": "sk-ant-ort01-…", "exp": 1784412000, "src": "mint" },
      "meta": { "plan": "max" }
    },
    {
      "p": "codex",
      "label": "Pro — you@example.com",
      "c": { "at": "eyJ…", "rt": "…", "acct": "acct_…" },
      "meta": { "plan": "pro" }
    }
  ]
}
```

- Keys are deliberately short (`p` provider id, `c` credentials, `at`/`rt` access/refresh token, `exp` access-token expiry unix seconds, `acct` account id, `src` credential origin).
- `c.src` is `"mint"` only for token pairs Vigil minted itself — the app may refresh those on 401. Absent `src` means copied credentials, which the app must never rotate (ADR-0005). Receivers treat unknown `src` values as non-refreshable.
- `iat` is unix seconds at payload creation. **Receivers MUST reject payloads older than 10 minutes or more than 60 seconds in the future.**
- Codex `id_token` JWTs are never included (dead weight; the plan label is precomputed into `meta.plan`).

## Envelope (what each QR encodes)

```
vigil1:<index>/<total>:<sid>:<data>
```

- `vigil1` — protocol + variant token. Unknown token (e.g. future `vigil1e` encrypted variant) ⇒ receiver shows "update Vigil". 
- `<index>/<total>` — 1-based chunk position, e.g. `2/3`.
- `<sid>` — 4-character random session id (A–Z, 2–7). All chunks of one link session share it; receivers MUST refuse to mix sids.
- `<data>` — a ≤700-char slice of `base64url( deflateRaw( JSON ) )`.
- One session may contain at most 64 chunks and 32 accounts. Receivers also
  bound credential and metadata fields before allocating durable storage.

Encoding pipeline: `JSON.stringify` → raw DEFLATE (no zlib header — Node `zlib.deflateRawSync`, Apple Compression `COMPRESSION_ZLIB`) → base64url (RFC 4648 §5, no padding) → split into 700-char chunks.

### Size budget

QR capacity at version 25 / EC level M is 997 bytes; codes past ~v25 scan unreliably from terminal-rendered block glyphs. 700 payload chars + ~20 envelope chars ≈ QR v20–22 @ EC-M — comfortably scannable by a stock iPhone camera at arm's length. Expected chunk counts: Claude-only ≈ 1; Claude + Codex (two JWTs) ≈ 2–4.

### Multi-chunk UX

- CLI: a single code draws once and waits for a keypress; multiple codes auto-cycle in place every 3 s until you press a key (the app can capture them in any order). The old `--loop` flag is deprecated and no longer needed.
- App: accepts chunks in any order, shows "captured 2 of 3", assembles when complete.

## Receiver algorithm

1. Parse envelope; verify token is `vigil1`; verify all chunks share one `sid`; assemble in index order.
2. base64url-decode → raw-inflate → parse JSON.
3. Validate `v == 1`, `now - iat ≤ 600 s`, and `iat - now ≤ 60 s`.
4. For each account: reserve the provider poll budget, then run a **live verify
   fetch** when allowed. Persist to Keychain **only on success**. On a network
   failure or a local safety-cooldown deferral, offer "save anyway, verify
   later".

The paste path (`vigil-link --json --yes` output pasted into the app) uses the same
envelope and decoder. Small payloads produce one line. Larger payloads produce
multiple `vigil1:` lines, all of which must be pasted.

## Security posture (ADR-0003)

v1 payloads are **compressed plaintext**, with guardrails:

- The CLI shows an explicit consent prompt before rendering ("anyone who can see or record your screen can capture these credentials").
- The terminal is cleared after linking (`--no-clear` opts out).
- Receivers reject payloads older than 10 minutes or more than 60 seconds in the future.

Rationale: the QR is displayed on the user's own screen and scanned in person; the realistic threats are shoulder-surfing and screen capture. True encryption requires an out-of-band key exchange (typing a code from the phone into the CLI on every link), taxing the product's #1 goal. The same tokens already sit unencrypted in `~/.claude/.credentials.json`. 

**`vigil1e` (v1.1, opt-in):** app displays a 6-digit code → user types it into the CLI → HKDF-SHA256 derives a key → payload sealed with ChaCha20-Poly1305. Post-quantum KEMs are deliberately not used here: an optical, local, one-way transfer has no network key exchange for a quantum adversary to harvest. (If a future Mac-relay feature transmits over a network, that channel is where PQC-hybrid encryption belongs.)

## Test vectors

`protocol/qr-vectors/*.json` hold committed payload ⇄ chunk pairs. Both implementations assert the decode direction byte-exactly (chunk strings → exact payload) — that is the cross-language contract. The encode direction is **not** asserted byte-for-byte: different Node/zlib builds emit different (equally valid) DEFLATE bytes for the same payload, so the CLI instead asserts that a fresh encode produces well-formed chunks under each vector's constraints and decodes back to the payload. Regenerating vectors (`cli/scripts/gen-vectors.mjs`) is only needed when the payload shape or envelope format changes.

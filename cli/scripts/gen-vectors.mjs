// Regenerates protocol/qr-vectors/*.json from the built CLI encoder.
// Deterministic inputs only — vectors are the cross-language contract:
// the CLI asserts the encode direction, VigilKit asserts the decode direction.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildPayload, chunkEncoded, encodePayload, MAX_CHUNK } from "../dist/qr/payload.js";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "..", "protocol", "qr-vectors");
mkdirSync(outDir, { recursive: true });

const IAT = 1784408400; // 2026-07-18T21:00:00Z

function writeVector(name, description, sid, accounts, maxChunk = MAX_CHUNK) {
  const payload = buildPayload(accounts, IAT);
  const encoded = encodePayload(payload);
  const chunks = chunkEncoded(encoded, sid, maxChunk);
  writeFileSync(
    join(outDir, `${name}.json`),
    JSON.stringify({ description, maxChunk, sid, payload, chunks }, null, 2) + "\n"
  );
  console.log(`${name}: ${chunks.length} chunk(s), ${encoded.length} encoded chars`);
}

writeVector(
  "claude-single-chunk",
  "Typical Claude-only link: fits in one QR.",
  "AB2C",
  [
    {
      providerId: "claude",
      accessToken: "sk-ant-oat01-VECTORFIXTUREACCESSTOKENVECTORFIXTUREACCESSTOKEN",
      refreshToken: "sk-ant-ort01-VECTORFIXTUREREFRESHTOKEN",
      expiresAt: 1784412000,
      plan: "max",
      label: "Claude (max)",
      source: "mint",
    },
  ]
);

// A deterministic JWT-sized token forces multiple chunks like real Codex creds
// do. Real JWTs are base64 of near-random data, so the body must be
// incompressible — a seeded LCG, not a repeating pattern deflate would crush.
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
let seed = 123456789;
const nextChar = () => {
  // Lehmer LCG: products stay < 2^53, so exact in JS float arithmetic.
  seed = (seed * 48271) % 2147483647;
  return B64[seed % 64];
};
let jwtBody = "";
for (let i = 0; i < 2200; i++) jwtBody += nextChar();
const longToken = `eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.${jwtBody}.c2lnbmF0dXJlLXNpZ25hdHVyZS1zaWduYXR1cmU`;

writeVector(
  "codex-multi-chunk",
  "Claude + Codex link with a JWT-sized access token: spans multiple QRs.",
  "XY7Z",
  [
    {
      providerId: "claude",
      accessToken: "sk-ant-oat01-VECTORFIXTUREACCESSTOKENVECTORFIXTUREACCESSTOKEN",
      refreshToken: "sk-ant-ort01-VECTORFIXTUREREFRESHTOKEN",
      expiresAt: 1784412000,
      plan: "max",
      label: "Claude (max)",
      source: "file",
    },
    {
      providerId: "codex",
      accessToken: longToken,
      refreshToken: "codex-vector-refresh-token",
      accountId: "acct_vector123",
      plan: "pro",
      label: "ChatGPT (pro) — you@example.com",
      source: "file",
    },
  ]
);

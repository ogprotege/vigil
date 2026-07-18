import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { assembleAndDecode, chunkEncoded, encodePayload, parseChunk, type QrPayload } from "../src/qr/payload.js";
import { REPO_ROOT } from "./helpers.js";

interface Vector {
  description: string;
  maxChunk: number;
  sid: string;
  payload: QrPayload;
  chunks: string[];
}

const vectorDir = path.join(REPO_ROOT, "protocol", "qr-vectors");
const vectors = readdirSync(vectorDir)
  .filter((f) => f.endsWith(".json"))
  .map((f) => ({ name: f, vector: JSON.parse(readFileSync(path.join(vectorDir, f), "utf8")) as Vector }));

// Encode-side of the cross-language contract; VigilKit owns the decode-side.
describe("qr vectors", () => {
  it("has at least the two canonical vectors", () => {
    const names = vectors.map((v) => v.name);
    expect(names).toContain("claude-single-chunk.json");
    expect(names).toContain("codex-multi-chunk.json");
  });

  for (const { name, vector } of vectors) {
    it(`${name}: encode(payload) round-trips under the vector's constraints`, () => {
      // Deliberately NOT compared byte-for-byte against the committed chunks:
      // different Node/zlib builds emit different (equally valid) DEFLATE
      // bytes for the same payload. The committed strings pin the decode side
      // (below, and in VigilKit); encode is held to the contract that actually
      // matters — well-formed chunks that decode back to the payload.
      const chunks = chunkEncoded(encodePayload(vector.payload), vector.sid, vector.maxChunk);
      chunks.forEach((chunk, i) => {
        const parsed = parseChunk(chunk);
        expect(parsed.sid).toBe(vector.sid);
        expect(parsed.index).toBe(i + 1);
        expect(parsed.total).toBe(chunks.length);
        expect(parsed.data.length).toBeLessThanOrEqual(vector.maxChunk);
      });
      expect(assembleAndDecode(chunks)).toEqual(vector.payload);
    });

    it(`${name}: committed chunks decode back to the payload`, () => {
      expect(assembleAndDecode(vector.chunks)).toEqual(vector.payload);
    });
  }

  it("codex-multi-chunk actually spans multiple chunks", () => {
    const multi = vectors.find((v) => v.name === "codex-multi-chunk.json")!;
    expect(multi.vector.chunks.length).toBeGreaterThan(1);
  });
});

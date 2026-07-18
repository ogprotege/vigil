import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { assembleAndDecode, chunkEncoded, encodePayload, type QrPayload } from "../src/qr/payload.js";
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
    it(`${name}: encode(payload) reproduces the committed chunks`, () => {
      const chunks = chunkEncoded(encodePayload(vector.payload), vector.sid, vector.maxChunk);
      expect(chunks).toEqual(vector.chunks);
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

import { describe, expect, it } from "vitest";
import {
  assembleAndDecode,
  buildPayload,
  chunkEncoded,
  encodePayload,
  makeSid,
  parseChunk,
  validateAge,
  MAX_CHUNK,
} from "../src/qr/payload.js";
import type { Credentials } from "../src/providers/types.js";

const claudeCreds: Credentials = {
  providerId: "claude",
  accessToken: "sk-ant-oat01-AAAA",
  refreshToken: "sk-ant-ort01-BBBB",
  expiresAt: 1784412000,
  plan: "max",
  label: "Claude (max)",
  source: "mint",
};

describe("payload round-trip", () => {
  it("encodes and decodes a single-account payload", () => {
    const payload = buildPayload([claudeCreds], 1784408400);
    const chunks = chunkEncoded(encodePayload(payload), "AB2C");
    expect(chunks.length).toBe(1);
    expect(chunks[0]!).toMatch(/^vigil1:1\/1:AB2C:/);
    const decoded = assembleAndDecode(chunks);
    expect(decoded).toEqual(payload);
    expect(decoded.accounts[0]!.c["at"]).toBe("sk-ant-oat01-AAAA");
    expect(decoded.accounts[0]!.c["src"]).toBe("mint");
    expect(decoded.accounts[0]!.meta).toEqual({ plan: "max" });
  });

  it("marks only minted credentials as refreshable", () => {
    const copied = buildPayload([{ ...claudeCreds, source: "file" }], 1784408400);
    expect(copied.accounts[0]!.c["src"]).toBeUndefined();
  });

  it("reassembles multi-chunk payloads in any order", () => {
    const big: Credentials = { ...claudeCreds, accessToken: "x".repeat(4000) };
    const chunks = chunkEncoded(encodePayload(buildPayload([big], 1784408400)), "XY7Z", 100);
    expect(chunks.length).toBeGreaterThan(1);
    const shuffled = [...chunks].reverse();
    const decoded = assembleAndDecode(shuffled);
    expect(decoded.accounts[0]!.c["at"]).toBe("x".repeat(4000));
  });

  it("property: payloads up to 16KB chunk to <=700 chars and reassemble byte-identically", () => {
    // Deterministic pseudo-random content (no Math.random flakiness).
    let seed = 42;
    const next = () => (seed = (seed * 1103515245 + 12345) % 2 ** 31);
    for (const size of [10, 700, 701, 2100, 8000, 16000]) {
      let token = "";
      while (token.length < size) token += String.fromCharCode(97 + (next() % 26));
      const payload = buildPayload([{ ...claudeCreds, accessToken: token }], 1784408400);
      const chunks = chunkEncoded(encodePayload(payload), "AB2C");
      for (const chunk of chunks) {
        const { data } = parseChunk(chunk);
        expect(data.length).toBeLessThanOrEqual(MAX_CHUNK);
      }
      expect(assembleAndDecode(chunks)).toEqual(payload);
    }
  });
});

describe("envelope validation", () => {
  const chunks = chunkEncoded(encodePayload(buildPayload([claudeCreds], 1784408400)), "AB2C");

  it("rejects mixed link sessions (sid mismatch)", () => {
    const other = chunkEncoded(encodePayload(buildPayload([claudeCreds], 1784408400)), "ZZ22");
    expect(() => assembleAndDecode([chunks[0]!, other[0]!.replace(":1/1:", ":2/2:")])).toThrow(/sid/);
  });

  it("rejects incomplete sets", () => {
    const big = chunkEncoded(encodePayload(buildPayload([{ ...claudeCreds, accessToken: "x".repeat(4000) }], 1)), "AB2C", 100);
    expect(() => assembleAndDecode(big.slice(0, 1))).toThrow(/incomplete/);
  });

  it("rejects unknown protocol variants with an upgrade hint", () => {
    expect(() => parseChunk("vigil1e:1/1:AB2C:abcd")).toThrow(/update Vigil/);
  });

  it("rejects garbage", () => {
    expect(() => parseChunk("https://example.com/not-a-vigil-code")).toThrow(/unrecognized/);
  });

  it("enforces the 10-minute age limit", () => {
    const payload = buildPayload([claudeCreds], 1784408400);
    expect(() => validateAge(payload, 1784408400 + 599)).not.toThrow();
    expect(() => validateAge(payload, 1784408400 + 601)).toThrow(/expired/);
  });
});

describe("sid", () => {
  it("generates 4 chars from the A-Z2-7 alphabet", () => {
    for (let i = 0; i < 50; i++) {
      expect(makeSid()).toMatch(/^[A-Z2-7]{4}$/);
    }
  });
});

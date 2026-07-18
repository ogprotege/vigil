import { deflateRawSync, inflateRawSync } from "node:zlib";
import { randomInt } from "node:crypto";
import type { Credentials } from "../providers/types.js";

export const PROTOCOL_TOKEN = "vigil1";
export const MAX_CHUNK = 700;
export const MAX_AGE_SECONDS = 600;

export interface QrAccount {
  p: string;
  label: string;
  c: Record<string, unknown>;
  meta?: Record<string, unknown>;
}

export interface QrPayload {
  v: 1;
  iat: number;
  accounts: QrAccount[];
}

const SID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function makeSid(rng: (max: number) => number = randomInt): string {
  let sid = "";
  for (let i = 0; i < 4; i++) sid += SID_ALPHABET[rng(SID_ALPHABET.length)];
  return sid;
}

export function buildPayload(accounts: Credentials[], nowSeconds: number): QrPayload {
  return {
    v: 1,
    iat: nowSeconds,
    accounts: accounts.map((creds): QrAccount => {
      const c: Record<string, unknown> = { at: creds.accessToken };
      if (creds.refreshToken) c["rt"] = creds.refreshToken;
      if (creds.expiresAt) c["exp"] = creds.expiresAt;
      if (creds.accountId) c["acct"] = creds.accountId;
      const account: QrAccount = {
        p: creds.providerId,
        label: creds.label ?? creds.providerId,
        c,
      };
      if (creds.plan) account.meta = { plan: creds.plan };
      return account;
    }),
  };
}

export function encodePayload(payload: QrPayload): string {
  const json = JSON.stringify(payload);
  return deflateRawSync(Buffer.from(json, "utf8")).toString("base64url");
}

export function chunkEncoded(encoded: string, sid: string, maxChunk: number = MAX_CHUNK): string[] {
  if (!/^[A-Z2-7]{4}$/.test(sid)) throw new Error(`invalid sid: ${sid}`);
  const pieces: string[] = [];
  for (let i = 0; i < encoded.length; i += maxChunk) {
    pieces.push(encoded.slice(i, i + maxChunk));
  }
  if (pieces.length === 0) pieces.push("");
  return pieces.map((piece, i) => `${PROTOCOL_TOKEN}:${i + 1}/${pieces.length}:${sid}:${piece}`);
}

export interface ParsedChunk {
  index: number;
  total: number;
  sid: string;
  data: string;
}

export function parseChunk(chunk: string): ParsedChunk {
  const match = /^([a-z0-9]+):(\d+)\/(\d+):([A-Z2-7]{4}):([A-Za-z0-9_-]*)$/.exec(chunk.trim());
  if (!match) throw new Error("unrecognized chunk format");
  const [, token, indexStr, totalStr, sid, data] = match;
  if (token !== PROTOCOL_TOKEN) {
    throw new Error(`unsupported protocol variant "${token}" — update Vigil`);
  }
  const index = Number(indexStr);
  const total = Number(totalStr);
  if (index < 1 || total < 1 || index > total) throw new Error("invalid chunk indices");
  return { index, total, sid: sid!, data: data ?? "" };
}

export function assembleAndDecode(chunks: string[]): QrPayload {
  if (chunks.length === 0) throw new Error("no chunks");
  const parsed = chunks.map(parseChunk);
  const sid = parsed[0]!.sid;
  const total = parsed[0]!.total;
  if (parsed.some((c) => c.sid !== sid)) throw new Error("chunks from different link sessions (sid mismatch)");
  if (parsed.some((c) => c.total !== total)) throw new Error("inconsistent chunk totals");
  if (parsed.length !== total) throw new Error(`incomplete: have ${parsed.length} of ${total} chunks`);

  const byIndex = new Map(parsed.map((c) => [c.index, c.data]));
  if (byIndex.size !== total) throw new Error("duplicate chunk indices");
  let encoded = "";
  for (let i = 1; i <= total; i++) encoded += byIndex.get(i)!;

  const json = inflateRawSync(Buffer.from(encoded, "base64url")).toString("utf8");
  const payload = JSON.parse(json) as QrPayload;
  if (payload.v !== 1 || !Array.isArray(payload.accounts)) throw new Error("invalid payload");
  return payload;
}

export function validateAge(payload: QrPayload, nowSeconds: number): void {
  if (typeof payload.iat !== "number" || nowSeconds - payload.iat > MAX_AGE_SECONDS) {
    throw new Error("link code expired (older than 10 minutes) — run vigil-link again");
  }
}

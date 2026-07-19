import { deflateRawSync, inflateRawSync } from "node:zlib";
import { randomInt } from "node:crypto";
import type { Credentials } from "../providers/types.js";

export const PROTOCOL_TOKEN = "vigil1";
export const MAX_CHUNK = 700;
export const MAX_CHUNKS = 64;
export const MAX_ACCOUNTS = 32;
export const MAX_AGE_SECONDS = 600;
export const MAX_FUTURE_SKEW_SECONDS = 60;

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
      // Only minted pairs are marked refreshable: the app must never rotate
      // copied credentials (ADR-0005).
      if (creds.source === "mint") c["src"] = "mint";
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
  validatePayloadShape(payload);
  const json = JSON.stringify(payload);
  return deflateRawSync(Buffer.from(json, "utf8")).toString("base64url");
}

export function chunkEncoded(encoded: string, sid: string, maxChunk: number = MAX_CHUNK): string[] {
  if (!/^[A-Z2-7]{4}$/.test(sid)) throw new Error(`invalid sid: ${sid}`);
  if (!Number.isSafeInteger(maxChunk) || maxChunk < 1 || maxChunk > MAX_CHUNK) {
    throw new Error(`chunk size must be between 1 and ${MAX_CHUNK}`);
  }
  const pieces: string[] = [];
  for (let i = 0; i < encoded.length; i += maxChunk) {
    pieces.push(encoded.slice(i, i + maxChunk));
  }
  if (pieces.length === 0) pieces.push("");
  if (pieces.length > MAX_CHUNKS) {
    throw new Error(`link payload needs ${pieces.length} chunks; maximum is ${MAX_CHUNKS}`);
  }
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
  if (
    !Number.isSafeInteger(index) ||
    !Number.isSafeInteger(total) ||
    index < 1 ||
    total < 1 ||
    total > MAX_CHUNKS ||
    index > total ||
    (data?.length ?? 0) > MAX_CHUNK
  ) {
    throw new Error("invalid chunk indices or size");
  }
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

  const json = inflateRawSync(Buffer.from(encoded, "base64url"), {
    maxOutputLength: 4 * 1024 * 1024,
  }).toString("utf8");
  const payload = JSON.parse(json) as QrPayload;
  validatePayloadShape(payload);
  return payload;
}

export function validatePayloadShape(payload: QrPayload): void {
  if (
    payload === null ||
    typeof payload !== "object" ||
    payload.v !== 1 ||
    !Number.isSafeInteger(payload.iat) ||
    !Array.isArray(payload.accounts) ||
    payload.accounts.length < 1 ||
    payload.accounts.length > MAX_ACCOUNTS
  ) {
    throw new Error("invalid payload");
  }
  for (const account of payload.accounts) {
    const accessToken = account?.c?.["at"];
    const refreshToken = account?.c?.["rt"];
    const accountId = account?.c?.["acct"];
    const source = account?.c?.["src"];
    const expiry = account?.c?.["exp"];
    const plan = account?.meta?.["plan"];
    if (
      typeof account?.p !== "string" ||
      !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(account.p) ||
      typeof account.label !== "string" ||
      Buffer.byteLength(account.label) < 1 ||
      Buffer.byteLength(account.label) > 256 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(account.label) ||
      typeof accessToken !== "string" ||
      Buffer.byteLength(accessToken) < 1 ||
      Buffer.byteLength(accessToken) > 65_536 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(accessToken)
    ) {
      throw new Error("invalid payload");
    }
    if (refreshToken !== undefined && (
      typeof refreshToken !== "string" ||
      Buffer.byteLength(refreshToken) > 65_536 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(refreshToken)
    )) {
      throw new Error("invalid payload");
    }
    if (accountId !== undefined && (
      typeof accountId !== "string" ||
      Buffer.byteLength(accountId) > 128 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(accountId)
    )) {
      throw new Error("invalid payload");
    }
    if (source !== undefined && (
      typeof source !== "string" ||
      Buffer.byteLength(source) > 32 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(source)
    )) {
      throw new Error("invalid payload");
    }
    if (expiry !== undefined && (
      typeof expiry !== "number" ||
      !Number.isSafeInteger(expiry) ||
      expiry < 0 ||
      expiry > 253_402_300_799
    )) {
      throw new Error("invalid payload");
    }
    if (plan !== undefined && (
      typeof plan !== "string" ||
      Buffer.byteLength(plan) > 128 ||
      /[\u0000-\u001F\u007F-\u009F]/.test(plan)
    )) {
      throw new Error("invalid payload");
    }
  }
}

export function validateAge(payload: QrPayload, nowSeconds: number): void {
  if (typeof payload.iat !== "number" || !Number.isFinite(payload.iat)) {
    throw new Error("link code has an invalid issue time");
  }
  if (payload.iat - nowSeconds > MAX_FUTURE_SKEW_SECONDS) {
    throw new Error("link code is dated too far in the future. Check both devices' clocks");
  }
  if (nowSeconds - payload.iat > MAX_AGE_SECONDS) {
    throw new Error("link code expired (older than 10 minutes) — run vigil-link again");
  }
}

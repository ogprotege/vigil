import { mkdir, readFile, rename, rmdir, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { SnapshotStatus } from "./providers/types.js";
import type { PollSpec, ProviderId } from "./spec/registry.js";

interface PollState {
  lastAttemptAt: number;
  nextAllowedAt: number;
  consecutive429: number;
  /**
   * True while a request has not recorded its result. The reservation uses
   * the maximum 429 backoff until completion, so a crash or failed result
   * write cannot silently fall back to the ordinary five-minute cooldown.
   */
  pendingResult?: boolean;
}

export interface PollGateOptions {
  stateDir?: string;
  homeDir?: string;
  env?: Record<string, string | undefined>;
  now?: () => Date;
  random?: () => number;
}

export type PollDecision =
  | { allowed: true; fallbackRetryAt: string }
  | {
      allowed: false;
      retryAt: string;
      reason: "cooldown" | "busy" | "stateUnavailable";
    };

const LOCK_STALE_MS = 60_000;
const LOCK_RETRIES = 10;
const MAX_CONSECUTIVE_429 = 63;
const MAX_DATE_MILLISECONDS = 8_640_000_000_000_000;

function stateDirectory(options: PollGateOptions): string {
  if (options.stateDir) return options.stateDir;
  const env = options.env ?? process.env;
  if (env["VIGIL_STATE_DIR"]) return env["VIGIL_STATE_DIR"];
  if (env["XDG_CACHE_HOME"]) return path.join(env["XDG_CACHE_HOME"], "vigil-link");
  return path.join(options.homeDir ?? os.homedir(), ".cache", "vigil-link");
}

function statePath(providerId: ProviderId, options: PollGateOptions): string {
  const safeId = providerId.replace(/[^a-zA-Z0-9._-]/g, "_");
  return path.join(stateDirectory(options), `${safeId}.poll.json`);
}

function isNodeError(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && (error as NodeJS.ErrnoException).code === code;
}

function parseState(raw: string): PollState | null {
  try {
    const value = JSON.parse(raw) as Partial<PollState>;
    if (
      typeof value.lastAttemptAt !== "number" ||
      !Number.isSafeInteger(value.lastAttemptAt) ||
      value.lastAttemptAt < 0 ||
      value.lastAttemptAt > MAX_DATE_MILLISECONDS ||
      typeof value.nextAllowedAt !== "number" ||
      !Number.isSafeInteger(value.nextAllowedAt) ||
      value.nextAllowedAt < 0 ||
      value.nextAllowedAt > MAX_DATE_MILLISECONDS ||
      typeof value.consecutive429 !== "number" ||
      !Number.isInteger(value.consecutive429) ||
      value.consecutive429 < 0 ||
      value.consecutive429 > MAX_CONSECUTIVE_429
    ) {
      return null;
    }
    if (value.pendingResult !== undefined && typeof value.pendingResult !== "boolean") {
      return null;
    }
    return value as PollState;
  } catch {
    return null;
  }
}

async function readState(filePath: string): Promise<PollState | null> {
  try {
    const raw = await readFile(filePath, "utf8");
    const state = parseState(raw);
    if (!state) throw new Error("poll state is malformed");
    return state;
  } catch (error) {
    if (isNodeError(error, "ENOENT")) return null;
    throw error;
  }
}

async function writeState(filePath: string, state: PollState): Promise<void> {
  const temporary = `${filePath}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  await writeFile(temporary, JSON.stringify(state) + "\n", { encoding: "utf8", mode: 0o600 });
  await rename(temporary, filePath);
}

async function acquireLock(filePath: string, nowMs: number): Promise<string | null> {
  const lockPath = `${filePath}.lock`;
  for (let attempt = 0; attempt < LOCK_RETRIES; attempt++) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      return lockPath;
    } catch (error) {
      if (!isNodeError(error, "EEXIST")) throw error;
      try {
        const lockStat = await stat(lockPath);
        if (nowMs - lockStat.mtimeMs > LOCK_STALE_MS) {
          await rmdir(lockPath);
          continue;
        }
      } catch (statError) {
        if (!isNodeError(statError, "ENOENT")) throw statError;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  return null;
}

async function withStateLock<T>(
  providerId: ProviderId,
  options: PollGateOptions,
  body: (filePath: string) => Promise<T>
): Promise<T | null> {
  const filePath = statePath(providerId, options);
  await mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const nowMs = (options.now ?? (() => new Date()))().getTime();
  const lockPath = await acquireLock(filePath, nowMs);
  if (!lockPath) return null;
  try {
    return await body(filePath);
  } finally {
    await rmdir(lockPath).catch(() => {});
  }
}

function jitterMilliseconds(policy: PollSpec, random: () => number): number {
  const sample = Math.min(1, Math.max(0, random()));
  const seconds = Number.isFinite(policy.jitterSeconds)
    ? Math.max(0, policy.jitterSeconds)
    : 0;
  return Math.floor(sample * seconds * 1000);
}

/**
 * Atomically reserves a provider poll across CLI processes. The persisted
 * record contains timestamps and a 429 counter only, never credentials or
 * usage values.
 */
export async function reservePoll(
  providerId: ProviderId,
  policy: PollSpec,
  options: PollGateOptions = {}
): Promise<PollDecision> {
  const now = (options.now ?? (() => new Date()))();
  const nowMs = now.getTime();
  try {
    const decision = await withStateLock(providerId, options, async (filePath) => {
      const state = await readState(filePath);
      if (state && state.nextAllowedAt > nowMs) {
        return {
          allowed: false,
          retryAt: new Date(state.nextAllowedAt).toISOString(),
          reason: "cooldown",
        } as const;
      }

      // Reserve pessimistically. recordPollResult shortens this to the normal
      // interval after a non-429 response or to the precise exponential
      // interval after a 429. If that result write fails, the durable maximum
      // backoff remains, which is the safe failure mode.
      const nextAllowedAt =
        nowMs +
        Math.max(0, policy.minSeconds, policy.backoffMaxSeconds) * 1000 +
        jitterMilliseconds(policy, options.random ?? Math.random);
      await writeState(filePath, {
        lastAttemptAt: nowMs,
        nextAllowedAt,
        consecutive429: state?.consecutive429 ?? 0,
        pendingResult: true,
      });
      return {
        allowed: true,
        fallbackRetryAt: new Date(nextAllowedAt).toISOString(),
      } as const;
    });
    if (decision) return decision;
    return {
      allowed: false,
      retryAt: new Date(nowMs + 1000).toISOString(),
      reason: "busy",
    };
  } catch {
    return {
      allowed: false,
      retryAt: new Date(nowMs + Math.max(1, policy.minSeconds) * 1000).toISOString(),
      reason: "stateUnavailable",
    };
  }
}

export type PollRecordOutcome =
  | { recorded: true }
  | { recorded: false; reason: "busy" | "stateUnavailable" };

/** Updates the next allowed time after a completed request, including 429 backoff. */
export async function recordPollResult(
  providerId: ProviderId,
  policy: PollSpec,
  status: SnapshotStatus,
  options: PollGateOptions = {}
): Promise<PollRecordOutcome> {
  const nowMs = (options.now ?? (() => new Date()))().getTime();
  try {
    const result = await withStateLock(providerId, options, async (filePath) => {
      const current = await readState(filePath);
      const lastAttemptAt = current?.lastAttemptAt ?? nowMs;
      let consecutive429 =
        status === "rateLimited"
          ? Math.min(MAX_CONSECUTIVE_429, (current?.consecutive429 ?? 0) + 1)
          : 0;
      let delaySeconds = policy.minSeconds;
      if (status === "rateLimited") {
        const exponent = Math.max(0, consecutive429 - 1);
        delaySeconds = Math.min(
          policy.backoff429BaseSeconds * 2 ** exponent,
          policy.backoffMaxSeconds
        );
      }
      if (!Number.isFinite(delaySeconds)) {
        delaySeconds = policy.backoffMaxSeconds;
        consecutive429 = Math.max(1, consecutive429);
      }
      const nextAllowedAt =
        nowMs +
        Math.max(0, delaySeconds) * 1000 +
        jitterMilliseconds(policy, options.random ?? Math.random);
      await writeState(filePath, {
        lastAttemptAt,
        nextAllowedAt,
        consecutive429,
        pendingResult: false,
      });
      return true;
    });
    return result === null ? { recorded: false, reason: "busy" } : { recorded: true };
  } catch {
    return { recorded: false, reason: "stateUnavailable" };
  }
}

export function pollingStateDescription(options: PollGateOptions = {}): string {
  return stateDirectory(options);
}

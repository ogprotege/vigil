import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { recordPollResult, reservePoll } from "../src/polling.js";
import type { PollSpec } from "../src/spec/registry.js";

const policy: PollSpec = {
  minSeconds: 300,
  jitterSeconds: 60,
  backoff429BaseSeconds: 900,
  backoffMaxSeconds: 3600,
};

const directories: string[] = [];

async function stateDir(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), "vigil-poll-test-"));
  directories.push(directory);
  return directory;
}

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("cross-process poll gate", () => {
  it("allows one reservation and defers a repeat until the provider minimum", async () => {
    const directory = await stateDir();
    const now = () => new Date("2026-07-18T20:00:00Z");
    const options = { stateDir: directory, now, random: () => 0 };

    await expect(reservePoll("claude", policy, options)).resolves.toEqual({
      allowed: true,
      fallbackRetryAt: "2026-07-18T21:00:00.000Z",
    });
    await expect(recordPollResult("claude", policy, "ok", options)).resolves.toEqual({
      recorded: true,
    });
    const repeated = await reservePoll("claude", policy, options);
    expect(repeated).toEqual({
      allowed: false,
      retryAt: "2026-07-18T20:05:00.000Z",
      reason: "cooldown",
    });
  });

  it("retains the maximum backoff if a process exits before recording its result", async () => {
    const directory = await stateDir();
    const options = {
      stateDir: directory,
      now: () => new Date("2026-07-18T20:00:00Z"),
      random: () => 0,
    };

    await reservePoll("claude", policy, options);
    await expect(reservePoll("claude", policy, options)).resolves.toEqual({
      allowed: false,
      retryAt: "2026-07-18T21:00:00.000Z",
      reason: "cooldown",
    });
  });

  it("reports a failed result write while preserving the conservative reservation", async () => {
    const directory = await stateDir();
    const options = {
      stateDir: directory,
      now: () => new Date("2026-07-18T20:00:00Z"),
      random: () => 0,
    };
    await reservePoll("claude", policy, options);
    await mkdir(path.join(directory, "claude.poll.json.lock"));

    await expect(recordPollResult("claude", policy, "ok", options)).resolves.toEqual({
      recorded: false,
      reason: "busy",
    });
    const raw = JSON.parse(
      await readFile(path.join(directory, "claude.poll.json"), "utf8")
    ) as Record<string, unknown>;
    expect(raw).toMatchObject({
      nextAllowedAt: new Date("2026-07-18T21:00:00Z").getTime(),
      pendingResult: true,
    });
  });

  it("grants only one of two concurrent process-style reservations", async () => {
    const directory = await stateDir();
    const options = {
      stateDir: directory,
      now: () => new Date("2026-07-18T20:00:00Z"),
      random: () => 0,
    };
    const decisions = await Promise.all([
      reservePoll("codex", policy, options),
      reservePoll("codex", policy, options),
    ]);
    expect(decisions.filter((decision) => decision.allowed)).toHaveLength(1);
  });

  it("extends the timestamp-only reservation after a 429", async () => {
    const directory = await stateDir();
    const options = {
      stateDir: directory,
      now: () => new Date("2026-07-18T20:00:00Z"),
      random: () => 0,
    };
    await reservePoll("claude", policy, options);
    await recordPollResult("claude", policy, "rateLimited", options);

    const raw = await readFile(path.join(directory, "claude.poll.json"), "utf8");
    expect(raw).not.toMatch(/token|usage|credential/i);
    expect(JSON.parse(raw)).toMatchObject({
      nextAllowedAt: new Date("2026-07-18T20:15:00Z").getTime(),
      consecutive429: 1,
    });
  });

  it("fails closed when an existing poll record is malformed", async () => {
    const directory = await stateDir();
    await writeFile(path.join(directory, "claude.poll.json"), "not-json\n");
    const result = await reservePoll("claude", policy, {
      stateDir: directory,
      now: () => new Date("2026-07-18T20:00:00Z"),
      random: () => 0,
    });
    expect(result.allowed).toBe(false);

    const names = await readdir(directory);
    expect(names).toContain("claude.poll.json");
  });
});

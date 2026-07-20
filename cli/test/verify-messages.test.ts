import { describe, expect, it } from "vitest";
import { verifyOutcomeMessages, type VerifyOutcome } from "../src/commands/link.js";
import type { ProviderSnapshot, SnapshotStatus } from "../src/providers/types.js";

const NOW = new Date("2026-07-18T20:01:00Z");

function snapshot(status: SnapshotStatus, extra: Partial<ProviderSnapshot> = {}): ProviderSnapshot {
  return {
    providerId: "claude",
    accountLabel: "Claude",
    planLabel: null,
    fetchedAt: NOW.toISOString(),
    status,
    windows: [],
    metrics: [],
    ...extra,
  };
}

describe("verifyOutcomeMessages", () => {
  it("marks a verified account with a checkmark", () => {
    const outcome: VerifyOutcome = {
      kind: "verified",
      credentials: { providerId: "claude", accessToken: "x", source: "file" },
      displayName: "Claude",
      snapshot: snapshot("ok"),
    };
    expect(verifyOutcomeMessages(outcome, NOW)).toEqual(["✓ Claude: verified (ok)"]);
  });

  it("explains a deferred account will be verified on the phone and gives the next-allowed time", () => {
    const outcome: VerifyOutcome = {
      kind: "deferred",
      credentials: { providerId: "claude", accessToken: "x", source: "file" },
      displayName: "Claude",
      snapshot: snapshot("deferred", { retryAt: "2026-07-18T20:04:00Z", deferredReason: "cooldown" }),
    };
    const [line] = verifyOutcomeMessages(outcome, NOW);
    expect(line).toContain("couldn't verify right now");
    expect(line).toContain("next allowed in 3m");
    expect(line).toContain("iPhone will verify");
  });

  it("adds a recovery hint when a deferred account hit a corrupt poll-state file", () => {
    const outcome: VerifyOutcome = {
      kind: "deferred",
      credentials: { providerId: "claude", accessToken: "x", source: "file" },
      displayName: "Claude",
      snapshot: snapshot("deferred", {
        deferredReason: "corruptState",
        pollStatePath: "/tmp/vigil/claude.poll.json",
      }),
    };
    const messages = verifyOutcomeMessages(outcome, NOW);
    expect(messages.some((m) => m.includes("corrupt or unreadable"))).toBe(true);
    expect(messages.some((m) => m.includes("/tmp/vigil/claude.poll.json"))).toBe(true);
    expect(messages.some((m) => m.includes("delete that file"))).toBe(true);
  });

  it("tells the user to refresh credentials on authExpired", () => {
    const outcome: VerifyOutcome = {
      kind: "failed",
      credentials: { providerId: "claude", accessToken: "x", source: "file" },
      displayName: "Claude",
      snapshot: snapshot("authExpired"),
    };
    expect(verifyOutcomeMessages(outcome, NOW)[0]).toContain("rejected these credentials");
  });

  it("reports a network problem distinctly from a schema change", () => {
    const network: VerifyOutcome = {
      kind: "failed",
      credentials: { providerId: "openrouter", accessToken: "x", source: "environment" },
      displayName: "OpenRouter",
      snapshot: snapshot("network"),
    };
    const schema: VerifyOutcome = {
      kind: "failed",
      credentials: { providerId: "openrouter", accessToken: "x", source: "environment" },
      displayName: "OpenRouter",
      snapshot: snapshot("schemaChanged"),
    };
    expect(verifyOutcomeMessages(network, NOW)[0]).toContain("network problem");
    expect(verifyOutcomeMessages(schema, NOW)[0]).toContain("unexpected response");
  });

  it("prefixes a poll-safety warning before the outcome line", () => {
    const outcome: VerifyOutcome = {
      kind: "verified",
      credentials: { providerId: "claude", accessToken: "x", source: "file" },
      displayName: "Claude",
      snapshot: snapshot("ok"),
      pollSafetyWarning: { reason: "stateUnavailable", retryAt: "2026-07-18T20:06:00Z" },
    };
    const messages = verifyOutcomeMessages(outcome, NOW);
    expect(messages[0]).toContain("poll safety result could not be saved");
    expect(messages[1]).toContain("verified (ok)");
  });
});

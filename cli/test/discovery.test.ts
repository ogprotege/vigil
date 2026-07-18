import { describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { discoverClaude } from "../src/discovery/claude.js";
import { discoverCodex } from "../src/discovery/codex.js";
import { decodeJwtPayload } from "../src/util/jwt.js";
import { CLAUDE_CREDS_FILE, codexCredsFile, makeFakeHome, makeJwt } from "./helpers.js";

const registry = loadRegistry();

describe("claude discovery", () => {
  it("reads ~/.claude/.credentials.json and normalizes expiresAt ms->s", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const result = await discoverClaude(registry.providers.claude, { homeDir, platform: "linux" });
    expect(result.location).toBe("file");
    expect(result.credentials).toMatchObject({
      providerId: "claude",
      accessToken: CLAUDE_CREDS_FILE.claudeAiOauth.accessToken,
      refreshToken: CLAUDE_CREDS_FILE.claudeAiOauth.refreshToken,
      expiresAt: 1784412000,
      plan: "max",
      source: "file",
    });
  });

  it("falls back to the macOS keychain via `security`", async () => {
    const { homeDir } = await makeFakeHome({});
    const result = await discoverClaude(registry.providers.claude, {
      homeDir,
      platform: "darwin",
      execFile: async (command, args) => {
        expect(command).toBe("security");
        expect(args).toEqual(["find-generic-password", "-s", "Claude Code-credentials", "-w"]);
        return { stdout: JSON.stringify(CLAUDE_CREDS_FILE) + "\n" };
      },
    });
    expect(result.location).toBe("keychain");
    expect(result.credentials?.source).toBe("keychain");
  });

  it("returns null cleanly when nothing exists", async () => {
    const { homeDir } = await makeFakeHome({});
    const result = await discoverClaude(registry.providers.claude, { homeDir, platform: "linux" });
    expect(result.credentials).toBeNull();
    expect(result.location).toBeNull();
  });

  it("tolerates malformed JSON", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const { writeFile } = await import("node:fs/promises");
    await writeFile(`${homeDir}/.claude/.credentials.json`, "{not json");
    const result = await discoverClaude(registry.providers.claude, { homeDir, platform: "linux" });
    expect(result.credentials).toBeNull();
  });
});

describe("codex discovery", () => {
  it("reads ~/.codex/auth.json with account id and plan from the id_token", async () => {
    const { homeDir } = await makeFakeHome({ codex: codexCredsFile() });
    const result = await discoverCodex(registry.providers.codex, { homeDir, env: {} });
    expect(result.credentials).toMatchObject({
      providerId: "codex",
      accountId: "acct_test123",
      plan: "pro",
      expiresAt: 1784500000,
      source: "file",
    });
    expect(result.credentials!.label).toContain("you@example.com");
  });

  it("honors $CODEX_HOME", async () => {
    const { homeDir } = await makeFakeHome({ codex: codexCredsFile() });
    const result = await discoverCodex(registry.providers.codex, {
      homeDir: "/nonexistent",
      env: { CODEX_HOME: `${homeDir}/.codex` },
    });
    expect(result.credentials).not.toBeNull();
  });

  it("derives account id from JWT claims when auth.json lacks it", async () => {
    const codex = codexCredsFile();
    delete (codex["tokens"] as Record<string, unknown>)["account_id"];
    const { homeDir } = await makeFakeHome({ codex });
    const result = await discoverCodex(registry.providers.codex, { homeDir, env: {} });
    expect(result.credentials?.accountId).toBe("acct_test123");
  });
});

describe("jwt decode", () => {
  it("decodes payloads and survives garbage", () => {
    expect(decodeJwtPayload(makeJwt({ hello: "world" }))).toEqual({ hello: "world" });
    expect(decodeJwtPayload("not-a-jwt")).toBeNull();
    expect(decodeJwtPayload("a.b.c")).toBeNull();
    expect(decodeJwtPayload("")).toBeNull();
  });
});

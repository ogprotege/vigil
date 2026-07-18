import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { runLink } from "../src/commands/link.js";
import { assembleAndDecode, validateAge } from "../src/qr/payload.js";
import {
  CLAUDE_CREDS_FILE,
  codexCredsFile,
  json,
  loadFixture,
  makeFakeHome,
  startFixtureServer,
  testEnv,
  type FixtureServer,
} from "./helpers.js";

const registry = loadRegistry();

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
});

describe("link --copy --json end-to-end", () => {
  it("discovers, live-verifies, and emits a decodable paste-code", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
      "/backend-api/wham/usage": json(200, loadFixture("codex-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });

    const out: string[] = [];
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude", "codex"],
      mode: "copy",
      json: true,
      loop: false,
      big: false,
      clear: true,
      verify: true,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      http: { env: testEnv(server.url) },
      now: () => new Date("2026-07-18T20:01:00Z"),
      out: (t) => out.push(t),
      err: (t) => err.push(t),
    });

    expect(code).toBe(0);
    expect(err.join("\n")).toContain("✓ Claude: verified (ok)");
    expect(err.join("\n")).toContain("✓ ChatGPT / Codex: verified (ok)");

    const line = out.join("").trim();
    expect(line).toMatch(/^vigil1:1\/1:[A-Z2-7]{4}:/);

    const payload = assembleAndDecode([line]);
    validateAge(payload, Math.floor(new Date("2026-07-18T20:05:00Z").getTime() / 1000));
    expect(payload.accounts).toHaveLength(2);

    const claude = payload.accounts.find((a) => a.p === "claude")!;
    expect(claude.c["at"]).toBe(CLAUDE_CREDS_FILE.claudeAiOauth.accessToken);
    expect(claude.c["rt"]).toBe(CLAUDE_CREDS_FILE.claudeAiOauth.refreshToken);
    expect(claude.meta).toEqual({ plan: "max" });

    const codex = payload.accounts.find((a) => a.p === "codex")!;
    expect(codex.c["acct"]).toBe("acct_test123");
    // id_token is deliberately excluded from payloads (size).
    expect(codex.c["id"]).toBeUndefined();
  });

  it("excludes accounts that fail verification and fails cleanly when none survive", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(401, { error: "expired" }),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: true,
      loop: false,
      big: false,
      clear: true,
      verify: true,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      http: { env: testEnv(server.url) },
      out: () => {},
      err: (t) => err.push(t),
    });
    expect(code).toBe(1);
    expect(err.join("\n")).toContain("authExpired");
    expect(err.join("\n")).toContain("No account verified successfully");
  });

  it("returns 1 with guidance when no credentials exist at all", async () => {
    const { homeDir } = await makeFakeHome({});
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude", "codex"],
      mode: "copy",
      json: true,
      loop: false,
      big: false,
      clear: true,
      verify: false,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      out: () => {},
      err: (t) => err.push(t),
    });
    expect(code).toBe(1);
    expect(err.join("\n")).toContain("Nothing to link");
  });
});

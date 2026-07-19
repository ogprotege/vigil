import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { runLink } from "../src/commands/link.js";
import { statusReport } from "../src/commands/status.js";
import { assembleAndDecode, validateAge } from "../src/qr/payload.js";
import {
  CLAUDE_CREDS_FILE,
  codexCredsFile,
  json,
  loadFixture,
  makeFakeHome,
  startFixtureServer,
  fixtureHttp,
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
      yes: true,
      loop: false,
      big: false,
      clear: true,
      verify: true,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      http: fixtureHttp(server.url),
      now: () => new Date("2026-07-18T20:01:00Z"),
      out: (t) => out.push(t),
      err: (t) => err.push(t),
    });

    expect(code).toBe(0);
    expect(err.join("\n")).toContain("✓ Claude: verified (ok)");
    expect(err.join("\n")).toContain("✓ ChatGPT / Codex: verified (ok)");
    expect(err.join("\n")).toContain("contain credentials");
    expect(err.join("\n")).toContain("cannot clear a piped stream");

    const lines = out.join("").trim().split("\n");
    expect(lines[0]).toMatch(/^vigil1:1\/\d+:[A-Z2-7]{4}:/);

    const payload = assembleAndDecode(lines);
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
      yes: true,
      loop: false,
      big: false,
      clear: true,
      verify: true,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      http: fixtureHttp(server.url),
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
      yes: true,
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

  it("does not double-poll when status is followed immediately by link verification", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const now = () => new Date("2026-07-18T20:01:00Z");
    const discovery = { homeDir, platform: "linux" as const, env: {} };
    const http = fixtureHttp(server.url);

    await statusReport({ registry, discovery, http, now }, ["claude"]);
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: true,
      yes: true,
      loop: false,
      big: false,
      clear: true,
      verify: true,
      registry,
      discovery,
      http,
      now,
      out: () => {},
      err: (text) => err.push(text),
    });

    expect(code).toBe(1);
    expect(server.requests).toHaveLength(1);
    expect(err.join("\n")).toContain("deferred");
  });
});

describe("credential-display consent gate", () => {
  it("refuses --json output without --yes and emits nothing to stdout", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const out: string[] = [];
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: true,
      yes: false,
      loop: false,
      big: false,
      clear: true,
      verify: false,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      out: (t) => out.push(t),
      err: (t) => err.push(t),
    });
    expect(code).toBe(1);
    expect(out).toHaveLength(0);
    expect(err.join("\n")).toContain("Refusing to print credentials");
    expect(err.join("\n")).toContain("--yes");
  });

  it("refuses QR output without --yes when no interactive confirmation exists", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const out: string[] = [];
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: false,
      yes: false,
      loop: false,
      big: false,
      clear: true,
      verify: false,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      out: (t) => out.push(t),
      err: (t) => err.push(t),
      // confirm deliberately omitted: stdin is not a TTY.
    });
    expect(code).toBe(1);
    expect(out).toHaveLength(0);
    expect(err.join("\n")).toContain("Refusing to print credentials without --yes");
  });

  it("renders QR codes non-interactively when --yes grants consent", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const out: string[] = [];
    const err: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: false,
      yes: true,
      loop: false,
      big: false,
      clear: false,
      verify: false,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      out: (t) => out.push(t),
      err: (t) => err.push(t),
    });
    expect(code).toBe(0);
    expect(out.join("\n")).toContain("Vigil link — code 1 of");
    expect(err.join("\n")).toContain("--yes: skipping the credential-display confirmation");
  });

  it("still asks the interactive prompt when --yes is absent and honors a decline", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const out: string[] = [];
    const err: string[] = [];
    const questions: string[] = [];
    const code = await runLink({
      providers: ["claude"],
      mode: "copy",
      json: false,
      yes: false,
      loop: false,
      big: false,
      clear: true,
      verify: false,
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      out: (t) => out.push(t),
      err: (t) => err.push(t),
      confirm: async (question) => {
        questions.push(question);
        return false;
      },
    });
    expect(code).toBe(1);
    expect(questions).toHaveLength(1);
    expect(questions[0]).toContain("credentials");
    expect(out).toHaveLength(0);
    expect(err.join("\n")).toContain("Cancelled — nothing was shown.");
  });
});

import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { statusReport } from "../src/commands/status.js";
import { doctorReport } from "../src/commands/doctor.js";
import { humanizeUntil } from "../src/util/time.js";
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
// One minute before the fixture session reset at 2026-07-18T21:00:00Z minus 59m.
const NOW = () => new Date("2026-07-18T20:01:00Z");

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
});

describe("status", () => {
  it("renders both providers' windows (golden)", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
      "/backend-api/wham/usage": json(200, loadFixture("codex-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });
    const report = await statusReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        http: { env: testEnv(server.url) },
        now: NOW,
      },
      ["claude", "codex"]
    );
    expect(report).toMatchSnapshot();
    expect(report).toContain("Claude (max)");
    expect(report).toContain("ChatGPT / Codex (pro)");
    expect(report).toContain("resets in 59m");
  });

  it("reports honest states for missing creds and rate limiting", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(429, loadFixture("claude-429.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const report = await statusReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        http: { env: testEnv(server.url) },
        now: NOW,
      },
      ["claude", "codex"]
    );
    expect(report).toContain("rate-limiting");
    expect(report).toContain("no credentials found");
    expect(report).toMatchSnapshot();
  });
});

describe("doctor", () => {
  it("reports discovery results without any network calls (golden)", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });
    const report = await doctorReport(
      { registry, discovery: { homeDir, platform: "linux", env: {} }, now: NOW },
      ["claude", "codex"]
    );
    expect(report).toMatchSnapshot();
    expect(report).toContain("✓ credentials found (file)");
    expect(report).toContain("stateless");
  });

  it("flags missing credentials with the path it checked", async () => {
    const { homeDir } = await makeFakeHome({});
    const report = await doctorReport(
      { registry, discovery: { homeDir, platform: "linux", env: {} }, now: NOW },
      ["claude", "codex"]
    );
    expect(report).toContain("✗ nothing at");
    expect(report).toContain(".claude/.credentials.json");
    expect(report).toContain(".codex/auth.json");
  });
});

describe("humanizeUntil", () => {
  const now = new Date("2026-07-18T20:01:00Z");
  it("formats sensibly across scales", () => {
    expect(humanizeUntil("2026-07-18T21:00:00Z", now)).toBe("59m");
    expect(humanizeUntil("2026-07-20T07:00:00Z", now)).toBe("1d 10h");
    expect(humanizeUntil("2026-07-18T20:00:00Z", now)).toBe("now");
    expect(humanizeUntil(null, now)).toBe("—");
  });
});

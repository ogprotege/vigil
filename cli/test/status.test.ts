import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
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
  fixtureHttp,
  type FixtureServer,
} from "./helpers.js";

const registry = loadRegistry();
// One minute before the fixture session reset at 2026-07-18T21:00:00Z minus 59m.
const NOW = () => new Date("2026-07-18T20:01:00Z");

let server: FixtureServer | null = null;
const tempDirs: string[] = [];
afterEach(async () => {
  await server?.close();
  server = null;
  await Promise.all(
    tempDirs.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

async function corruptPollStateDir(providerId: string): Promise<{ stateDir: string; stateFile: string }> {
  const stateDir = await mkdtemp(path.join(tmpdir(), "vigil-corrupt-poll-"));
  tempDirs.push(stateDir);
  const stateFile = path.join(stateDir, `${providerId}.poll.json`);
  await writeFile(stateFile, "not-json\n");
  return { stateDir, stateFile };
}

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
        http: fixtureHttp(server.url),
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
        http: fixtureHttp(server.url),
        now: NOW,
      },
      ["claude", "codex"]
    );
    expect(report).toContain("rate-limiting");
    expect(report).toContain("no credentials found");
    expect(report).toMatchSnapshot();
  });

  it("isolates one provider's transport failure and still renders the others", async () => {
    server = await startFixtureServer({
      "/backend-api/wham/usage": json(200, loadFixture("codex-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });
    const isolatedFetch: typeof fetch = async (input, init) => {
      if (new URL(input.toString()).pathname === "/api/oauth/usage") {
        throw new Error("simulated provider outage");
      }
      return fetch(input, init);
    };
    const report = await statusReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        http: { ...fixtureHttp(server.url), fetchImpl: isolatedFetch, retries: 0 },
        now: NOW,
      },
      ["claude", "codex"]
    );
    expect(report).toContain("network problem reaching the provider");
    expect(report).toContain("ChatGPT / Codex (pro)");
    expect(report).toContain("72%");
  });

  it("renders scalar usage metrics for an opt-in gateway provider", async () => {
    server = await startFixtureServer({
      "/api/v1/key": json(200, loadFixture("openrouter-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({});
    const report = await statusReport(
      {
        registry,
        discovery: {
          homeDir,
          platform: "linux",
          env: { OPENROUTER_API_KEY: "sk-or-v1-test" },
        },
        http: fixtureHttp(server.url),
        now: NOW,
      },
      ["openrouter"]
    );
    expect(report).toContain("Usage (all time)");
    expect(report).toContain("12.5 USD");
    expect(report).toContain("Key limit remaining");
  });

  it("names the corrupt poll-state file and gives the recovery hint when deferred", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const { stateDir, stateFile } = await corruptPollStateDir("claude");
    const report = await statusReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        poll: { stateDir },
        now: NOW,
      },
      ["claude"]
    );
    expect(report).toContain("live check deferred locally");
    expect(report).toContain("poll-state file is corrupt or unreadable");
    expect(report).toContain(stateFile);
    expect(report).toContain("delete that file to reset this provider's poll clock");
  });
});

describe("doctor", () => {
  it("reports discovery results without any network calls (golden)", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });
    const report = await doctorReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        poll: { stateDir: "/tmp/vigil-test-poll" },
        now: NOW,
      },
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

  it("flags a corrupt poll-state file with the path and recovery guidance", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const { stateDir, stateFile } = await corruptPollStateDir("claude");
    const report = await doctorReport(
      {
        registry,
        discovery: { homeDir, platform: "linux", env: {} },
        poll: { stateDir },
        now: NOW,
      },
      ["claude", "codex"]
    );
    expect(report).toContain(`✗ poll-state file is corrupt: ${stateFile}`);
    expect(report).toContain("delete that file to reset this provider's poll clock");
    // Codex has no state file, so only the corrupt provider is flagged.
    expect(report).not.toContain("codex.poll.json");
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

import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { buildHeaders, fetchUsage, resolveUrl } from "../src/http.js";
import { getSnapshot } from "../src/service.js";
import type { Credentials } from "../src/providers/types.js";
import { fixtureHttp, json, loadFixture, startFixtureServer, type FixtureServer } from "./helpers.js";

const registry = loadRegistry();

const claudeCreds: Credentials = {
  providerId: "claude",
  accessToken: "sk-ant-oat01-LIVE",
  refreshToken: "sk-ant-ort01-LIVE",
  plan: "max",
  source: "file",
};

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
});

describe("header construction", () => {
  it("substitutes the access token and sends the load-bearing User-Agent", () => {
    const headers = buildHeaders(registry.providers.claude, claudeCreds);
    expect(headers["Authorization"]).toBe("Bearer sk-ant-oat01-LIVE");
    expect(headers["anthropic-beta"]).toBe("oauth-2025-04-20");
    expect(headers["User-Agent"]).toMatch(/^claude-code\//);
  });

  it("omits headers whose placeholder has no value (codex without account id)", () => {
    const headers = buildHeaders(registry.providers.codex, {
      providerId: "codex",
      accessToken: "tok",
      source: "file",
    });
    expect(headers["ChatGPT-Account-Id"]).toBeUndefined();
    expect(headers["Authorization"]).toBe("Bearer tok");
  });
});

describe("fetchUsage against a fixture server", () => {
  it("rejects non-loopback fixture URL overrides", () => {
    expect(() =>
      resolveUrl("https://api.anthropic.com/api/oauth/usage", "claude", {
        claude: "https://attacker.example",
      })
    ).toThrow(/loopback/);
  });

  it("returns ok + body on 200, sending the exact contract headers", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
    });
    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      ...fixtureHttp(server.url),
    });
    expect(result.status).toBe("ok");
    const seen = server.requests[0]!;
    expect(seen.headers["authorization"]).toBe("Bearer sk-ant-oat01-LIVE");
    expect(seen.headers["anthropic-beta"]).toBe("oauth-2025-04-20");
    expect(seen.headers["user-agent"]).toMatch(/^claude-code\//);
  });

  it("maps 429 to rateLimited WITHOUT retrying (respects the 429 jail)", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(429, loadFixture("claude-429.json")),
    });
    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      ...fixtureHttp(server.url),
    });
    expect(result.status).toBe("rateLimited");
    expect(server.requests.length).toBe(1);
  });

  it("maps 401 to authExpired and non-JSON to schemaChanged", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": (_req, res) => {
        res.writeHead(200, { "Content-Type": "text/html" });
        res.end("<html>maintenance</html>");
      },
    });
    const drift = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      ...fixtureHttp(server.url),
    });
    expect(drift.status).toBe("schemaChanged");
  });

  it("retries transport failures with backoff, then succeeds", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
    });
    let failures = 0;
    const flaky: typeof fetch = async (input, init) => {
      if (failures++ < 1) throw new Error("ECONNRESET");
      return fetch(input, init);
    };
    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      ...fixtureHttp(server.url),
      fetchImpl: flaky,
      retryDelayMs: 1,
    });
    expect(result.status).toBe("ok");
    expect(failures).toBe(2);
  });

  it("redacts tokens from terminal transport errors", async () => {
    const alwaysDown: typeof fetch = async () => {
      throw new Error("connect failed for Bearer sk-ant-oat01-LIVE");
    };
    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      fetchImpl: alwaysDown,
      retries: 0,
      ...fixtureHttp("http://127.0.0.1:1"),
    });
    expect(result.status).toBe("network");
    expect(result.error).toContain("[redacted]");
    expect(result.error).not.toContain("sk-ant-oat01-LIVE");
  });

  it("aborts a hung request at the configured per-attempt timeout", async () => {
    const neverResponds: typeof fetch = async (_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (signal?.aborted) {
          reject(signal.reason);
          return;
        }
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
      });

    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      fetchImpl: neverResponds,
      retries: 0,
      timeoutMs: 5,
    });
    expect(result.status).toBe("network");
  });
});

describe("getSnapshot 401 -> refresh -> retry (minted creds only)", () => {
  it("refreshes a minted token once and retries", async () => {
    let usageCalls = 0;
    server = await startFixtureServer({
      "/api/oauth/usage": (req, res) => {
        usageCalls++;
        if (req.headers["authorization"] === "Bearer sk-ant-oat01-FRESH") {
          json(200, loadFixture("claude-usage-ok.json"))(req, res, "");
        } else {
          json(401, { error: "expired" })(req, res, "");
        }
      },
      "/v1/oauth/token": json(200, {
        access_token: "sk-ant-oat01-FRESH",
        refresh_token: "sk-ant-ort01-ROTATED",
        expires_in: 28800,
      }),
    });
    const minted: Credentials = { ...claudeCreds, source: "mint" };
    const { snapshot, credentials } = await getSnapshot(registry, minted, fixtureHttp(server.url));
    expect(snapshot.status).toBe("ok");
    expect(usageCalls).toBe(2);
    expect(credentials.accessToken).toBe("sk-ant-oat01-FRESH");
    expect(credentials.refreshToken).toBe("sk-ant-ort01-ROTATED");
  });

  it("NEVER refreshes file-sourced creds (would rotate Claude Code's token)", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(401, { error: "expired" }),
      "/v1/oauth/token": json(200, { access_token: "should-not-be-called" }),
    });
    const { snapshot } = await getSnapshot(registry, claudeCreds, fixtureHttp(server.url));
    expect(snapshot.status).toBe("authExpired");
    expect(server.requests.every((r) => r.path !== "/v1/oauth/token")).toBe(true);
  });
});

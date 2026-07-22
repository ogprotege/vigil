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

  it("rejects literal and escaped-equivalent duplicate JSON keys", async () => {
    const bodies = [
      String.raw`{"five_hour":{"utilization":10,"utilization":20,"resets_at":"2026-07-22T17:00:00Z"},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}`,
      String.raw`{"five_hour":{"utilization":10,"\u0075tilization":20,"resets_at":"2026-07-22T17:00:00Z"},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}`,
    ];
    let responseIndex = 0;
    server = await startFixtureServer({
      "/api/oauth/usage": (_req, res) => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(bodies[responseIndex++]);
      },
    });

    for (const _body of bodies) {
      const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
        ...fixtureHttp(server.url),
      });
      expect(result.status).toBe("schemaChanged");
    }
  });

  it("rejects malformed UTF-8 instead of replacement-decoding it", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": (_req, res) => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(Buffer.from([0x7b, 0x22, 0x78, 0x22, 0x3a, 0xc3, 0x28, 0x7d]));
      },
    });
    const result = await fetchUsage("claude", registry.providers.claude, claudeCreds, {
      ...fixtureHttp(server.url),
    });
    expect(result.status).toBe("schemaChanged");
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

describe("provider-body errors and completeness", () => {
  it("downgrades one malformed static bucket even when another maps", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, {
        five_hour: { utilization: "wrong", resets_at: "wrong" },
        seven_day: { utilization: 12, resets_at: "2026-07-20T07:00:00Z" },
      }),
    });
    const { snapshot } = await getSnapshot(registry, claudeCreds, fixtureHttp(server.url));
    expect(snapshot.status).toBe("schemaChanged");
    expect(snapshot.windows.map((window) => window.id)).toEqual(["weekly"]);
  });

  it("downgrades partial Claude window mapping and preserves the metric", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, {
        five_hour: { utilization: "wrong", resets_at: "wrong" },
        seven_day: { utilization: "wrong", resets_at: "wrong" },
        extra_usage: { is_enabled: true, used_credits: 750, monthly_limit: 5000, currency: "USD" },
      }),
    });
    const { snapshot } = await getSnapshot(registry, claudeCreds, fixtureHttp(server.url));
    expect(snapshot.status).toBe("schemaChanged");
    expect(snapshot.metrics.find((metric) => metric.id === "extra_used")?.value).toBe(7.5);
  });

  it("downgrades a malformed Codex dynamic lane even when the primary window maps", async () => {
    server = await startFixtureServer({
      "/backend-api/wham/usage": json(200, {
        rate_limit: {
          primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
        },
        additional_rate_limits: [
          {
            limit_name: "Changed lane",
            metered_feature: "changed_lane",
            rate_limit: { primary_window: { another_percent: 5 } },
          },
        ],
      }),
    });
    const credentials: Credentials = {
      providerId: "codex",
      accessToken: "codex-token",
      accountId: "account-id",
      source: "file",
    };
    const { snapshot } = await getSnapshot(registry, credentials, fixtureHttp(server.url));
    expect(snapshot.status).toBe("schemaChanged");
    expect(snapshot.windows.map((window) => window.id)).toEqual(["session"]);
  });

  it("downgrades present wrong-shaped and garbage-only Codex lane collections", async () => {
    const credentials: Credentials = {
      providerId: "codex",
      accessToken: "codex-token",
      accountId: "account-id",
      source: "file",
    };
    const primary = {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
    };

    for (const additional_rate_limits of ["changed-wrapper", [null, "garbage", 7]]) {
      server = await startFixtureServer({
        "/backend-api/wham/usage": json(200, { ...primary, additional_rate_limits }),
      });
      const { snapshot } = await getSnapshot(registry, credentials, fixtureHttp(server.url));
      expect(snapshot.status).toBe("schemaChanged");
      expect(snapshot.windows.map((window) => window.id)).toEqual(["session"]);
      await server.close();
      server = null;
    }
  });

  it("keeps Claude Live when limits[] has no eligible weekly-scoped entry", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, {
        five_hour: { utilization: 10, resets_at: null },
        seven_day: null,
        seven_day_sonnet: null,
        seven_day_opus: null,
        limits: [
          { kind: "monthly_overage", is_active: true },
          { kind: "weekly_scoped", is_active: false },
        ],
      }),
    });
    const { snapshot } = await getSnapshot(registry, claudeCreds, fixtureHttp(server.url));
    expect(snapshot.status).toBe("ok");
    expect(snapshot.windows.map((window) => window.id)).toEqual(["session"]);
  });

  it("keeps MiniMax all-unlimited responses Live but rejects unknown empty arrays", async () => {
    server = await startFixtureServer({
      "/v1/token_plan/remains": json(200, loadFixture("minimax-usage-unlimited.json")),
    });
    const credentials: Credentials = {
      providerId: "minimax",
      accessToken: "minimax-token",
      source: "file",
    };
    const unlimited = await getSnapshot(
      registry,
      credentials,
      { fixtureBaseUrls: { minimax: server.url } }
    );
    expect(unlimited.snapshot.status).toBe("ok");
    expect(unlimited.snapshot.windows).toEqual([]);
    await server.close();

    server = await startFixtureServer({
      "/v1/token_plan/remains": json(200, {
        model_remains: [],
        base_resp: { status_code: 0 },
      }),
    });
    const unknown = await getSnapshot(
      registry,
      credentials,
      { fixtureBaseUrls: { minimax: server.url } }
    );
    expect(unknown.snapshot.status).toBe("schemaChanged");
  });

  it("fails closed when Claude sends an invalid canonical money exponent", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-invalid-canonical-exponent.json")),
    });
    const { snapshot } = await getSnapshot(registry, claudeCreds, fixtureHttp(server.url));
    expect(snapshot.status).toBe("schemaChanged");
    expect(snapshot.metrics.find((metric) => metric.id === "extra_used")).toBeUndefined();
  });

  it("classifies MiniMax and Z.ai authentication errors carried in HTTP 200 bodies", async () => {
    server = await startFixtureServer({
      "/v1/token_plan/remains": json(200, {
        base_resp: { status_code: 1004, status_msg: "login fail" },
      }),
      "/api/monitor/usage/quota/limit": json(200, {
        code: 1001,
        msg: "authentication required",
        success: false,
      }),
    });
    const miniMax = await getSnapshot(
      registry,
      { providerId: "minimax", accessToken: "bad", source: "file" },
      { fixtureBaseUrls: { minimax: server.url } }
    );
    const zAI = await getSnapshot(
      registry,
      { providerId: "zai", accessToken: "bad", source: "file" },
      { fixtureBaseUrls: { zai: server.url } }
    );
    expect(miniMax.snapshot.status).toBe("authExpired");
    expect(zAI.snapshot.status).toBe("authExpired");
  });

  it("keeps a healthy metric-only provider live", async () => {
    server = await startFixtureServer({
      "/api/v1/key": json(200, loadFixture("openrouter-usage-unlimited.json")),
    });
    const { snapshot } = await getSnapshot(
      registry,
      { providerId: "openrouter", accessToken: "key", source: "file" },
      fixtureHttp(server.url)
    );
    expect(snapshot.status).toBe("ok");
    expect(snapshot.windows).toEqual([]);
    expect(snapshot.metrics.map((metric) => metric.id)).toEqual([
      "usage_lifetime",
      "usage_daily",
      "usage_weekly",
      "usage_monthly",
      "byok_usage_lifetime",
      "byok_usage_daily",
      "byok_usage_weekly",
      "byok_usage_monthly",
    ]);
  });

  it("downgrades missing required Z.ai windows and OpenRouter usage periods", async () => {
    server = await startFixtureServer({
      "/api/monitor/usage/quota/limit": json(200, {
        code: 200,
        success: true,
        data: {
          limits: [
            {
              type: "TOKENS_LIMIT",
              unit: 3,
              number: 5,
              percentage: 17,
              nextResetTime: 1782724971179,
            },
          ],
        },
      }),
      "/api/v1/key": json(200, {
        data: { usage: 3.75, usage_monthly: 3.5 },
      }),
    });

    const zAI = await getSnapshot(
      registry,
      { providerId: "zai", accessToken: "key", source: "file" },
      { fixtureBaseUrls: { zai: server.url } }
    );
    expect(zAI.snapshot.status).toBe("schemaChanged");
    expect(zAI.snapshot.windows.map((window) => window.id)).toEqual(["session"]);

    const openRouter = await getSnapshot(
      registry,
      { providerId: "openrouter", accessToken: "key", source: "file" },
      fixtureHttp(server.url)
    );
    expect(openRouter.snapshot.status).toBe("schemaChanged");
    expect(openRouter.snapshot.metrics.map((metric) => metric.id)).toEqual([
      "usage_lifetime",
      "usage_monthly",
    ]);
  });
});

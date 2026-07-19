import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { mintClaude, parsePastedCallback } from "../src/oauth/claudeMint.js";
import { json, startFixtureServer, type FixtureServer } from "./helpers.js";

const registry = loadRegistry();
const oauth = registry.providers.claude.oauth!;

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
});

describe("parsePastedCallback", () => {
  it("accepts every shape a user might paste", () => {
    const F = "FALLBACK";
    expect(parsePastedCallback("abc123", F)).toEqual({ code: "abc123", state: F });
    expect(parsePastedCallback("abc123#st99", F)).toEqual({ code: "abc123", state: "st99" });
    expect(parsePastedCallback("abc123&state=st99", F)).toEqual({ code: "abc123", state: "st99" });
    expect(parsePastedCallback("http://127.0.0.1:54545/callback?code=abc123&state=st99", F)).toEqual({
      code: "abc123",
      state: "st99",
    });
    expect(parsePastedCallback("http://localhost:54545/callback?code=abc123", F)).toEqual({
      code: "abc123",
      state: F,
    });
    expect(() => parsePastedCallback("two words", F)).toThrow(/could not parse/);
  });
});

// Loopback ports distinct from the production 54545 so tests never collide.
describe("claude mint (PKCE loopback)", () => {
  it("completes the loopback flow: authorize -> callback -> code exchange", async () => {
    server = await startFixtureServer({
      "/v1/oauth/token": json(200, {
        access_token: "sk-ant-oat01-MINTED",
        refresh_token: "sk-ant-ort01-MINTED",
        expires_in: 28800,
      }),
    });

    const creds = await mintClaude(oauth, {
      port: 54611,
      tokenUrlOverride: `${server.url}/v1/oauth/token`,
      openBrowser: (url) => {
        // Simulate the user approving in a browser: the provider redirects
        // back to the loopback with code + state.
        const authorize = new URL(url);
        expect(authorize.origin + authorize.pathname).toBe("https://claude.ai/oauth/authorize");
        expect(authorize.searchParams.get("client_id")).toBe(oauth.clientId);
        expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
        expect(authorize.searchParams.get("code")).toBe("true");
        // Anthropic rejects short state values; state must be verifier-length.
        expect(authorize.searchParams.get("state")!.length).toBeGreaterThanOrEqual(43);
        expect(authorize.searchParams.get("scope")).toBe(oauth.scopes.join(" "));
        const redirect = new URL(authorize.searchParams.get("redirect_uri")!);
        redirect.searchParams.set("code", "auth-code-123");
        redirect.searchParams.set("state", authorize.searchParams.get("state")!);
        void fetch(redirect.toString().replace("localhost", "127.0.0.1"));
      },
    });

    expect(creds.source).toBe("mint");
    expect(creds.accessToken).toBe("sk-ant-oat01-MINTED");
    expect(creds.refreshToken).toBe("sk-ant-ort01-MINTED");

    const exchange = server.requests.find((r) => r.path === "/v1/oauth/token")!;
    const body = JSON.parse(exchange.body) as Record<string, unknown>;
    expect(body["grant_type"]).toBe("authorization_code");
    expect(body["code"]).toBe("auth-code-123");
    expect(body["client_id"]).toBe(oauth.clientId);
    expect(typeof body["code_verifier"]).toBe("string");
  });

  it("ignores a mismatched callback and still accepts the legitimate callback", async () => {
    server = await startFixtureServer({
      "/v1/oauth/token": json(200, { access_token: "sk-ant-oat01-VALID" }),
    });
    const creds = await mintClaude(oauth, {
      port: 54612,
      timeoutMs: 5000,
      tokenUrlOverride: `${server.url}/v1/oauth/token`,
      openBrowser: (url) => {
        void (async () => {
          const authorize = new URL(url);
          const redirect = new URL(authorize.searchParams.get("redirect_uri")!);
          redirect.searchParams.set("code", "auth-code-123");
          redirect.searchParams.set("state", "WRONG");
          const rejected = await fetch(
            redirect.toString().replace("localhost", "127.0.0.1")
          );
          expect(rejected.status).toBe(400);
          redirect.searchParams.set("state", authorize.searchParams.get("state")!);
          await fetch(redirect.toString().replace("localhost", "127.0.0.1"));
        })();
      },
    });
    expect(creds.accessToken).toBe("sk-ant-oat01-VALID");
  });

  it("recovers via paste when the browser can't reach the loopback", async () => {
    server = await startFixtureServer({
      "/v1/oauth/token": json(200, { access_token: "sk-ant-oat01-PASTED", refresh_token: "r", expires_in: 3600 }),
    });
    const creds = await mintClaude(oauth, {
      port: 54614,
      tokenUrlOverride: `${server.url}/v1/oauth/token`,
      openBrowser: () => {
        // Browser opens but the redirect never reaches the loopback
        // (firewall, wrong browser profile, CLI machine != browser machine).
      },
      promptPaste: async (url) => {
        // User pastes the full failed-callback URL from the address bar.
        const state = new URL(url).searchParams.get("state")!;
        return `http://127.0.0.1:54614/callback?code=paste-code-789&state=${state}`;
      },
    });
    expect(creds.accessToken).toBe("sk-ant-oat01-PASTED");
    const exchange = server.requests.find((r) => r.path === "/v1/oauth/token")!;
    expect((JSON.parse(exchange.body) as Record<string, unknown>)["code"]).toBe("paste-code-789");
  });

  it("falls back to manual code paste when the loopback port is taken", async () => {
    server = await startFixtureServer({
      "/v1/oauth/token": json(200, { access_token: "sk-ant-oat01-MANUAL" }),
    });
    // Occupy the port so listenLoopback fails.
    const { createServer } = await import("node:http");
    const blocker = createServer(() => {});
    await new Promise<void>((resolve) => blocker.listen(54613, "127.0.0.1", resolve));
    try {
      const creds = await mintClaude(oauth, {
        port: 54613,
        tokenUrlOverride: `${server.url}/v1/oauth/token`,
        promptPaste: async (url) => {
          const state = new URL(url).searchParams.get("state")!;
          expect(url).toContain(encodeURIComponent(oauth.manualRedirectUri));
          return `manual-code-456#${state}`;
        },
      });
      expect(creds.accessToken).toBe("sk-ant-oat01-MANUAL");
    } finally {
      await new Promise<void>((resolve) => blocker.close(() => resolve()));
    }
  });
});

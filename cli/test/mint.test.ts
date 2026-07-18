import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import { mintClaude } from "../src/oauth/claudeMint.js";
import { json, startFixtureServer, type FixtureServer } from "./helpers.js";

const registry = loadRegistry();
const oauth = registry.providers.claude.oauth!;

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
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

  it("aborts on state mismatch (interception guard)", async () => {
    server = await startFixtureServer({
      "/v1/oauth/token": json(200, { access_token: "nope" }),
    });
    await expect(
      mintClaude(oauth, {
        port: 54612,
        timeoutMs: 5000,
        tokenUrlOverride: `${server.url}/v1/oauth/token`,
        openBrowser: (url) => {
          const authorize = new URL(url);
          const redirect = new URL(authorize.searchParams.get("redirect_uri")!);
          redirect.searchParams.set("code", "auth-code-123");
          redirect.searchParams.set("state", "WRONG");
          void fetch(redirect.toString().replace("localhost", "127.0.0.1"));
        },
      })
    ).rejects.toThrow(/state mismatch/);
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

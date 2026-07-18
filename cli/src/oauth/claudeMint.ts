import { createServer, type Server } from "node:http";
import type { OAuthSpec } from "../spec/registry.js";
import type { Credentials } from "../providers/types.js";
import { generatePkce } from "./pkce.js";

export interface MintOptions {
  fetchImpl?: typeof fetch;
  openBrowser?: (url: string) => void;
  /** Prompt for the manual "code#state" paste fallback. */
  promptPaste?: (authorizeUrl: string) => Promise<string>;
  port?: number;
  timeoutMs?: number;
  tokenUrlOverride?: string;
}

async function defaultOpenBrowser(url: string): Promise<void> {
  const { spawn } = await import("node:child_process");
  const platform = process.platform;
  const [command, args] =
    platform === "darwin"
      ? ["open", [url]]
      : platform === "win32"
        ? ["cmd", ["/c", "start", "", url]]
        : ["xdg-open", [url]];
  spawn(command, args as string[], { stdio: "ignore", detached: true }).unref();
}

function authorizeUrl(oauth: OAuthSpec, redirectUri: string, challenge: string, state: string): string {
  const url = new URL(oauth.authorizeUrl);
  url.searchParams.set("client_id", oauth.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("scope", oauth.scopes.join(" "));
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  return url.toString();
}

async function exchangeCode(
  oauth: OAuthSpec,
  opts: MintOptions,
  params: { code: string; redirectUri: string; verifier: string; state: string }
): Promise<Credentials> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const response = await fetchImpl(opts.tokenUrlOverride ?? oauth.tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code: params.code,
      redirect_uri: params.redirectUri,
      client_id: oauth.clientId,
      code_verifier: params.verifier,
      state: params.state,
    }),
  });
  if (!response.ok) {
    throw new Error(`token exchange failed (HTTP ${response.status})`);
  }
  const body = (await response.json()) as Record<string, unknown>;
  const accessToken = body["access_token"];
  if (typeof accessToken !== "string" || accessToken.length === 0) {
    throw new Error("token exchange returned no access_token");
  }
  const expiresIn = typeof body["expires_in"] === "number" ? (body["expires_in"] as number) : undefined;
  return {
    providerId: "claude",
    accessToken,
    refreshToken: typeof body["refresh_token"] === "string" ? (body["refresh_token"] as string) : undefined,
    expiresAt: expiresIn ? Math.floor(Date.now() / 1000) + expiresIn : undefined,
    label: "Claude",
    source: "mint",
  };
}

function listenLoopback(port: number): Promise<{ server: Server; codePromise: Promise<{ code: string; state: string }> }> {
  return new Promise((resolveListen, rejectListen) => {
    let resolveCode: (v: { code: string; state: string }) => void;
    let rejectCode: (e: Error) => void;
    const codePromise = new Promise<{ code: string; state: string }>((res, rej) => {
      resolveCode = res;
      rejectCode = rej;
    });

    const server = createServer((req, res) => {
      const url = new URL(req.url ?? "/", `http://127.0.0.1:${port}`);
      if (url.pathname !== "/callback") {
        res.writeHead(404).end();
        return;
      }
      const code = url.searchParams.get("code");
      const state = url.searchParams.get("state");
      const error = url.searchParams.get("error");
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(
        "<html><body style=\"font-family:system-ui;padding:2rem\"><h2>Vigil is linked.</h2><p>You can close this tab and return to your terminal.</p></body></html>"
      );
      if (error) rejectCode(new Error(`authorization denied: ${error}`));
      else if (code && state) resolveCode({ code, state });
      else rejectCode(new Error("callback missing code/state"));
    });

    server.once("error", rejectListen);
    server.listen(port, "127.0.0.1", () => resolveListen({ server, codePromise }));
  });
}

/**
 * Mints Vigil its own Claude token pair via browser OAuth + PKCE (ADR-0005).
 * Ladder: loopback redirect -> manual code paste -> caller falls back to --copy.
 */
export async function mintClaude(oauth: OAuthSpec, opts: MintOptions = {}): Promise<Credentials> {
  const pkce = generatePkce();
  const port = opts.port ?? oauth.loopbackPort;
  const timeoutMs = opts.timeoutMs ?? 300_000;
  const open = opts.openBrowser ?? defaultOpenBrowser;

  let loopback: Awaited<ReturnType<typeof listenLoopback>> | null = null;
  try {
    loopback = await listenLoopback(port);
  } catch {
    loopback = null; // port busy or sandboxed — manual fallback below
  }

  if (loopback) {
    const redirectUri = `http://localhost:${port}/callback`;
    const url = authorizeUrl(oauth, redirectUri, pkce.challenge, pkce.state);
    try {
      open(url);
      const timeout = new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("timed out waiting for browser authorization")), timeoutMs).unref()
      );
      const { code, state } = await Promise.race([loopback.codePromise, timeout]);
      if (state !== pkce.state) throw new Error("state mismatch — possible interception, aborting");
      return await exchangeCode(oauth, opts, { code, redirectUri, verifier: pkce.verifier, state });
    } finally {
      loopback.server.close();
    }
  }

  if (!opts.promptPaste) {
    throw new Error(`could not open loopback port ${port} and no manual-paste prompt available`);
  }
  const url = authorizeUrl(oauth, oauth.manualRedirectUri, pkce.challenge, pkce.state);
  const pasted = (await opts.promptPaste(url)).trim();
  const [code, state] = pasted.includes("#") ? pasted.split("#", 2) : [pasted, pkce.state];
  if (!code) throw new Error("no authorization code pasted");
  if (state !== pkce.state) throw new Error("state mismatch in pasted code");
  return exchangeCode(oauth, opts, {
    code,
    redirectUri: oauth.manualRedirectUri,
    verifier: pkce.verifier,
    state: pkce.state,
  });
}

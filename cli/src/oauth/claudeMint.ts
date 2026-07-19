import { spawn } from "node:child_process";
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
  /** Timeout for the final token exchange. Defaults to 15 seconds. */
  tokenTimeoutMs?: number;
  tokenUrlOverride?: string;
}

function defaultOpenBrowser(url: string): void {
  const platform = process.platform;
  const [command, args] =
    platform === "darwin"
      ? ["open", [url]]
      : platform === "win32"
        ? ["cmd", ["/c", "start", "", url]]
        : ["xdg-open", [url]];
  const child = spawn(command, args as string[], { stdio: "ignore", detached: true });
  // Missing desktop opener is recoverable because the CLI prints a manual URL
  // and accepts a pasted callback. Do not let an unhandled ChildProcess error
  // terminate the credential flow.
  child.on("error", () => {});
  child.unref();
}

function authorizeUrl(oauth: OAuthSpec, redirectUri: string, challenge: string, state: string): string {
  const url = new URL(oauth.authorizeUrl);
  // Anthropic's authorize endpoint rejects requests without code=true
  // ("invalid request format", observed live 2026-07-18).
  url.searchParams.set("code", "true");
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
    signal: AbortSignal.timeout(Math.max(1, opts.tokenTimeoutMs ?? 15_000)),
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
  const expiresValue = body["expires_in"];
  const expiresIn =
    typeof expiresValue === "number" &&
    Number.isFinite(expiresValue) &&
    expiresValue > 0
      ? expiresValue
      : undefined;
  return {
    providerId: "claude",
    accessToken,
    refreshToken: typeof body["refresh_token"] === "string" ? (body["refresh_token"] as string) : undefined,
    expiresAt: expiresIn ? Math.floor(Date.now() / 1000) + expiresIn : undefined,
    label: "Claude",
    source: "mint",
  };
}

/**
 * Parses whatever the user pastes after authorizing: a full callback URL
 * (including one copied from a "can't connect to localhost" error page), a
 * "code#state" pair, "code&state=...", or a bare code.
 */
export function parsePastedCallback(input: string, fallbackState: string): { code: string; state: string } {
  const text = input.trim();
  const fromUrl = /[?&]code=([^&\s]+)(?:&state=([^&\s]+))?/.exec(text);
  if (fromUrl) {
    return {
      code: decodeURIComponent(fromUrl[1]!),
      state: fromUrl[2] ? decodeURIComponent(fromUrl[2]) : fallbackState,
    };
  }
  const bare = /^([^#&\s]+)(?:(?:#|&state=)([^&\s]+))?$/.exec(text);
  if (!bare) throw new Error("could not parse the pasted code — paste the full callback URL or code#state");
  return { code: bare[1]!, state: bare[2] ?? fallbackState };
}

function listenLoopback(
  port: number,
  expectedState: string
): Promise<{ server: Server; codePromise: Promise<{ code: string; state: string }> }> {
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
      const headers = {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        Pragma: "no-cache",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
      };
      if (state !== expectedState) {
        // Ignore unsolicited or stale callbacks so they cannot cancel the
        // legitimate authorization still in progress.
        res.writeHead(400, headers);
        res.end("<html><body><h2>Invalid authorization state.</h2></body></html>");
        return;
      }
      if (error) {
        res.writeHead(400, headers);
        res.end("<html><body><h2>Authorization was not completed.</h2></body></html>");
        rejectCode(new Error(`authorization denied: ${error}`));
        return;
      }
      if (!code) {
        res.writeHead(400, headers);
        res.end("<html><body><h2>Authorization code is missing.</h2></body></html>");
        return;
      }
      res.writeHead(200, headers);
      res.end(
        "<html><body style=\"font-family:system-ui;padding:2rem\"><h2>Vigil is linked.</h2><p>You can close this tab and return to your terminal.</p></body></html>"
      );
      resolveCode({ code, state });
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
  // Generous window: signing in via emailed code (fresh browser session)
  // routinely takes longer than 5 minutes.
  const timeoutMs = opts.timeoutMs ?? 900_000;
  const open = opts.openBrowser ?? defaultOpenBrowser;

  let loopback: Awaited<ReturnType<typeof listenLoopback>> | null = null;
  try {
    loopback = await listenLoopback(port, pkce.state);
  } catch {
    loopback = null; // port busy or sandboxed — manual fallback below
  }

  if (loopback) {
    // Must be the literal host "localhost": the client's allowlist rejects
    // http://127.0.0.1:<port>/callback ("Redirect URI ... is not supported by
    // client", observed live 2026-07-18). Browsers fall back to the IPv4
    // listener when resolving localhost.
    const redirectUri = `http://localhost:${port}/callback`;
    const url = authorizeUrl(oauth, redirectUri, pkce.challenge, pkce.state);
    try {
      open(url);
      const timeout = new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("timed out waiting for browser authorization")), timeoutMs).unref()
      );
      const racers: Promise<{ code: string; state: string }>[] = [loopback.codePromise];
      if (opts.promptPaste) {
        // Recovery lane: if the browser can't reach the loopback (or the user
        // prefers pasting), accept the callback URL / code at any time.
        const paste = opts.promptPaste(url).then(async (pasted) => {
          if (!pasted.trim()) return new Promise<never>(() => {}); // ignore stray Enter
          return parsePastedCallback(pasted, pkce.state);
        });
        paste.catch(() => {}); // readline may close after the browser lane wins
        racers.push(paste as Promise<{ code: string; state: string }>);
      }
      const { code, state } = await Promise.race([...racers, timeout]);
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
  if (!pasted) throw new Error("no authorization code pasted");
  const { code, state } = parsePastedCallback(pasted, pkce.state);
  if (state !== pkce.state) throw new Error("state mismatch in pasted code");
  return exchangeCode(oauth, opts, {
    code,
    redirectUri: oauth.manualRedirectUri,
    verifier: pkce.verifier,
    state: pkce.state,
  });
}

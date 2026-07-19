import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export function loadFixture(name: string): unknown {
  return JSON.parse(readFileSync(path.join(REPO_ROOT, "protocol", "fixtures", name), "utf8"));
}

export type RouteHandler = (req: IncomingMessage, res: ServerResponse, body: string) => void;

export interface FixtureServer {
  url: string;
  close: () => Promise<void>;
  requests: Array<{ method: string; path: string; headers: IncomingMessage["headers"]; body: string }>;
}

export async function startFixtureServer(routes: Record<string, RouteHandler>): Promise<FixtureServer> {
  const requests: FixtureServer["requests"] = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const pathname = new URL(req.url ?? "/", "http://localhost").pathname;
      requests.push({ method: req.method ?? "GET", path: pathname, headers: req.headers, body });
      const handler = routes[pathname];
      if (!handler) {
        res.writeHead(404).end("not found");
        return;
      }
      handler(req, res, body);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no address");
  return {
    url: `http://127.0.0.1:${address.port}`,
    requests,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

export function json(status: number, payload: unknown): RouteHandler {
  return (_req, res) => {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(payload));
  };
}

export function makeJwt(payload: Record<string, unknown>): string {
  const enc = (obj: unknown) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  return `${enc({ alg: "none", typ: "JWT" })}.${enc(payload)}.sig`;
}

export interface FakeHome {
  homeDir: string;
}

export async function makeFakeHome(opts: {
  claude?: Record<string, unknown> | null;
  codex?: Record<string, unknown> | null;
}): Promise<FakeHome> {
  const homeDir = await mkdtemp(path.join(tmpdir(), "vigil-test-home-"));
  if (opts.claude) {
    await mkdir(path.join(homeDir, ".claude"), { recursive: true });
    await writeFile(path.join(homeDir, ".claude", ".credentials.json"), JSON.stringify(opts.claude));
  }
  if (opts.codex) {
    await mkdir(path.join(homeDir, ".codex"), { recursive: true });
    await writeFile(path.join(homeDir, ".codex", "auth.json"), JSON.stringify(opts.codex));
  }
  return { homeDir };
}

export const CLAUDE_CREDS_FILE = {
  claudeAiOauth: {
    accessToken: "sk-ant-oat01-TESTTOKENTESTTOKENTESTTOKEN",
    refreshToken: "sk-ant-ort01-TESTREFRESHTESTREFRESH",
    expiresAt: 1784412000000,
    scopes: ["user:profile", "user:inference"],
    subscriptionType: "max",
  },
};

export function codexCredsFile(): Record<string, unknown> {
  return {
    tokens: {
      access_token: makeJwt({
        exp: 1784500000,
        "https://api.openai.com/auth": { chatgpt_account_id: "acct_test123", chatgpt_plan_type: "pro" },
      }),
      refresh_token: "codex-refresh-token-test",
      id_token: makeJwt({
        email: "you@example.com",
        "https://api.openai.com/auth": { chatgpt_account_id: "acct_test123", chatgpt_plan_type: "pro" },
      }),
      account_id: "acct_test123",
    },
    last_refresh: "2026-07-18T00:00:00Z",
  };
}

export function fixtureHttp(claudeBase: string, codexBase?: string): {
  fixtureBaseUrls: Record<string, string>;
} {
  return {
    fixtureBaseUrls: {
      claude: claudeBase,
      codex: codexBase ?? claudeBase,
      openrouter: claudeBase,
      deepseek: claudeBase,
    },
  };
}

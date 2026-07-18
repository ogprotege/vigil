import { readFile } from "node:fs/promises";
import path from "node:path";
import type { ProviderSpec } from "../spec/registry.js";
import type { Credentials } from "../providers/types.js";
import { decodeJwtPayload } from "../util/jwt.js";
import { homeDir, type DiscoveryOptions } from "./paths.js";

export interface CodexDiscovery {
  credentials: Credentials | null;
  filePath: string;
}

interface CodexTokens {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
  account_id?: string;
}

function claim(payload: Record<string, unknown> | null, key: string): string | undefined {
  if (!payload) return undefined;
  const direct = payload[key];
  if (typeof direct === "string") return direct;
  const auth = payload["https://api.openai.com/auth"];
  if (auth !== null && typeof auth === "object") {
    const nested = (auth as Record<string, unknown>)[key];
    if (typeof nested === "string") return nested;
  }
  return undefined;
}

export async function discoverCodex(
  spec: ProviderSpec,
  opts: DiscoveryOptions = {}
): Promise<CodexDiscovery> {
  const env = opts.env ?? process.env;
  const codexHome = env["CODEX_HOME"];
  const filePath = codexHome
    ? path.join(codexHome, "auth.json")
    : path.join(homeDir(opts), ".codex", "auth.json");

  let json: string;
  try {
    json = await readFile(filePath, "utf8");
  } catch {
    return { credentials: null, filePath };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return { credentials: null, filePath };
  }
  if (parsed === null || typeof parsed !== "object") return { credentials: null, filePath };

  const tokens = ((parsed as Record<string, unknown>)["tokens"] ?? parsed) as CodexTokens;
  if (typeof tokens.access_token !== "string" || tokens.access_token.length === 0) {
    return { credentials: null, filePath };
  }

  const idPayload = typeof tokens.id_token === "string" ? decodeJwtPayload(tokens.id_token) : null;
  const accountId =
    (typeof tokens.account_id === "string" ? tokens.account_id : undefined) ??
    claim(idPayload, "chatgpt_account_id");
  const plan = claim(idPayload, "chatgpt_plan_type");
  const email = idPayload && typeof idPayload["email"] === "string" ? (idPayload["email"] as string) : undefined;

  const accessPayload = decodeJwtPayload(tokens.access_token);
  const exp = accessPayload && typeof accessPayload["exp"] === "number" ? (accessPayload["exp"] as number) : undefined;

  return {
    filePath,
    credentials: {
      providerId: "codex",
      accessToken: tokens.access_token,
      refreshToken: typeof tokens.refresh_token === "string" ? tokens.refresh_token : undefined,
      expiresAt: exp,
      accountId,
      plan,
      label: [plan ? `ChatGPT (${plan})` : "ChatGPT", email].filter(Boolean).join(" — "),
      source: "file",
    },
  };
}

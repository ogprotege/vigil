import { readFile } from "node:fs/promises";
import path from "node:path";
import type { ProviderSpec } from "../spec/registry.js";
import type { Credentials } from "../providers/types.js";
import { defaultExecFile, homeDir, type DiscoveryOptions } from "./paths.js";

interface ClaudeOauthBlob {
  accessToken?: string;
  refreshToken?: string;
  expiresAt?: number;
  scopes?: string[];
  subscriptionType?: string;
}

function parseBlob(json: string): Credentials | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object") return null;
  const root = parsed as Record<string, unknown>;
  const blob = (root["claudeAiOauth"] ?? root) as ClaudeOauthBlob;
  if (typeof blob.accessToken !== "string" || blob.accessToken.length === 0) return null;

  // Claude Code stores expiresAt in epoch milliseconds; normalize to seconds.
  let expiresAt: number | undefined;
  if (typeof blob.expiresAt === "number" && Number.isFinite(blob.expiresAt)) {
    expiresAt = blob.expiresAt > 1e12 ? Math.floor(blob.expiresAt / 1000) : blob.expiresAt;
  }

  return {
    providerId: "claude",
    accessToken: blob.accessToken,
    refreshToken: typeof blob.refreshToken === "string" ? blob.refreshToken : undefined,
    expiresAt,
    plan: typeof blob.subscriptionType === "string" ? blob.subscriptionType : undefined,
    label: blob.subscriptionType ? `Claude (${blob.subscriptionType})` : "Claude",
    source: "file",
  };
}

export interface ClaudeDiscovery {
  credentials: Credentials | null;
  /** Where the credentials were found (for doctor output). */
  location: "file" | "keychain" | null;
  filePath: string;
}

export async function discoverClaude(
  spec: ProviderSpec,
  opts: DiscoveryOptions = {}
): Promise<ClaudeDiscovery> {
  const relative = spec.discovery.file?.path ?? "~/.claude/.credentials.json";
  const filePath = relative.startsWith("~/")
    ? path.join(homeDir(opts), relative.slice(2))
    : relative;

  try {
    const json = await readFile(filePath, "utf8");
    const credentials = parseBlob(json);
    if (credentials) return { credentials, location: "file", filePath };
  } catch {
    // fall through to keychain
  }

  const platform = opts.platform ?? process.platform;
  const service = spec.discovery.macosKeychain?.service;
  if (platform === "darwin" && service) {
    const exec = opts.execFile ?? defaultExecFile;
    try {
      const { stdout } = await exec("security", ["find-generic-password", "-s", service, "-w"]);
      const credentials = parseBlob(stdout.trim());
      if (credentials) {
        return { credentials: { ...credentials, source: "keychain" }, location: "keychain", filePath };
      }
    } catch {
      // not found in keychain either
    }
  }

  return { credentials: null, location: null, filePath };
}

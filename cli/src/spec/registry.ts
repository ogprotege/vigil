import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type ProviderId = "claude" | "codex";

export interface WindowSpec {
  id: string;
  sourceKey: string;
  resetFormat: "iso8601" | "unixSeconds";
  windowSeconds?: number;
  secondary: boolean;
}

export interface PollSpec {
  minSeconds: number;
  jitterSeconds: number;
  backoff429BaseSeconds: number;
  backoffMaxSeconds: number;
}

export interface OAuthSpec {
  authorizeUrl: string;
  tokenUrl: string;
  clientId: string;
  scopes: string[];
  loopbackPort: number;
  manualRedirectUri: string;
}

export interface UsageRequestSpec {
  method: string;
  url: string;
  headers: Record<string, string>;
}

export interface DiscoverySpec {
  file?: { path: string; jsonPath: string };
  macosKeychain?: { service: string };
}

export interface ResponseFieldsSpec {
  utilization: string;
  resetsAt: string;
  windowSeconds?: string;
}

export interface AdditionalWindowsSpec {
  sourceKey: string;
  idKey: string;
  secondary: boolean;
}

export interface ProviderSpec {
  displayName: string;
  auth: string;
  usage: UsageRequestSpec;
  oauth?: OAuthSpec;
  poll: PollSpec;
  discovery: DiscoverySpec;
  responseFields: ResponseFieldsSpec;
  planKey?: string;
  additionalWindows?: AdditionalWindowsSpec;
  windows: WindowSpec[];
  capabilities: string[];
}

export interface Registry {
  version: number;
  providers: Record<ProviderId, ProviderSpec>;
}

export const PROVIDER_IDS: ProviderId[] = ["claude", "codex"];

function specPath(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    // packaged: dist/spec/registry.js -> dist/providers.json
    path.join(here, "..", "providers.json"),
    // repo: cli/src/spec/registry.ts -> protocol/providers.json
    path.join(here, "..", "..", "..", "protocol", "providers.json"),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error("providers.json not found (looked in package dist/ and repo protocol/)");
}

export function loadRegistry(): Registry {
  return JSON.parse(readFileSync(specPath(), "utf8")) as Registry;
}

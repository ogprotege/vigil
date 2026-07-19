import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Provider IDs are registry keys, not a closed compile-time union. This keeps
 * the CLI able to consume newly generated registry entries without another
 * round of command parsing changes.
 */
export type ProviderId = string;

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
  adapter?: "claude" | "codex" | "environment" | string;
  file?: { path: string; jsonPath: string };
  macosKeychain?: { service: string };
  environment?: {
    accessToken: string;
    accountId?: string;
    label?: string;
  };
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

export type UsageMetricKind = "balance" | "spend" | "limit" | "remaining";

export interface MetricMappingSpec {
  id: string;
  label: string;
  sourceKey: string;
  kind: UsageMetricKind;
  unit?: string;
  secondary: boolean;
}

export interface MetricCollectionMappingSpec {
  sourceKey: string;
  idKey: string;
  valueKey: string;
  label: string;
  kind: UsageMetricKind;
  unitKey?: string;
  secondary: boolean;
}

export interface ProviderSpec {
  displayName: string;
  /** Omitted means enabled. Opt-in providers set this to false. */
  defaultEnabled?: boolean;
  auth: string;
  usage: UsageRequestSpec;
  oauth?: OAuthSpec;
  poll: PollSpec;
  discovery: DiscoverySpec;
  manualEntryHint?: string;
  responseFields?: ResponseFieldsSpec;
  planKey?: string;
  additionalWindows?: AdditionalWindowsSpec;
  metricMappings?: MetricMappingSpec[];
  metricCollectionMappings?: MetricCollectionMappingSpec[];
  windows: WindowSpec[];
  capabilities: string[];
}

export interface Registry {
  version: number;
  providers: Record<ProviderId, ProviderSpec>;
}

export function providerIds(registry: Registry, includeOptIn = false): ProviderId[] {
  return Object.entries(registry.providers)
    .filter(([, spec]) => includeOptIn || spec.defaultEnabled !== false)
    .map(([id]) => id);
}

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
  const parsed = JSON.parse(readFileSync(specPath(), "utf8")) as Registry;
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    typeof parsed.version !== "number" ||
    parsed.providers === null ||
    typeof parsed.providers !== "object"
  ) {
    throw new Error("providers.json has an invalid registry shape");
  }
  return parsed;
}

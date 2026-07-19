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
  resetFormat: "iso8601" | "unixSeconds" | "unixMillis";
  windowSeconds?: number;
  secondary: boolean;
  /** Per-window override of the provider's responseFields (e.g. MiniMax
   * exposes the session and weekly numbers under different keys of one
   * bucket). */
  fields?: { utilization: string; resetsAt: string };
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

/**
 * A query parameter is either a literal value or one computed client-side at
 * request time from a small closed vocabulary (billing APIs need time
 * ranges). The vocabulary is deliberately tiny so both implementations stay
 * trivially in lockstep.
 */
export type QueryParamSpec =
  | { value: string }
  | { compute: "monthStartUnixSeconds" | "currentYear" | "currentMonth" };

export interface UsageRequestSpec {
  method: string;
  /** May contain {account_id}, substituted from the credential (GitHub
   * usernames, xAI team ids). A URL needing an id the credential lacks
   * yields no request. */
  url: string;
  headers: Record<string, string>;
  query?: Record<string, QueryParamSpec>;
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
  /** "remaining" inverts the percentage (utilization = 100 - value) for
   * providers that report quota left instead of quota used. Default "used". */
  utilizationKind?: "used" | "remaining";
  /** Providers that serialize window numbers as JSON strings ("46.5"). */
  allowStringNumbers?: boolean;
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
  /** With aggregate, path segments ending in [] flat-map arrays
   * (data[].results[].amount.value collects every matching leaf). */
  sourceKey: string;
  kind: UsageMetricKind;
  unit?: string;
  secondary: boolean;
  /** "sum" adds every value the sourceKey resolves to (billing buckets). */
  aggregate?: "sum";
  /** Multiplier applied after resolution (0.01 converts cents to dollars). */
  scale?: number;
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
  /** Community-proven but undocumented endpoint: surfaced in UI and docs so
   * nobody mistakes it for a vendor-supported integration. */
  experimental?: boolean;
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

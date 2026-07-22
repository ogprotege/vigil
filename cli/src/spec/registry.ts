import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Provider IDs are registry keys, not a closed compile-time union. This keeps
 * the CLI able to consume newly generated registry entries without another
 * round of command parsing changes.
 */
export type ProviderId = string;

export type WindowSourceContainer = "object" | "array";

export interface WindowSpec {
  id: string;
  sourceKey: string;
  /** Exact provider container at sourceKey/sourceKeys. A changed object/array
   * wrapper is schema drift, never a singleton compatibility guess. */
  sourceContainer: WindowSourceContainer;
  /** Ordered fallbacks for APIs that have shipped more than one wrapper
   * shape. The first path that resolves wins. */
  sourceKeys?: string[];
  resetFormat: "iso8601" | "unixSeconds" | "unixMillis";
  windowSeconds?: number;
  secondary: boolean;
  /** Keep the resolved bucket only when every predicate matches. Numeric and
   * boolean response values are compared using their JSON string form. */
  conditions?: FieldConditionSpec[];
  /** Keep a bucket when at least one predicate matches. This composes with
   * `conditions` and supports APIs that renamed an identity field while
   * retaining the same value. */
  anyConditions?: FieldConditionSpec[];
  /** Alias keys that identify the same entry. When more than one is present,
   * their scalar values must agree. */
  identityAliases?: string[];
  /** Suppress a bucket when every predicate matches. Missing fields do not
   * suppress it, which matters for optional entitlement flags. */
  omitWhen?: FieldConditionSpec[];
  /** Some APIs move a sole weekly limit into their primary slot. Prefer the
   * response's explicit duration over the slot name when it is available. */
  idByWindowSeconds?: Record<string, string>;
  /** Derive the actual window duration from a provider `(unit, number)` pair
   * and optionally use a duration range to select an array entry. */
  duration?: WindowDurationSpec;
  /** Optional provider-facing label for the window. */
  label?: string;
  /** Per-window override of the provider's responseFields (e.g. MiniMax
   * exposes the session and weekly numbers under different keys of one
   * bucket). */
  fields?: WindowFieldsSpec;
  /** A present bucket whose candidate value is absent/null is drift unless
   * this is false. Cursor uses false for ordered and optional subfields. */
  requiredWhenPresent?: boolean;
  /** Ordered candidates sharing a group stop after the first successful map. */
  fallbackGroup?: string;
}

export interface WindowDurationSpec {
  unitKey: string;
  numberKey: string;
  unitSeconds: Record<string, number>;
  /** When supplied, only these exact derived durations are eligible. */
  allowedSeconds?: number[];
  minimumSeconds?: number;
  maximumSecondsExclusive?: number;
}

export interface FieldConditionSpec {
  key: string;
  equals: string;
  /** Optional JSON scalar type. Used when stringifying values would make an
   * invalid provider value look equivalent to the observed contract. */
  valueType?: "boolean" | "number" | "string";
  /** Explicit, well-formed values that mean this entry is ineligible. Any
   * other non-match is schema drift. */
  allowedNonMatches?: string[];
}

export interface WindowFieldsSpec {
  /** Direct 0-100 percentage. Omit when `used` + `limit` are supplied. */
  utilization?: string;
  resetsAt: string;
  /** Absolute used and limit values, converted to used / limit * 100. */
  used?: string;
  limit?: string;
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
  /** OpenAI Codex device-authorization-grant endpoints (app-side, on-device
   * sign-in). Absent for providers that use the auth-code flow. */
  deviceCodeUrl?: string;
  deviceTokenUrl?: string;
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
  /** Array of dynamic window entries in the response. */
  sourceKey: string;
  /** Dot-path (within each entry) to the string used as the window id. */
  idKey: string;
  /** Observed machine-id grammar. Codex metered_feature is an ASCII slug;
   * rejecting arbitrary Unicode also keeps JS and Swift identity equal. */
  idFormat?: "asciiSlug";
  secondary: boolean;
  /** Keep only entries whose `key` string-equals `equals` (e.g. Claude's
   * limits[] carries many kinds; take just `weekly_scoped`). */
  filter?: { key: string; equals: string };
  /** Reset encoding for these entries. Defaults to unixSeconds (Codex). */
  resetFormat?: "iso8601" | "unixSeconds" | "unixMillis";
  /** When set, the id is `${idPrefix}_${normalized(idKey value)}` — a stable,
   * safe key. Absent means the raw idKey value is the id (Codex lanes). */
  idPrefix?: string;
  /** Dot-path to a human display label carried verbatim on the window. */
  labelKey?: string;
  /** Static duration for these windows, in seconds. */
  windowSeconds?: number;
  /** Per-entry override of the provider's responseFields. */
  fields?: WindowFieldsSpec;
  /** Treat a present non-array source and eligible entries that map no child
   * windows as drift. Unfiltered non-empty arrays must contain at least one
   * mappable object; a filtered array may legitimately have zero matches. */
  requiredWhenPresent?: boolean;
  conditions?: FieldConditionSpec[];
  /** One array entry can carry multiple nested quota windows. OpenAI Codex,
   * for example, nests primary and secondary windows under one model lane. */
  entryWindows?: AdditionalEntryWindowSpec[];
}

export interface AdditionalEntryWindowSpec {
  sourceKey: string;
  sourceContainer: WindowSourceContainer;
  idSuffix: string;
  idSuffixByWindowSeconds?: Record<string, string>;
  labelSuffix?: string;
  labelSuffixByWindowSeconds?: Record<string, string>;
  resetFormat?: "iso8601" | "unixSeconds" | "unixMillis";
  windowSeconds?: number;
  secondary?: boolean;
  fields?: WindowFieldsSpec;
}

export interface ResponseEnvelopeSpec {
  /** Provider-defined status code carried inside an HTTP 2xx body. */
  codeKey: string;
  okCode: string;
  codeValueType?: "boolean" | "number" | "string";
  /** Optional redundant success flag, also carried in the body. */
  successKey?: string;
  successValue?: string;
  successValueType?: "boolean" | "number" | "string";
  /** Codes that mean the credential is invalid or expired. */
  authCodes?: string[];
}

export interface RequiredOutputsSpec {
  minimumWindows?: number;
  minimumPrimaryWindows?: number;
  windowIds?: string[];
  minimumMetrics?: number;
  metricIds?: string[];
}

/** A provider response that legitimately yields no finite quota windows.
 * The first non-empty array found at sourceKeys is recognized only when every
 * entry is an object matching every condition. This keeps an explicit
 * unlimited state distinct from an unknown or malformed empty payload. */
export interface RecognizedEmptySpec {
  sourceKeys: string[];
  allEntriesMatch: FieldConditionSpec[];
}

/** An exhaustive provider array. Every entry identity must be known; wrapper
 * fallbacks are mutually exclusive; selected identities may constrain the
 * complete set of supported quota durations. */
export interface ExhaustiveCollectionSpec {
  sourceKeys: string[];
  identityKeys: string[];
  allowedIdentities: string[];
  uniqueIdentities?: string[];
  durationIdentities?: string[];
  duration?: WindowDurationSpec;
}

export type UsageMetricKind = "balance" | "spend" | "limit" | "remaining";

export interface MetricMappingSpec {
  id: string;
  label: string;
  /** With aggregate, path segments ending in [] flat-map arrays
   * (data[].results[].amount.value collects every matching leaf). */
  sourceKey: string;
  conditions?: FieldConditionSpec[];
  kind: UsageMetricKind;
  unit?: string;
  /** Dot-path to a unit/currency string in the response; overrides `unit`
   * when it resolves (e.g. Claude extra_usage.currency). */
  unitKey?: string;
  /** Every listed path must resolve to a finite number before this candidate
   * mapping is eligible. Duplicate ids can then express correlated fallbacks
   * without pairing values from different response scopes. */
  requires?: string[];
  /** Non-numeric family members that must be present (for example currency
   * metadata paired with minor-unit amounts). */
  requiresPresent?: string[];
  /** Every path in each inner group must resolve to the same scalar value. */
  equalFields?: string[][];
  /** Parent/family paths whose presence makes this leaf contract required. */
  presencePaths?: string[];
  /** Every listed path must resolve to a finite number greater than zero. */
  requiresPositive?: string[];
  /** If any required member is present but the complete numeric family is
   * not, mark the response incomplete instead of silently omitting it. */
  incompleteWhenAnyRequiredPresent?: boolean;
  /** Ordered fallback candidates are ineligible when any canonical-family
   * member is present, even if that canonical member is malformed. */
  fallbackBlockedBy?: string[];
  secondary: boolean;
  /** "sum" adds every value the sourceKey resolves to (billing buckets). */
  aggregate?: "sum";
  /** Aggregate sibling units aligned with sourceKey leaves. */
  aggregateUnitKey?: string;
  aggregateExpectedUnit?: string;
  /** Multiplier applied after resolution (0.01 converts cents to dollars). */
  scale?: number;
  /** Dot-path to a non-negative minor-unit exponent. When valid, the mapper
   * divides by 10^exponent; `scale` remains the fallback for older payloads
   * that omit the metadata. */
  exponentKey?: string;
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
  /** No stable vendor contract or Vigil production capture: surfaced in UI
   * and docs so nobody mistakes research-derived mapping for live proof. */
  experimental?: boolean;
  auth: string;
  usage: UsageRequestSpec;
  oauth?: OAuthSpec;
  poll: PollSpec;
  discovery: DiscoverySpec;
  manualEntryHint?: string;
  responseFields?: ResponseFieldsSpec;
  responseEnvelope?: ResponseEnvelopeSpec;
  requiredOutputs?: RequiredOutputsSpec;
  recognizedEmpty?: RecognizedEmptySpec;
  exhaustiveCollections?: ExhaustiveCollectionSpec[];
  /** Successful HTTP bodies matching any condition are intentionally
   * incomplete. Used for pagination flags we cannot safely follow yet. */
  incompleteWhen?: FieldConditionSpec[];
  /** Every condition must match for a successful body to be complete. */
  requiredConditions?: FieldConditionSpec[];
  /** Paths whose keys must exist in a successful body. Explicit null is
   * allowed; absence means the provider contract changed. */
  requiredPaths?: string[];
  /** Paths that must be absent or explicit null in a complete response. */
  absentOrNullPaths?: string[];
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

export const SUPPORTED_REGISTRY_VERSION = 2;

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

export function parseRegistry(raw: string): Registry {
  const parsed = JSON.parse(raw) as Registry;
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    typeof parsed.version !== "number" ||
    parsed.providers === null ||
    typeof parsed.providers !== "object"
  ) {
    throw new Error("providers.json has an invalid registry shape");
  }
  if (parsed.version !== SUPPORTED_REGISTRY_VERSION) {
    throw new Error(
      `providers.json registry version ${parsed.version} is unsupported; expected ${SUPPORTED_REGISTRY_VERSION}`
    );
  }
  return parsed;
}

export function loadRegistry(): Registry {
  return parseRegistry(readFileSync(specPath(), "utf8"));
}

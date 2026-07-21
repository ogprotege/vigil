import type { ProviderId, ProviderSpec, QueryParamSpec } from "./spec/registry.js";
import type { Credentials, SnapshotStatus } from "./providers/types.js";
import { redactedMessage } from "./util/redact.js";

export interface FetchUsageResult {
  status: SnapshotStatus;
  httpStatus?: number;
  body?: unknown;
  error?: string;
}

export type FetchLike = typeof fetch;

export interface HttpOptions {
  fetchImpl?: FetchLike;
  /** Retries for transport-level failures only (never 4xx/5xx). */
  retries?: number;
  retryDelayMs?: number;
  /** Per-attempt timeout. Defaults to 15 seconds. */
  timeoutMs?: number;
  /**
   * Explicit dependency injection for local fixture servers. Overrides are
   * accepted only for loopback hosts, so ambient environment variables cannot
   * redirect credential-bearing requests.
   */
  fixtureBaseUrls?: Readonly<Record<ProviderId, string>>;
}

export const DEFAULT_TIMEOUT_MS = 15_000;

function isLoopbackHost(hostname: string): boolean {
  const normalized = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  return (
    normalized === "localhost" ||
    normalized === "::1" ||
    normalized === "0:0:0:0:0:0:0:1" ||
    /^127(?:\.\d{1,3}){3}$/.test(normalized)
  );
}

/** Resolves an explicitly injected, loopback-only fixture endpoint. */
export function resolveUrl(
  specUrl: string,
  providerId: ProviderId,
  fixtureBaseUrls: Readonly<Record<ProviderId, string>> = {}
): string {
  const override = fixtureBaseUrls[providerId];
  if (!override) return specUrl;
  const base = new URL(override);
  if (!["http:", "https:"].includes(base.protocol) || !isLoopbackHost(base.hostname)) {
    throw new Error(`fixture URL override for "${providerId}" must use a loopback HTTP(S) host`);
  }
  const original = new URL(specUrl);
  return new URL(original.pathname + original.search, base).toString();
}

/**
 * Applies {account_id} substitution and the registry's computed query
 * params to the spec URL. Returns null when the URL needs an account id the
 * credential does not carry — callers surface that as authExpired (the
 * credential cannot authenticate this request).
 */
export function buildRequestUrl(
  spec: ProviderSpec,
  creds: Credentials,
  now: Date = new Date()
): string | null {
  let url = spec.usage.url;
  if (url.includes("{account_id}")) {
    const accountId = creds.accountId?.trim();
    if (!accountId) return null;
    url = url.replace("{account_id}", encodeURIComponent(accountId));
  }
  if (spec.usage.query) {
    const withQuery = new URL(url);
    for (const [name, param] of Object.entries(spec.usage.query)) {
      withQuery.searchParams.set(name, resolveQueryParam(param, now));
    }
    url = withQuery.toString();
  }
  return url;
}

/** Billing periods are UTC on every provider that takes date params. */
export function resolveQueryParam(param: QueryParamSpec, now: Date): string {
  if ("value" in param) return param.value;
  switch (param.compute) {
    case "monthStartUnixSeconds":
      return String(Math.floor(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000));
    case "currentYear":
      return String(now.getUTCFullYear());
    case "currentMonth":
      return String(now.getUTCMonth() + 1);
  }
}

export function buildHeaders(spec: ProviderSpec, creds: Credentials): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const [name, template] of Object.entries(spec.usage.headers)) {
    const value = template
      .replace("{access_token}", creds.accessToken)
      .replace("{account_id}", creds.accountId ?? "");
    // Drop headers whose placeholder had no value (e.g. missing account id).
    if (value.trim() === "" || value.trim() === "Bearer") continue;
    headers[name] = value;
  }
  return headers;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export async function fetchWithTimeout(
  fetchImpl: FetchLike,
  input: string,
  init: RequestInit,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<Response> {
  const timeout = AbortSignal.timeout(Math.max(1, timeoutMs));
  return fetchImpl(input, { ...init, signal: timeout });
}

export async function fetchUsage(
  providerId: ProviderId,
  spec: ProviderSpec,
  creds: Credentials,
  opts: HttpOptions = {}
): Promise<FetchUsageResult> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const retries = opts.retries ?? 2;
  const retryDelayMs = opts.retryDelayMs ?? 500;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const templatedUrl = buildRequestUrl(spec, creds);
  if (templatedUrl === null) {
    return {
      status: "authExpired",
      error: "this provider needs an account id (re-link with one, or set its account-id environment variable)",
    };
  }
  let url: string;
  try {
    url = resolveUrl(templatedUrl, providerId, opts.fixtureBaseUrls);
  } catch (error) {
    return { status: "network", error: redactedMessage(error) };
  }
  const headers = buildHeaders(spec, creds);

  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    let response: Response;
    try {
      response = await fetchWithTimeout(
        fetchImpl,
        url,
        { method: spec.usage.method, headers },
        timeoutMs
      );
    } catch (err) {
      lastError = err;
      if (attempt < retries) await sleep(retryDelayMs * 2 ** attempt);
      continue;
    }

    if (response.status === 401 || response.status === 403) {
      return { status: "authExpired", httpStatus: response.status };
    }
    if (response.status === 429) {
      return { status: "rateLimited", httpStatus: response.status };
    }
    if (!response.ok) {
      return { status: "network", httpStatus: response.status };
    }
    // Read the body as text first, so a transport failure *while streaming*
    // stays a transport failure. `response.json()` collapses both cases into
    // one throw, and reporting a dropped socket or a fired timeout as
    // schemaChanged tells the user their provider changed its format and sends
    // them looking for a CLI update. It also skipped the retry loop that an
    // identical header-time failure would have used.
    let text: string;
    try {
      text = await response.text();
    } catch (err) {
      lastError = err;
      if (attempt < retries) await sleep(retryDelayMs * 2 ** attempt);
      continue;
    }
    try {
      const body: unknown = JSON.parse(text);
      return { status: "ok", httpStatus: response.status, body };
    } catch {
      // The body arrived complete and did not parse: a real shape change.
      return { status: "schemaChanged", httpStatus: response.status };
    }
  }

  return {
    status: "network",
    error: `network failure reaching ${url}: ${redactedMessage(lastError)}`,
  };
}

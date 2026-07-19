import type { ProviderId, ProviderSpec } from "./spec/registry.js";
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
  let url: string;
  try {
    url = resolveUrl(spec.usage.url, providerId, opts.fixtureBaseUrls);
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
    try {
      const body: unknown = await response.json();
      return { status: "ok", httpStatus: response.status, body };
    } catch {
      return { status: "schemaChanged", httpStatus: response.status };
    }
  }

  return {
    status: "network",
    error: `network failure reaching ${url}: ${redactedMessage(lastError)}`,
  };
}

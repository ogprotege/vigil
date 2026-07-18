import type { ProviderId, ProviderSpec } from "./spec/registry.js";
import type { Credentials, SnapshotStatus } from "./providers/types.js";
import { redactedMessage } from "./util/redact.js";

export interface FetchUsageResult {
  status: SnapshotStatus;
  httpStatus?: number;
  body?: unknown;
}

export type FetchLike = typeof fetch;

export interface HttpOptions {
  fetchImpl?: FetchLike;
  /** Retries for transport-level failures only (never 4xx/5xx). */
  retries?: number;
  retryDelayMs?: number;
  env?: Record<string, string | undefined>;
}

/**
 * Test-only base URL override: VIGIL_TEST=1 plus VIGIL_TEST_BASE_CLAUDE /
 * VIGIL_TEST_BASE_CODEX redirect requests at a local fixture server.
 */
export function resolveUrl(
  specUrl: string,
  providerId: ProviderId,
  env: Record<string, string | undefined> = process.env
): string {
  if (env["VIGIL_TEST"] !== "1") return specUrl;
  const override = env[`VIGIL_TEST_BASE_${providerId.toUpperCase()}`];
  if (!override) return specUrl;
  const original = new URL(specUrl);
  return new URL(original.pathname + original.search, override).toString();
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

export async function fetchUsage(
  providerId: ProviderId,
  spec: ProviderSpec,
  creds: Credentials,
  opts: HttpOptions = {}
): Promise<FetchUsageResult> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const retries = opts.retries ?? 2;
  const retryDelayMs = opts.retryDelayMs ?? 500;
  const url = resolveUrl(spec.usage.url, providerId, opts.env ?? process.env);
  const headers = buildHeaders(spec, creds);

  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    let response: Response;
    try {
      response = await fetchImpl(url, { method: spec.usage.method, headers });
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

  throw new Error(`network failure reaching ${url}: ${redactedMessage(lastError)}`);
}

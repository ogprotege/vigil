import type { ProviderId, ProviderSpec, Registry } from "./spec/registry.js";
import { fetchUsage, fetchWithTimeout, resolveUrl, type HttpOptions } from "./http.js";
import { recordPollResult, reservePoll, type PollGateOptions } from "./polling.js";
import { classifyResponseEnvelope, mapUsageResponse } from "./providers/map.js";

/** Enforces the provider's declared minimum useful output. Dynamic-window
 * incompleteness comes from the mapper because only it knows which filtered
 * entries were actually eligible. */
function mappingIsComplete(
  spec: ProviderSpec,
  mapped: ReturnType<typeof mapUsageResponse> & {}
): boolean {
  if (!mapped || mapped.incomplete) return false;
  const required = spec.requiredOutputs;
  const declaresWindows = spec.windows.length > 0 || spec.additionalWindows != null;
  const minimumWindows = mapped.recognizedEmpty
    ? 0
    : required?.minimumWindows ?? (declaresWindows ? 1 : 0);
  if (mapped.windows.length < minimumWindows) return false;
  if (
    !mapped.recognizedEmpty &&
    mapped.windows.filter((window) => !window.secondary).length <
    (required?.minimumPrimaryWindows ?? 0)
  ) return false;
  if ((required?.minimumMetrics ?? 0) > mapped.metrics.length) return false;
  const windowIds = new Set(mapped.windows.map((window) => window.id));
  if (!mapped.recognizedEmpty && required?.windowIds?.some((id) => !windowIds.has(id))) return false;
  const metricIds = new Set(mapped.metrics.map((metric) => metric.id));
  if (required?.metricIds?.some((id) => !metricIds.has(id))) return false;
  return true;
}
import type { Credentials, ProviderSnapshot } from "./providers/types.js";

export type UsageBodyClassification = Pick<
  ProviderSnapshot,
  "status" | "planLabel" | "windows" | "metrics"
>;

/** Classifies an already-decoded HTTP 2xx usage body. Keeping this as the
 * production path gives every provider a deterministic fixture-level test of
 * the complete envelope -> mapper -> required-output decision. */
export function classifyUsageBody(
  spec: ProviderSpec,
  body: unknown,
  fallbackPlan: string | null = null
): UsageBodyClassification {
  const envelopeStatus = classifyResponseEnvelope(spec, body);
  if (envelopeStatus) {
    return {
      status: envelopeStatus,
      planLabel: fallbackPlan,
      windows: [],
      metrics: [],
    };
  }
  const mapped = mapUsageResponse(spec, body);
  if (!mapped) {
    return {
      status: "schemaChanged",
      planLabel: fallbackPlan,
      windows: [],
      metrics: [],
    };
  }
  return {
    status: mappingIsComplete(spec, mapped) ? "ok" : "schemaChanged",
    planLabel: mapped.planLabel ?? fallbackPlan,
    windows: mapped.windows,
    metrics: mapped.metrics,
  };
}

export interface RefreshResult {
  credentials: Credentials;
}

/**
 * Refreshes a token pair minted specifically for Vigil. Deliberately refuses
 * to refresh copied file/keychain credentials because rotating another
 * client's refresh token would de-sync that client (ADR-0005).
 */
export async function refreshMintedCredentials(
  spec: ProviderSpec,
  creds: Credentials,
  opts: HttpOptions = {}
): Promise<Credentials | null> {
  if (creds.source !== "mint" || !creds.refreshToken || !spec.oauth) return null;
  const fetchImpl = opts.fetchImpl ?? fetch;
  const url = resolveUrl(spec.oauth.tokenUrl, creds.providerId, opts.fixtureBaseUrls);
  const response = await fetchWithTimeout(
    fetchImpl,
    url,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        grant_type: "refresh_token",
        refresh_token: creds.refreshToken,
        client_id: spec.oauth.clientId,
      }),
    },
    opts.timeoutMs
  );
  if (!response.ok) return null;
  let body: Record<string, unknown>;
  try {
    body = (await response.json()) as Record<string, unknown>;
  } catch {
    return null;
  }
  const accessToken = body["access_token"];
  if (typeof accessToken !== "string" || accessToken.length === 0) return null;
  const refreshToken = typeof body["refresh_token"] === "string" ? (body["refresh_token"] as string) : creds.refreshToken;
  const expiresValue = body["expires_in"];
  const expiresIn =
    typeof expiresValue === "number" &&
    Number.isFinite(expiresValue) &&
    expiresValue > 0
      ? expiresValue
      : undefined;
  return {
    ...creds,
    accessToken,
    refreshToken,
    expiresAt: expiresIn ? Math.floor(Date.now() / 1000) + expiresIn : creds.expiresAt,
  };
}

export interface SnapshotOptions extends HttpOptions {
  now?: () => Date;
  /**
   * When present, reserve and record a timestamp-only cross-process poll slot.
   * Library callers may omit this for fixture tests or their own scheduling.
   */
  poll?: PollGateOptions;
}

export interface PollSafetyWarning {
  reason: "busy" | "stateUnavailable";
  /** The conservative reservation that remains active after the failed write. */
  retryAt: string;
}

export interface SnapshotResult {
  snapshot: ProviderSnapshot;
  credentials: Credentials;
  pollSafetyWarning?: PollSafetyWarning;
}

/** Fetch + map + one refresh-and-retry on 401 for Vigil-minted credentials. */
export async function getSnapshot(
  registry: Registry,
  creds: Credentials,
  opts: SnapshotOptions = {}
): Promise<SnapshotResult> {
  const providerId: ProviderId = creds.providerId;
  const spec = registry.providers[providerId];
  const now = opts.now ?? (() => new Date());
  if (!spec) throw new Error(`provider "${providerId}" is missing from the registry`);

  const base: Omit<ProviderSnapshot, "status" | "windows" | "metrics" | "planLabel"> = {
    providerId,
    accountLabel: creds.label ?? null,
    fetchedAt: now().toISOString(),
  };

  let pollFallbackRetryAt: string | undefined;
  if (opts.poll) {
    const decision = await reservePoll(providerId, spec.poll, { ...opts.poll, now });
    if (!decision.allowed) {
      return {
        credentials: creds,
        snapshot: {
          ...base,
          status: "deferred",
          retryAt: decision.retryAt,
          deferredReason: decision.reason,
          ...(decision.statePath !== undefined ? { pollStatePath: decision.statePath } : {}),
          planLabel: creds.plan ?? null,
          windows: [],
          metrics: [],
        },
      };
    }
    pollFallbackRetryAt = decision.fallbackRetryAt;
  }

  let activeCreds = creds;
  let snapshot: ProviderSnapshot;
  try {
    let result = await fetchUsage(providerId, spec, activeCreds, opts);

    if (result.status === "authExpired" && activeCreds.source === "mint") {
      const refreshed = await refreshMintedCredentials(spec, activeCreds, opts).catch(() => null);
      if (refreshed) {
        activeCreds = refreshed;
        result = await fetchUsage(providerId, spec, activeCreds, opts);
      }
    }

    if (result.status !== "ok") {
      snapshot = {
        ...base,
        status: result.status,
        planLabel: activeCreds.plan ?? null,
        windows: [],
        metrics: [],
      };
    } else {
      snapshot = {
        ...base,
        ...classifyUsageBody(spec, result.body, activeCreds.plan ?? null),
      };
    }
  } catch {
    snapshot = {
      ...base,
      status: "network",
      planLabel: activeCreds.plan ?? null,
      windows: [],
      metrics: [],
    };
  }

  let pollSafetyWarning: PollSafetyWarning | undefined;
  if (opts.poll) {
    const outcome = await recordPollResult(providerId, spec.poll, snapshot.status, {
      ...opts.poll,
      now,
    });
    if (!outcome.recorded) {
      pollSafetyWarning = {
        reason: outcome.reason,
        // reservePoll always supplies this after an allowed decision.
        retryAt:
          pollFallbackRetryAt ??
          new Date(now().getTime() + Math.max(1, spec.poll.backoffMaxSeconds) * 1000).toISOString(),
      };
    }
  }
  return { credentials: activeCreds, snapshot, pollSafetyWarning };
}

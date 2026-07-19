import type { ProviderId, ProviderSpec, Registry } from "./spec/registry.js";
import { fetchUsage, fetchWithTimeout, resolveUrl, type HttpOptions } from "./http.js";
import { recordPollResult, reservePoll, type PollGateOptions } from "./polling.js";
import { mapUsageResponse } from "./providers/map.js";
import type { Credentials, ProviderSnapshot } from "./providers/types.js";

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
      const mapped = mapUsageResponse(spec, result.body);
      if (!mapped) {
        snapshot = {
          ...base,
          status: "schemaChanged",
          planLabel: activeCreds.plan ?? null,
          windows: [],
          metrics: [],
        };
      } else {
        snapshot = {
          ...base,
          status: "ok",
          planLabel: mapped.planLabel ?? activeCreds.plan ?? null,
          windows: mapped.windows,
          metrics: mapped.metrics,
        };
      }
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

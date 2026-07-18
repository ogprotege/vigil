import type { ProviderId, ProviderSpec, Registry } from "./spec/registry.js";
import { fetchUsage, resolveUrl, type HttpOptions } from "./http.js";
import { mapUsageResponse } from "./providers/map.js";
import type { Credentials, ProviderSnapshot } from "./providers/types.js";

export interface RefreshResult {
  credentials: Credentials;
}

/**
 * Refreshes a minted Claude token pair. Deliberately refuses to refresh
 * file/keychain credentials: rotating Claude Code's refresh token from
 * outside would de-sync the user's own install (ADR-0005).
 */
export async function refreshClaude(
  spec: ProviderSpec,
  creds: Credentials,
  opts: HttpOptions = {}
): Promise<Credentials | null> {
  if (creds.source !== "mint" || !creds.refreshToken || !spec.oauth) return null;
  const fetchImpl = opts.fetchImpl ?? fetch;
  const url = resolveUrl(spec.oauth.tokenUrl, creds.providerId, opts.env ?? process.env);
  const response = await fetchImpl(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: creds.refreshToken,
      client_id: spec.oauth.clientId,
    }),
  });
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
  const expiresIn = typeof body["expires_in"] === "number" ? (body["expires_in"] as number) : undefined;
  return {
    ...creds,
    accessToken,
    refreshToken,
    expiresAt: expiresIn ? Math.floor(Date.now() / 1000) + expiresIn : creds.expiresAt,
  };
}

export interface SnapshotOptions extends HttpOptions {
  now?: () => Date;
}

/** Fetch + map + (for minted Claude creds) one refresh-and-retry on 401. */
export async function getSnapshot(
  registry: Registry,
  creds: Credentials,
  opts: SnapshotOptions = {}
): Promise<{ snapshot: ProviderSnapshot; credentials: Credentials }> {
  const providerId: ProviderId = creds.providerId;
  const spec = registry.providers[providerId];
  const now = opts.now ?? (() => new Date());

  const base: Omit<ProviderSnapshot, "status" | "windows" | "planLabel"> = {
    providerId,
    accountLabel: creds.label ?? null,
    fetchedAt: now().toISOString(),
  };

  let activeCreds = creds;
  let result = await fetchUsage(providerId, spec, activeCreds, opts);

  if (result.status === "authExpired" && providerId === "claude") {
    const refreshed = await refreshClaude(spec, activeCreds, opts).catch(() => null);
    if (refreshed) {
      activeCreds = refreshed;
      result = await fetchUsage(providerId, spec, activeCreds, opts);
    }
  }

  if (result.status !== "ok") {
    return {
      credentials: activeCreds,
      snapshot: { ...base, status: result.status, planLabel: creds.plan ?? null, windows: [] },
    };
  }

  const mapped = mapUsageResponse(spec, result.body);
  if (!mapped) {
    return {
      credentials: activeCreds,
      snapshot: { ...base, status: "schemaChanged", planLabel: creds.plan ?? null, windows: [] },
    };
  }

  return {
    credentials: activeCreds,
    snapshot: {
      ...base,
      status: "ok",
      planLabel: mapped.planLabel ?? creds.plan ?? null,
      windows: mapped.windows,
    },
  };
}

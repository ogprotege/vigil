import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import { discoverProvider, type DiscoveryResult } from "../discovery/index.js";
import type { HttpOptions } from "../http.js";
import { getSnapshot } from "../service.js";
import type { Credentials, ProviderSnapshot, UsageWindow } from "../providers/types.js";
import type { PollGateOptions } from "../polling.js";
import { humanizeUntil } from "../util/time.js";
import { sanitizeTerminalText } from "../util/terminal.js";

const BAR_WIDTH = 20;

export function prettyWindowId(id: string): string {
  switch (id) {
    case "session":
      return "Session";
    case "weekly":
      return "Weekly";
    case "weekly_sonnet":
      return "Weekly (Sonnet)";
    case "weekly_opus":
      return "Weekly (Opus)";
    case "weekly_oauth_apps":
      return "Weekly (OAuth apps)";
    case "weekly_cowork":
      return "Weekly (Cowork)";
    case "session_video":
      return "Video session";
    case "weekly_video":
      return "Video weekly";
    default:
      return id;
  }
}

/** Display name for a window, preferring a provider-supplied label (model
 * name) for scoped windows over the raw id. */
export function prettyWindow(window: UsageWindow): string {
  if (window.label) {
    return window.id.startsWith("weekly_scoped") ? `Weekly (${window.label})` : window.label;
  }
  return prettyWindowId(window.id);
}

function bar(utilization: number): string {
  const safeUtilization = Number.isFinite(utilization)
    ? Math.min(100, Math.max(0, utilization))
    : 0;
  const filled = Math.round((safeUtilization / 100) * BAR_WIDTH);
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
}

function formatMetricValue(value: number, unit: string | null): string {
  const formatted = Number.isInteger(value)
    ? value.toString()
    : value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
  return unit ? `${formatted} ${sanitizeTerminalText(unit)}` : formatted;
}

const STATUS_LINES: Record<Exclude<ProviderSnapshot["status"], "ok" | "deferred">, string> = {
  authExpired: "credentials expired — re-run `vigil-link` (or open the provider's own CLI to refresh)",
  rateLimited: "provider is rate-limiting checks — this is normal, try again in a few minutes",
  schemaChanged: "provider changed their response format — check for a vigil-link update",
  network: "network problem reaching the provider",
};

export function renderSnapshot(snapshot: ProviderSnapshot, displayName: string, now: Date): string {
  const safeDisplayName = sanitizeTerminalText(displayName);
  const safePlanLabel = snapshot.planLabel
    ? sanitizeTerminalText(snapshot.planLabel)
    : null;
  const title = safePlanLabel ? `${safeDisplayName} (${safePlanLabel})` : safeDisplayName;
  const lines: string[] = [title];
  if (snapshot.status !== "ok") {
    const message =
      snapshot.status === "deferred"
        ? `live check deferred locally${
            snapshot.retryAt ? `. Next allowed in ${humanizeUntil(snapshot.retryAt, now)}` : ""
          }`
        : STATUS_LINES[snapshot.status];
    lines.push(`  ⚠ ${message}`);
    if (snapshot.status === "deferred" && snapshot.deferredReason === "corruptState" && snapshot.pollStatePath) {
      lines.push(
        `  ⚠ poll-state file is corrupt or unreadable: ${sanitizeTerminalText(snapshot.pollStatePath)}`
      );
      lines.push(
        "  recovery: delete that file to reset this provider's poll clock (vigil-link fails closed instead of guessing)"
      );
    }
    return lines.join("\n");
  }
  if (snapshot.windows.length === 0 && snapshot.metrics.length === 0) {
    lines.push("  no usage values reported");
    return lines.join("\n");
  }
  if (snapshot.windows.length > 0) {
    const windowNames = snapshot.windows.map((window) =>
      sanitizeTerminalText(prettyWindow(window))
    );
    const idWidth = Math.max(...windowNames.map((name) => name.length), 7);
    for (const [index, window] of snapshot.windows.entries()) {
      const name = windowNames[index]!.padEnd(idWidth + 2);
      const pct = `${Math.round(window.utilization)}%`.padStart(4);
      const reset = window.resetsAt ? `resets in ${humanizeUntil(window.resetsAt, now)}` : "";
      lines.push(`  ${name}${pct}  ${bar(window.utilization)}  ${reset}`.trimEnd());
    }
  }
  if (snapshot.metrics.length > 0) {
    const metricLabels = snapshot.metrics.map((metric) =>
      sanitizeTerminalText(metric.label)
    );
    const labelWidth = Math.max(...metricLabels.map((label) => label.length));
    for (const [index, metric] of snapshot.metrics.entries()) {
      lines.push(
        `  ${metricLabels[index]!.padEnd(labelWidth + 2)}${formatMetricValue(metric.value, metric.unit)}`
      );
    }
  }
  return lines.join("\n");
}

export interface StatusDeps {
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  now?: () => Date;
  /** false disables the CLI's timestamp-only cross-process poll gate. */
  poll?: PollGateOptions | false;
}

export interface MissingCredential {
  providerId: ProviderId;
  discovery: DiscoveryResult;
}

export async function collectCredentials(
  registry: Registry,
  providers: ProviderId[],
  discovery: DiscoveryOptions = {}
): Promise<{ found: Credentials[]; missing: MissingCredential[] }> {
  const found: Credentials[] = [];
  const missing: MissingCredential[] = [];
  const discoveries = await Promise.all(providers.map(async (providerId) => {
    const spec = registry.providers[providerId];
    if (!spec) {
      return {
        kind: "missing" as const,
        item: {
        providerId,
        discovery: {
          credentials: null,
          location: null,
          checkedLocations: [],
          unsupported: true,
        },
        },
      };
    }
    try {
      const result = await discoverProvider(providerId, spec, discovery);
      if (result.credentials) {
        return { kind: "found" as const, credentials: result.credentials };
      }
      return { kind: "missing" as const, item: { providerId, discovery: result } };
    } catch {
      return {
        kind: "missing" as const,
        item: {
          providerId,
          discovery: { credentials: null, location: null, checkedLocations: [] },
        },
      };
    }
  }));
  for (const discovery of discoveries) {
    if (discovery.kind === "found") found.push(discovery.credentials);
    else missing.push(discovery.item);
  }
  return { found, missing };
}

export async function statusReport(deps: StatusDeps, providers: ProviderId[]): Promise<string> {
  const now = deps.now ?? (() => new Date());
  const { found, missing } = await collectCredentials(deps.registry, providers, deps.discovery);
  const poll =
    deps.poll === false
      ? undefined
      : {
          homeDir: deps.discovery?.homeDir,
          env: deps.discovery?.env,
          ...deps.poll,
          now,
        };

  const sections = await Promise.all(
    found.map(async (creds) => {
      const { snapshot, pollSafetyWarning } = await getSnapshot(deps.registry, creds, {
        ...deps.http,
        now,
        poll,
      });
      const spec = deps.registry.providers[creds.providerId];
      // Experimental = community-proven but undocumented endpoint; the label
      // keeps that visible in every report.
      const displayName =
        (spec?.displayName ?? creds.providerId) + (spec?.experimental ? " (experimental)" : "");
      const rendered = renderSnapshot(snapshot, displayName, now());
      if (!pollSafetyWarning) return rendered;
      return (
        rendered +
        `\n  ⚠ poll safety result could not be saved (${pollSafetyWarning.reason}); ` +
        `conservative pause remains until ${pollSafetyWarning.retryAt}`
      );
    })
  );
  for (const item of missing) {
    const spec = deps.registry.providers[item.providerId];
    const displayName = sanitizeTerminalText(spec?.displayName ?? item.providerId);
    if (item.discovery.unsupported) {
      sections.push(
        `${displayName}\n  credential discovery is not configured for this provider`
      );
      continue;
    }
    sections.push(
      `${displayName}\n  no credentials found. Run \`vigil-link doctor\` to see checked sources`
    );
  }
  return sections.join("\n\n");
}

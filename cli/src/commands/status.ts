import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import { discoverClaude } from "../discovery/claude.js";
import { discoverCodex } from "../discovery/codex.js";
import type { HttpOptions } from "../http.js";
import { getSnapshot } from "../service.js";
import type { Credentials, ProviderSnapshot } from "../providers/types.js";
import { humanizeUntil } from "../util/time.js";

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
    default:
      return id;
  }
}

function bar(utilization: number): string {
  const filled = Math.round((utilization / 100) * BAR_WIDTH);
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
}

const STATUS_LINES: Record<Exclude<ProviderSnapshot["status"], "ok">, string> = {
  authExpired: "credentials expired — re-run `vigil-link` (or open the provider's own CLI to refresh)",
  rateLimited: "provider is rate-limiting checks — this is normal, try again in a few minutes",
  schemaChanged: "provider changed their response format — check for a vigil-link update",
  network: "network problem reaching the provider",
};

export function renderSnapshot(snapshot: ProviderSnapshot, displayName: string, now: Date): string {
  const title = snapshot.planLabel ? `${displayName} (${snapshot.planLabel})` : displayName;
  const lines: string[] = [title];
  if (snapshot.status !== "ok") {
    lines.push(`  ⚠ ${STATUS_LINES[snapshot.status]}`);
    return lines.join("\n");
  }
  const idWidth = Math.max(...snapshot.windows.map((w) => prettyWindowId(w.id).length), 7);
  for (const window of snapshot.windows) {
    const name = prettyWindowId(window.id).padEnd(idWidth + 2);
    const pct = `${Math.round(window.utilization)}%`.padStart(4);
    const reset = window.resetsAt ? `resets in ${humanizeUntil(window.resetsAt, now)}` : "";
    lines.push(`  ${name}${pct}  ${bar(window.utilization)}  ${reset}`.trimEnd());
  }
  return lines.join("\n");
}

export interface StatusDeps {
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  now?: () => Date;
}

export async function collectCredentials(
  registry: Registry,
  providers: ProviderId[],
  discovery: DiscoveryOptions = {}
): Promise<{ found: Credentials[]; missing: ProviderId[] }> {
  const found: Credentials[] = [];
  const missing: ProviderId[] = [];
  for (const providerId of providers) {
    const spec = registry.providers[providerId];
    const result =
      providerId === "claude"
        ? (await discoverClaude(spec, discovery)).credentials
        : (await discoverCodex(spec, discovery)).credentials;
    if (result) found.push(result);
    else missing.push(providerId);
  }
  return { found, missing };
}

export async function statusReport(deps: StatusDeps, providers: ProviderId[]): Promise<string> {
  const now = deps.now ?? (() => new Date());
  const { found, missing } = await collectCredentials(deps.registry, providers, deps.discovery);

  const sections: string[] = [];
  for (const creds of found) {
    const { snapshot } = await getSnapshot(deps.registry, creds, { ...deps.http, now });
    sections.push(renderSnapshot(snapshot, deps.registry.providers[creds.providerId].displayName, now()));
  }
  for (const providerId of missing) {
    sections.push(
      `${deps.registry.providers[providerId].displayName}\n  no credentials found — is the provider's CLI signed in on this machine? (\`vigil-link doctor\` shows where Vigil looks)`
    );
  }
  return sections.join("\n\n");
}

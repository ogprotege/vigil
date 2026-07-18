import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import { discoverClaude } from "../discovery/claude.js";
import { discoverCodex } from "../discovery/codex.js";
import type { HttpOptions } from "../http.js";
import { getSnapshot } from "../service.js";

export interface DoctorDeps {
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  now?: () => Date;
  live?: boolean;
}

function expiryLine(expiresAt: number | undefined, nowSeconds: number): string {
  if (!expiresAt) return "expiry unknown";
  const delta = expiresAt - nowSeconds;
  if (delta <= 0) return "access token EXPIRED (the provider's own CLI will refresh it on next use)";
  const minutes = Math.floor(delta / 60);
  return minutes >= 120 ? `access token valid ~${Math.floor(minutes / 60)}h` : `access token valid ~${minutes}m`;
}

export async function doctorReport(deps: DoctorDeps, providers: ProviderId[]): Promise<string> {
  const now = deps.now ?? (() => new Date());
  const nowSeconds = Math.floor(now().getTime() / 1000);
  const lines: string[] = [];

  for (const providerId of providers) {
    const spec = deps.registry.providers[providerId];
    lines.push(`${spec.displayName}`);

    if (providerId === "claude") {
      const result = await discoverClaude(spec, deps.discovery);
      if (result.credentials) {
        lines.push(`  ✓ credentials found (${result.location})`);
        lines.push(`  ${expiryLine(result.credentials.expiresAt, nowSeconds)}`);
        lines.push(`  refresh token: ${result.credentials.refreshToken ? "present" : "missing"}`);
        if (result.credentials.plan) lines.push(`  plan: ${result.credentials.plan}`);
      } else {
        lines.push(`  ✗ nothing at ${result.filePath} (or macOS Keychain) — is Claude Code signed in?`);
      }
      if (deps.live && result.credentials) {
        const { snapshot } = await getSnapshot(deps.registry, result.credentials, { ...deps.http, now });
        lines.push(`  live check: ${snapshot.status}`);
      }
    } else {
      const result = await discoverCodex(spec, deps.discovery);
      if (result.credentials) {
        lines.push(`  ✓ credentials found (file)`);
        lines.push(`  ${expiryLine(result.credentials.expiresAt, nowSeconds)}`);
        lines.push(`  account id: ${result.credentials.accountId ? "present" : "missing"}`);
        if (result.credentials.plan) lines.push(`  plan: ${result.credentials.plan}`);
      } else {
        lines.push(`  ✗ nothing at ${result.filePath} — is the Codex CLI signed in?`);
      }
      if (deps.live && result.credentials) {
        const { snapshot } = await getSnapshot(deps.registry, result.credentials, { ...deps.http, now });
        lines.push(`  live check: ${snapshot.status}`);
      }
    }
    lines.push("");
  }
  lines.push("vigil-link is stateless: it never writes credentials to disk (ADR-0004).");
  return lines.join("\n").trimEnd() + "\n";
}

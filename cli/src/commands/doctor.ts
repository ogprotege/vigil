import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import { discoverProvider } from "../discovery/index.js";
import type { HttpOptions } from "../http.js";
import { pollingStateDescription, type PollGateOptions } from "../polling.js";
import { getSnapshot } from "../service.js";
import { sanitizeTerminalText } from "../util/terminal.js";

export interface DoctorDeps {
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  now?: () => Date;
  live?: boolean;
  poll?: PollGateOptions | false;
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
  const poll =
    deps.poll === false
      ? undefined
      : {
          homeDir: deps.discovery?.homeDir,
          env: deps.discovery?.env,
          ...deps.poll,
          now,
        };

  const sections = await Promise.all(providers.map(async (providerId) => {
    const lines: string[] = [];
    const spec = deps.registry.providers[providerId];
    if (!spec) {
      lines.push(sanitizeTerminalText(providerId));
      lines.push("  ✗ provider is missing from the loaded registry");
      return lines;
    }
    lines.push(sanitizeTerminalText(spec.displayName));

    let result;
    try {
      result = await discoverProvider(providerId, spec, deps.discovery);
    } catch {
      lines.push("  ✗ credential discovery failed");
      return lines;
    }

    if (result.unsupported) {
      const adapter = spec.discovery.adapter ?? providerId;
      lines.push(`  ✗ no credential discovery adapter named "${sanitizeTerminalText(adapter)}"`);
    } else if (result.credentials) {
      lines.push(
        `  ✓ credentials found (${sanitizeTerminalText(result.location ?? "configured source")})`
      );
      lines.push(`  ${expiryLine(result.credentials.expiresAt, nowSeconds)}`);
      if (spec.oauth && result.credentials.refreshToken !== undefined) {
        lines.push(`  refresh token: ${result.credentials.refreshToken ? "present" : "missing"}`);
      }
      if (spec.usage.headers && Object.values(spec.usage.headers).some((value) => value.includes("{account_id}"))) {
        lines.push(`  account id: ${result.credentials.accountId ? "present" : "missing"}`);
      }
      if (result.credentials.plan) {
        lines.push(`  plan: ${sanitizeTerminalText(result.credentials.plan)}`);
      }
    } else {
      const checked =
        result.checkedLocations.length > 0
          ? result.checkedLocations.map((location) => sanitizeTerminalText(location)).join(" and ")
          : "configured sources";
      lines.push(`  ✗ nothing at ${checked}`);
    }
    if (deps.live && result.credentials) {
      const { snapshot, pollSafetyWarning } = await getSnapshot(deps.registry, result.credentials, {
        ...deps.http,
        now,
        poll,
      });
      const retry =
        snapshot.status === "deferred" && snapshot.retryAt ? ` (next allowed ${snapshot.retryAt})` : "";
      lines.push(`  live check: ${snapshot.status}${retry}`);
      if (pollSafetyWarning) {
        lines.push(
          `  ⚠ poll safety result could not be saved (${pollSafetyWarning.reason}); ` +
            `conservative pause remains until ${pollSafetyWarning.retryAt}`
        );
      }
    }
    return lines;
  }));
  const lines = sections.flatMap((section, index) =>
    index < sections.length - 1 ? [...section, ""] : section
  );
  lines.push("");
  const statePath = pollingStateDescription(poll ?? {
    homeDir: deps.discovery?.homeDir,
    env: deps.discovery?.env,
  });
  lines.push("vigil-link is credential-stateless: it never writes credentials or usage values to disk (ADR-0004).");
  lines.push(
    `Poll safety state: ${sanitizeTerminalText(statePath)} (timestamps and 429 counters only).`
  );
  return lines.join("\n").trimEnd() + "\n";
}

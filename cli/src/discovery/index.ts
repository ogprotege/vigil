import { discoverClaude } from "./claude.js";
import { discoverCodex } from "./codex.js";
import type { DiscoveryOptions } from "./paths.js";
import type { Credentials } from "../providers/types.js";
import type { ProviderId, ProviderSpec } from "../spec/registry.js";

export interface DiscoveryResult {
  credentials: Credentials | null;
  /** Human-readable source kind. Never contains a credential value. */
  location: string | null;
  /** Locations checked, suitable for diagnostic output. */
  checkedLocations: string[];
  unsupported?: boolean;
}

export type DiscoveryAdapter = (
  providerId: ProviderId,
  spec: ProviderSpec,
  options?: DiscoveryOptions
) => Promise<DiscoveryResult>;

const adapters = new Map<string, DiscoveryAdapter>();

export function registerDiscoveryAdapter(id: string, adapter: DiscoveryAdapter): void {
  adapters.set(id, adapter);
}

registerDiscoveryAdapter("claude", async (_providerId, spec, options) => {
  const result = await discoverClaude(spec, options);
  return {
    credentials: result.credentials,
    location: result.location,
    checkedLocations: [
      result.filePath,
      ...(spec.discovery.macosKeychain?.service
        ? [`macOS Keychain service ${spec.discovery.macosKeychain.service}`]
        : []),
    ],
  };
});

registerDiscoveryAdapter("codex", async (_providerId, spec, options) => {
  const result = await discoverCodex(spec, options);
  return {
    credentials: result.credentials,
    location: result.credentials ? "file" : null,
    checkedLocations: [result.filePath],
  };
});

registerDiscoveryAdapter("environment", async (providerId, spec, options) => {
  const environment = spec.discovery.environment;
  if (!environment?.accessToken) {
    return {
      credentials: null,
      location: null,
      checkedLocations: [],
      unsupported: true,
    };
  }

  const env = options?.env ?? process.env;
  const accessToken = env[environment.accessToken]?.trim();
  const checkedLocations = [`environment variable ${environment.accessToken}`];
  if (!accessToken) return { credentials: null, location: null, checkedLocations };

  const accountId = environment.accountId ? env[environment.accountId]?.trim() : undefined;
  const configuredLabel = environment.label ? env[environment.label]?.trim() : undefined;
  return {
    credentials: {
      providerId,
      accessToken,
      accountId: accountId || undefined,
      label: configuredLabel || spec.displayName,
      source: "environment",
    },
    location: `environment variable ${environment.accessToken}`,
    checkedLocations,
  };
});

export async function discoverProvider(
  providerId: ProviderId,
  spec: ProviderSpec,
  options: DiscoveryOptions = {}
): Promise<DiscoveryResult> {
  const adapterId = spec.discovery.adapter ?? providerId;
  const adapter = adapters.get(adapterId);
  if (!adapter) {
    return {
      credentials: null,
      location: null,
      checkedLocations: [],
      unsupported: true,
    };
  }
  return adapter(providerId, spec, options);
}

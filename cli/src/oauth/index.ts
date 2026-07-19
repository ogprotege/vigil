import { mintClaude, type MintOptions } from "./claudeMint.js";
import type { Credentials } from "../providers/types.js";
import type { ProviderId, ProviderSpec } from "../spec/registry.js";

export type MintAdapter = (
  providerId: ProviderId,
  spec: ProviderSpec,
  options?: MintOptions
) => Promise<Credentials>;

const adapters = new Map<string, MintAdapter>();

export function registerMintAdapter(id: string, adapter: MintAdapter): void {
  adapters.set(id, adapter);
}

registerMintAdapter("claude", async (_providerId, spec, options) => {
  if (!spec.oauth) throw new Error("OAuth configuration is missing");
  return mintClaude(spec.oauth, options);
});

export function hasMintAdapter(providerId: ProviderId, spec: ProviderSpec): boolean {
  return adapters.has(spec.discovery.adapter ?? providerId);
}

export async function mintProvider(
  providerId: ProviderId,
  spec: ProviderSpec,
  options?: MintOptions
): Promise<Credentials> {
  const adapterId = spec.discovery.adapter ?? providerId;
  const adapter = adapters.get(adapterId);
  if (!adapter) throw new Error(`no mint adapter named "${adapterId}"`);
  return adapter(providerId, spec, options);
}

import type { ProviderId } from "../spec/registry.js";

export interface UsageWindow {
  id: string;
  utilization: number;
  resetsAt: string | null;
  windowSeconds: number | null;
  secondary: boolean;
}

export type SnapshotStatus = "ok" | "authExpired" | "rateLimited" | "schemaChanged" | "network";

export interface ProviderSnapshot {
  providerId: ProviderId;
  accountLabel: string | null;
  planLabel: string | null;
  fetchedAt: string;
  status: SnapshotStatus;
  windows: UsageWindow[];
}

export interface Credentials {
  providerId: ProviderId;
  accessToken: string;
  refreshToken?: string;
  /** Unix seconds. */
  expiresAt?: number;
  accountId?: string;
  label?: string;
  plan?: string;
  source: "file" | "keychain" | "mint";
}

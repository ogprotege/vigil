import type { ProviderId, UsageMetricKind } from "../spec/registry.js";

export interface UsageWindow {
  id: string;
  utilization: number;
  resetsAt: string | null;
  windowSeconds: number | null;
  secondary: boolean;
}

export interface UsageMetric {
  id: string;
  label: string;
  kind: UsageMetricKind;
  value: number;
  unit: string | null;
  secondary: boolean;
}

export type SnapshotStatus =
  | "ok"
  | "authExpired"
  | "rateLimited"
  | "schemaChanged"
  | "network"
  | "deferred";

export interface ProviderSnapshot {
  providerId: ProviderId;
  accountLabel: string | null;
  planLabel: string | null;
  fetchedAt: string;
  status: SnapshotStatus;
  /** Present when a local poll gate deferred the live request. */
  retryAt?: string;
  windows: UsageWindow[];
  metrics: UsageMetric[];
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
  source: "file" | "keychain" | "environment" | "mint";
}

import type { ProviderId, UsageMetricKind } from "../spec/registry.js";
import type { PollDeferReason } from "../polling.js";

export interface UsageWindow {
  id: string;
  /** Human display name for a provider-scoped window (e.g. a model name),
   * present only when the response carries one; null for static windows whose
   * name is derived from the id at the UI layer. */
  label: string | null;
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
  /** Present when status is "deferred": why the local gate refused the request. */
  deferredReason?: PollDeferReason;
  /** Present when deferredReason is "corruptState": the malformed or unreadable poll-state file. */
  pollStatePath?: string;
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
  source: "file" | "keychain" | "environment" | "mint" | "manual";
}

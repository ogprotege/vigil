import type { ProviderSpec, UsageMetricKind, WindowSpec } from "../spec/registry.js";
import type { UsageMetric, UsageWindow } from "./types.js";

export interface MappedUsage {
  planLabel: string | null;
  windows: UsageWindow[];
  metrics: UsageMetric[];
}

function getPath(obj: unknown, dotPath: string): unknown {
  let cur: unknown = obj;
  for (const key of dotPath.split(".")) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

/** Normalizes to second-precision ISO-8601 with a trailing Z. */
function toIso(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function parseReset(value: unknown, format: WindowSpec["resetFormat"]): string | null | undefined {
  if (value === null || value === undefined) return null;
  if (format === "iso8601") {
    if (typeof value !== "string") return undefined;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return undefined;
    return toIso(date);
  }
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  const date = new Date(value * 1000);
  if (Number.isNaN(date.getTime())) return undefined;
  return toIso(date);
}

function readBucket(
  spec: ProviderSpec,
  bucket: Record<string, unknown>,
  windowSpec: Pick<WindowSpec, "id" | "resetFormat" | "windowSeconds" | "secondary">
): UsageWindow | null {
  if (!spec.responseFields) return null;
  // Some providers nest the numbers one level down (e.g. Codex
  // additional_rate_limits entries have been seen both flat and nested).
  const nested = bucket["rate_limit"];
  const source =
    getPath(bucket, spec.responseFields.utilization) === undefined &&
    nested !== null &&
    typeof nested === "object"
      ? (nested as Record<string, unknown>)
      : bucket;

  const utilization = getPath(source, spec.responseFields.utilization);
  if (typeof utilization !== "number" || !Number.isFinite(utilization)) return null;

  const reset = parseReset(getPath(source, spec.responseFields.resetsAt), windowSpec.resetFormat);
  if (reset === undefined) return null;

  let windowSeconds: number | null = windowSpec.windowSeconds ?? null;
  if (spec.responseFields.windowSeconds) {
    const fromResponse = getPath(source, spec.responseFields.windowSeconds);
    if (
      typeof fromResponse === "number" &&
      Number.isSafeInteger(fromResponse) &&
      fromResponse > 0
    ) {
      windowSeconds = fromResponse;
    }
  }

  return {
    id: windowSpec.id,
    utilization: Math.min(100, Math.max(0, utilization)),
    resetsAt: reset,
    windowSeconds,
    secondary: windowSpec.secondary,
  };
}

function metricNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizedMetricId(raw: string, kind: UsageMetricKind): string {
  const suffix = raw.toLowerCase().replace(/[^a-z0-9]/g, "_");
  return `${kind}_${suffix}`;
}

function boundedProviderText(raw: unknown, maximumLength: number): string | null {
  if (
    typeof raw !== "string" ||
    raw.length === 0 ||
    raw.length > maximumLength ||
    /[\u0000-\u001F\u007F-\u009F]/.test(raw)
  ) {
    return null;
  }
  return raw;
}

/**
 * Maps a raw usage response through the provider's window spec.
 * Returns null when nothing maps at all — the schemaChanged signal.
 * Null/missing buckets are skipped silently (e.g. no Opus quota on this plan).
 */
export function mapUsageResponse(spec: ProviderSpec, body: unknown): MappedUsage | null {
  if (body === null || typeof body !== "object") return null;

  const windows: UsageWindow[] = [];
  const windowIds = new Set<string>();
  for (const windowSpec of spec.windows) {
    const bucket = getPath(body, windowSpec.sourceKey);
    if (bucket === null || bucket === undefined || typeof bucket !== "object") continue;
    const mapped = readBucket(spec, bucket as Record<string, unknown>, windowSpec);
    if (mapped && !windowIds.has(mapped.id)) {
      windowIds.add(mapped.id);
      windows.push(mapped);
    }
  }

  if (spec.additionalWindows) {
    const extra = getPath(body, spec.additionalWindows.sourceKey);
    if (Array.isArray(extra)) {
      for (const entry of extra.slice(0, 128)) {
        if (entry === null || typeof entry !== "object") continue;
        const record = entry as Record<string, unknown>;
        const id = boundedProviderText(record[spec.additionalWindows.idKey], 128);
        if (!id) continue;
        const mapped = readBucket(spec, record, {
          id,
          resetFormat: "unixSeconds",
          secondary: spec.additionalWindows.secondary,
        });
        if (mapped && !windowIds.has(mapped.id)) {
          windowIds.add(mapped.id);
          windows.push(mapped);
        }
      }
    }
  }

  const metrics: UsageMetric[] = [];
  const metricIds = new Set<string>();
  for (const mapping of spec.metricMappings ?? []) {
    const value = metricNumber(getPath(body, mapping.sourceKey));
    if (value === null) continue;
    const metric = {
      id: mapping.id,
      label: mapping.label,
      kind: mapping.kind,
      value,
      unit: mapping.unit ?? null,
      secondary: mapping.secondary,
    };
    if (!metricIds.has(metric.id)) {
      metricIds.add(metric.id);
      metrics.push(metric);
    }
  }

  for (const collection of spec.metricCollectionMappings ?? []) {
    const entries = getPath(body, collection.sourceKey);
    if (!Array.isArray(entries)) continue;
    for (const entry of entries.slice(0, 128)) {
      if (entry === null || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const rawId = boundedProviderText(getPath(record, collection.idKey), 128);
      const value = metricNumber(getPath(record, collection.valueKey));
      if (!rawId || value === null) continue;
      const rawUnit = collection.unitKey ? getPath(record, collection.unitKey) : undefined;
      const unit = boundedProviderText(rawUnit, 32);
      const metric = {
        id: normalizedMetricId(rawId, collection.kind),
        label: `${collection.label} (${unit ?? rawId})`,
        kind: collection.kind,
        value,
        unit,
        secondary: collection.secondary,
      };
      if (!metricIds.has(metric.id)) {
        metricIds.add(metric.id);
        metrics.push(metric);
      }
    }
  }

  if (windows.length === 0 && metrics.length === 0) return null;

  let planLabel: string | null = null;
  if (spec.planKey) {
    planLabel = boundedProviderText(getPath(body, spec.planKey), 128);
  }

  return { planLabel, windows, metrics };
}

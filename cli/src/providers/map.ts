import type { ProviderSpec, WindowSpec } from "../spec/registry.js";
import type { UsageWindow } from "./types.js";

export interface MappedUsage {
  planLabel: string | null;
  windows: UsageWindow[];
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
  return toIso(new Date(value * 1000));
}

function readBucket(
  spec: ProviderSpec,
  bucket: Record<string, unknown>,
  windowSpec: Pick<WindowSpec, "id" | "resetFormat" | "windowSeconds" | "secondary">
): UsageWindow | null {
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
    if (typeof fromResponse === "number" && Number.isFinite(fromResponse)) {
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

/**
 * Maps a raw usage response through the provider's window spec.
 * Returns null when nothing maps at all — the schemaChanged signal.
 * Null/missing buckets are skipped silently (e.g. no Opus quota on this plan).
 */
export function mapUsageResponse(spec: ProviderSpec, body: unknown): MappedUsage | null {
  if (body === null || typeof body !== "object") return null;

  const windows: UsageWindow[] = [];
  for (const windowSpec of spec.windows) {
    const bucket = getPath(body, windowSpec.sourceKey);
    if (bucket === null || bucket === undefined || typeof bucket !== "object") continue;
    const mapped = readBucket(spec, bucket as Record<string, unknown>, windowSpec);
    if (mapped) windows.push(mapped);
  }

  if (spec.additionalWindows) {
    const extra = getPath(body, spec.additionalWindows.sourceKey);
    if (Array.isArray(extra)) {
      for (const entry of extra) {
        if (entry === null || typeof entry !== "object") continue;
        const record = entry as Record<string, unknown>;
        const id = record[spec.additionalWindows.idKey];
        if (typeof id !== "string" || id.length === 0) continue;
        const mapped = readBucket(spec, record, {
          id,
          resetFormat: "unixSeconds",
          secondary: spec.additionalWindows.secondary,
        });
        if (mapped) windows.push(mapped);
      }
    }
  }

  if (windows.length === 0) return null;

  let planLabel: string | null = null;
  if (spec.planKey) {
    const plan = getPath(body, spec.planKey);
    if (typeof plan === "string" && plan.length > 0) planLabel = plan;
  }

  return { planLabel, windows };
}

import type { ProviderSpec, UsageMetricKind, WindowSpec } from "../spec/registry.js";
import type { UsageMetric, UsageWindow } from "./types.js";

export interface MappedUsage {
  planLabel: string | null;
  windows: UsageWindow[];
  metrics: UsageMetric[];
}

/**
 * Dot-path lookup with one extension: a segment may end in a selector,
 * `items[kind=general]`, which resolves `items` to an array and picks the
 * first element whose `kind` property string-equals "general".
 */
function getPath(obj: unknown, dotPath: string): unknown {
  let cur: unknown = obj;
  for (const segment of dotPath.split(".")) {
    if (cur === null || typeof cur !== "object") return undefined;
    const selector = /^([^[\]]+)\[([^=\]]+)=([^\]]*)\]$/.exec(segment);
    if (selector) {
      const key = selector[1] as string;
      const matchKey = selector[2] as string;
      const matchValue = selector[3] as string;
      const array = (cur as Record<string, unknown>)[key];
      if (!Array.isArray(array)) return undefined;
      cur = array
        .slice(0, 128)
        .find(
          (entry) =>
            entry !== null &&
            typeof entry === "object" &&
            (entry as Record<string, unknown>)[matchKey] === matchValue
        );
    } else {
      cur = (cur as Record<string, unknown>)[segment];
    }
  }
  return cur;
}

/**
 * Aggregate-path lookup: segments ending in `[]` flat-map arrays, so
 * `data[].results[].amount.value` collects every matching leaf. Bounded at
 * 128 elements per array level like every other provider-controlled fan-out.
 */
function collectPath(obj: unknown, dotPath: string): unknown[] {
  let frontier: unknown[] = [obj];
  for (const rawSegment of dotPath.split(".")) {
    const segment = rawSegment as string;
    const next: unknown[] = [];
    const isFlatMap = segment.endsWith("[]");
    const key = isFlatMap ? segment.slice(0, -2) : segment;
    for (const node of frontier) {
      if (node === null || typeof node !== "object") continue;
      const value = (node as Record<string, unknown>)[key];
      if (isFlatMap) {
        if (Array.isArray(value)) next.push(...value.slice(0, 128));
      } else {
        next.push(value);
      }
    }
    frontier = next;
    if (frontier.length === 0) return [];
  }
  return frontier;
}

/** Normalizes to second-precision ISO-8601 with a trailing Z. */
function toIso(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function parseReset(
  value: unknown,
  format: WindowSpec["resetFormat"],
  lenient: boolean
): string | null | undefined {
  if (value === null || value === undefined) return null;
  if (format === "iso8601") {
    if (typeof value !== "string") return undefined;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return undefined;
    return toIso(date);
  }
  const numeric = windowNumber(value, lenient);
  if (numeric === null) return undefined;
  const millis = format === "unixMillis" ? numeric : numeric * 1000;
  const date = new Date(millis);
  if (Number.isNaN(date.getTime())) return undefined;
  return toIso(date);
}

/** Window numbers are strict by default; allowStringNumbers opts a provider
 * into string-encoded numerics ("46.5") without loosening everyone else. */
function windowNumber(value: unknown, lenient: boolean): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (!lenient) return null;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function readBucket(
  spec: ProviderSpec,
  bucket: Record<string, unknown>,
  windowSpec: Pick<WindowSpec, "id" | "resetFormat" | "windowSeconds" | "secondary" | "fields"> & {
    label?: string | null;
  }
): UsageWindow | null {
  if (!spec.responseFields) return null;
  const utilizationKey = windowSpec.fields?.utilization ?? spec.responseFields.utilization;
  const resetsAtKey = windowSpec.fields?.resetsAt ?? spec.responseFields.resetsAt;
  const lenient = spec.responseFields.allowStringNumbers === true;

  // Some providers nest the numbers one level down (e.g. Codex
  // additional_rate_limits entries have been seen both flat and nested).
  const nested = bucket["rate_limit"];
  const source =
    getPath(bucket, utilizationKey) === undefined && nested !== null && typeof nested === "object"
      ? (nested as Record<string, unknown>)
      : bucket;

  const rawUtilization = windowNumber(getPath(source, utilizationKey), lenient);
  if (rawUtilization === null) return null;
  const utilization =
    spec.responseFields.utilizationKind === "remaining" ? 100 - rawUtilization : rawUtilization;

  const reset = parseReset(getPath(source, resetsAtKey), windowSpec.resetFormat, lenient);
  if (reset === undefined) return null;

  let windowSeconds: number | null = windowSpec.windowSeconds ?? null;
  if (spec.responseFields.windowSeconds) {
    const fromResponse = windowNumber(
      getPath(source, spec.responseFields.windowSeconds),
      lenient
    );
    if (fromResponse !== null && Number.isSafeInteger(fromResponse) && fromResponse > 0) {
      windowSeconds = fromResponse;
    }
  }

  return {
    id: windowSpec.id,
    label: windowSpec.label ?? null,
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

function normalizedIdSuffix(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9]/g, "_");
}

function normalizedMetricId(raw: string, kind: UsageMetricKind): string {
  return `${kind}_${normalizedIdSuffix(raw)}`;
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
    const aw = spec.additionalWindows;
    const extra = getPath(body, aw.sourceKey);
    if (Array.isArray(extra)) {
      for (const entry of extra.slice(0, 128)) {
        if (entry === null || typeof entry !== "object") continue;
        const record = entry as Record<string, unknown>;
        // Optional per-entry filter (e.g. keep only kind === "weekly_scoped").
        if (aw.filter && getPath(record, aw.filter.key) !== aw.filter.equals) continue;
        const rawId = boundedProviderText(getPath(record, aw.idKey), 128);
        if (!rawId) continue;
        // A prefix means synthesize a stable normalized id (weekly_scoped_fable);
        // without one, the raw id stands (Codex lane names like gpt-5-codex-spark).
        const id = aw.idPrefix ? `${aw.idPrefix}_${normalizedIdSuffix(rawId)}` : rawId;
        const label = aw.labelKey ? boundedProviderText(getPath(record, aw.labelKey), 64) : null;
        const mapped = readBucket(spec, record, {
          id,
          resetFormat: aw.resetFormat ?? "unixSeconds",
          secondary: aw.secondary,
          label,
          ...(aw.windowSeconds !== undefined ? { windowSeconds: aw.windowSeconds } : {}),
          ...(aw.fields ? { fields: aw.fields } : {}),
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
    let value: number | null;
    if (mapping.aggregate === "sum") {
      // A zero-spend month legitimately sums to 0 (root array present but
      // empty); a missing root key, or leaves that all fail to parse, means
      // the shape changed. The distinction keeps fresh accounts showing
      // $0.00 instead of schemaChanged.
      const firstSegment = mapping.sourceKey.split(".")[0] ?? "";
      const firstKey = firstSegment.endsWith("[]") ? firstSegment.slice(0, -2) : firstSegment;
      const root = (body as Record<string, unknown>)[firstKey];
      if (root === undefined || root === null) {
        value = null;
      } else {
        const leaves = collectPath(body, mapping.sourceKey);
        const numbers = leaves
          .map((leaf) => metricNumber(leaf))
          .filter((n): n is number => n !== null);
        value =
          leaves.length > 0 && numbers.length === 0
            ? null
            : numbers.reduce((a, b) => a + b, 0);
      }
    } else {
      value = metricNumber(getPath(body, mapping.sourceKey));
    }
    if (value === null) continue;
    if (typeof mapping.scale === "number" && Number.isFinite(mapping.scale)) {
      value *= mapping.scale;
    }
    if (!Number.isFinite(value)) continue;
    // A unitKey (e.g. extra_usage.currency) overrides the static unit when it
    // resolves to a usable string; otherwise the static unit stands.
    let unit: string | null = mapping.unit ?? null;
    if (mapping.unitKey) {
      const resolved = boundedProviderText(getPath(body, mapping.unitKey), 32);
      if (resolved) unit = resolved;
    }
    const metric = {
      id: mapping.id,
      label: mapping.label,
      kind: mapping.kind,
      value,
      unit,
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

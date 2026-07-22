import type {
  FieldConditionSpec,
  ProviderSpec,
  UsageMetricKind,
  WindowSpec,
} from "../spec/registry.js";
import type { UsageMetric, UsageWindow } from "./types.js";

export interface MappedUsage {
  planLabel: string | null;
  windows: UsageWindow[];
  metrics: UsageMetric[];
  /** A configured dynamic entry existed but none of its quota buckets mapped. */
  incomplete: boolean;
  /** The provider explicitly reported a legitimate no-finite-quota state. */
  recognizedEmpty: boolean;
}

/**
 * Dot-path lookup with one extension: a segment may end in a selector,
 * `items[kind=general]`, which resolves `items` to an array and picks the
 * first element whose `kind` property string-equals "general".
 */
const INVALID_PATH = Symbol("invalid-provider-path");

function getPath(obj: unknown, dotPath: string): unknown {
  if (dotPath === "$") return obj;
  if (dotPath.startsWith("$.")) dotPath = dotPath.slice(2);
  let cur: unknown = obj;
  for (const segment of dotPath.split(".")) {
    if (cur === INVALID_PATH) return cur;
    if (cur === null || typeof cur !== "object") return undefined;
    const selector = /^([^[\]]+)\[([^=\]]+)=([^\]]*)\]$/.exec(segment);
    if (selector) {
      const key = selector[1] as string;
      const matchKey = selector[2] as string;
      const matchValue = selector[3] as string;
      const array = (cur as Record<string, unknown>)[key];
      if (!Array.isArray(array)) return undefined;
      if (array.length > 128) return INVALID_PATH;
      if (array.some((entry) => entry === null || typeof entry !== "object" || Array.isArray(entry))) {
        return INVALID_PATH;
      }
      const matches = array.filter(
        (entry) => (entry as Record<string, unknown>)[matchKey] === matchValue
      );
      if (matches.length > 1) return INVALID_PATH;
      cur = matches[0];
    } else {
      cur = (cur as Record<string, unknown>)[segment];
    }
  }
  return cur;
}

function scalarString(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return null;
}

function conditionScalar(value: unknown, condition: FieldConditionSpec): string | null {
  if (condition.valueType === "boolean" && typeof value !== "boolean") return null;
  if (condition.valueType === "number") {
    if (typeof value !== "number" || !Number.isSafeInteger(value)) return null;
    return String(Object.is(value, -0) ? 0 : value);
  }
  if (condition.valueType === "string" && typeof value !== "string") return null;
  return scalarString(value);
}

function matchesConditions(record: Record<string, unknown>, conditions: FieldConditionSpec[]): boolean {
  return conditions.every(
    (condition) => conditionScalar(getPath(record, condition.key), condition) === condition.equals
  );
}

function conditionContractInvalid(
  record: Record<string, unknown>,
  conditions: FieldConditionSpec[] | undefined
): boolean {
  return (conditions ?? []).some((condition) => {
    if (!condition.allowedNonMatches?.length) return false;
    const value = conditionScalar(getPath(record, condition.key), condition);
    return value === null ||
      (value !== condition.equals && !condition.allowedNonMatches.includes(value));
  });
}

function isPresent(value: unknown): boolean {
  return value !== undefined && value !== null;
}

function hasLoneSurrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

/** JSON.parse accepts non-finite exponents and lone UTF-16 surrogates that
 * Foundation rejects. Validate the decoded tree before either mapper sees it. */
function isValidDecodedJSON(root: unknown): boolean {
  let nodes = 0;
  const active = new Set<object>();
  const visit = (value: unknown, depth: number): boolean => {
    nodes += 1;
    if (nodes > 10_000 || depth > 64) return false;
    if (value === null || typeof value === "boolean") return true;
    if (typeof value === "number") return Number.isFinite(value);
    if (typeof value === "string") return !hasLoneSurrogate(value);
    if (typeof value !== "object") return false;
    if (active.has(value)) return false;
    active.add(value);
    const valid = Array.isArray(value)
      ? value.every((entry) => visit(entry, depth + 1))
      : Object.entries(value as Record<string, unknown>).every(
          ([key, entry]) => !hasLoneSurrogate(key) && visit(entry, depth + 1)
        );
    active.delete(value);
    return valid;
  };
  return visit(root, 0);
}

function responseIsRecognizedEmpty(spec: ProviderSpec, body: unknown): boolean {
  const rule = spec.recognizedEmpty;
  if (!rule || rule.allEntriesMatch.length === 0) return false;
  for (const path of rule.sourceKeys) {
    const value = getPath(body, path);
    if (!Array.isArray(value) || value.length === 0) continue;
    // Mapping fan-out is capped at 128 everywhere. Never declare a larger
    // response healthy after inspecting only a prefix of it.
    if (value.length > 128) return false;
    return value.every(
      (entry) =>
        entry !== null &&
        typeof entry === "object" &&
        !Array.isArray(entry) &&
        matchesConditions(entry as Record<string, unknown>, rule.allEntriesMatch)
    );
  }
  return false;
}

function windowDurationSeconds(
  record: Record<string, unknown>,
  duration: NonNullable<WindowSpec["duration"]>
): number | null {
  const unit = scalarString(getPath(record, duration.unitKey));
  const count = metricNumber(getPath(record, duration.numberKey));
  if (unit === null || count === null || !Number.isSafeInteger(count) || count <= 0) return null;
  const secondsPerUnit = duration.unitSeconds[unit];
  if (
    typeof secondsPerUnit !== "number" ||
    !Number.isSafeInteger(secondsPerUnit) ||
    secondsPerUnit <= 0
  ) return null;
  const seconds = count * secondsPerUnit;
  return Number.isSafeInteger(seconds) && seconds > 0 ? seconds : null;
}

function matchesDuration(
  record: Record<string, unknown>,
  duration: WindowSpec["duration"] | undefined
): boolean {
  if (!duration) return true;
  const seconds = windowDurationSeconds(record, duration);
  if (seconds === null) return false;
  if (duration.allowedSeconds?.length && !duration.allowedSeconds.includes(seconds)) return false;
  if (duration.minimumSeconds !== undefined && seconds < duration.minimumSeconds) return false;
  if (
    duration.maximumSecondsExclusive !== undefined &&
    seconds >= duration.maximumSecondsExclusive
  ) return false;
  return true;
}

function exhaustiveCollectionsAreValid(spec: ProviderSpec, body: unknown): boolean {
  for (const contract of spec.exhaustiveCollections ?? []) {
    const present = contract.sourceKeys
      .map((path) => getPath(body, path))
      .filter(isPresent);
    if (present.length === 0) continue;
    if (present.length !== 1 || !Array.isArray(present[0])) return false;
    const entries = present[0];
    if (entries.length > 128) return false;
    const counts = new Map<string, number>();
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return false;
      const record = entry as Record<string, unknown>;
      const identities = contract.identityKeys
        .map((key) => getPath(record, key))
        .filter(isPresent);
      if (
        identities.length === 0 ||
        identities.some((identity) => typeof identity !== "string") ||
        new Set(identities).size !== 1
      ) return false;
      const identity = identities[0] as string;
      if (!contract.allowedIdentities.includes(identity)) return false;
      counts.set(identity, (counts.get(identity) ?? 0) + 1);
      if (
        contract.duration &&
        contract.durationIdentities?.includes(identity) &&
        !matchesDuration(record, contract.duration)
      ) return false;
    }
    if (contract.uniqueIdentities?.some((identity) => (counts.get(identity) ?? 0) > 1)) {
      return false;
    }
  }
  return true;
}

interface WindowBucketResolution {
  bucket: Record<string, unknown> | null;
  invalid: boolean;
}

function resolveWindowBucket(
  body: unknown,
  sourceKey: string,
  sourceKeys: string[] | undefined,
  sourceContainer: WindowSpec["sourceContainer"],
  conditions: FieldConditionSpec[] | undefined,
  omitWhen?: FieldConditionSpec[],
  anyConditions?: FieldConditionSpec[],
  duration?: WindowSpec["duration"],
  identityAliases?: string[]
): WindowBucketResolution {
  let invalid = false;
  let bucket: Record<string, unknown> | null = null;
  let matchCount = 0;
  const consider = (record: Record<string, unknown>): void => {
    if (identityAliases?.length) {
      const aliases = identityAliases
        .map((key) => getPath(record, key))
        .filter(isPresent)
        .map(scalarString);
      if (aliases.some((value) => value === null) || new Set(aliases).size > 1) invalid = true;
    }
    if (conditionContractInvalid(record, conditions)) invalid = true;
    for (const condition of omitWhen ?? []) {
      if (
        isPresent(getPath(record, condition.key)) &&
        conditionContractInvalid(record, [condition])
      ) {
        invalid = true;
      }
    }
    const eligible = (!conditions?.length || matchesConditions(record, conditions)) &&
      (!anyConditions?.length || anyConditions.some((condition) => matchesConditions(record, [condition]))) &&
      (!omitWhen?.length || !matchesConditions(record, omitWhen)) &&
      matchesDuration(record, duration);
    if (!eligible) return;
    matchCount += 1;
    if (!bucket) bucket = record;
  };
  for (const path of [sourceKey, ...(sourceKeys ?? [])]) {
    const value = getPath(body, path);
    if (value === undefined || value === null) continue;
    if (sourceContainer === "array") {
      if (!Array.isArray(value)) {
        invalid = true;
        continue;
      }
      if (value.length > 128) invalid = true;
      const boundedEntries = value.slice(0, 128);
      if (
        boundedEntries.some(
          (entry) => entry === null || typeof entry !== "object" || Array.isArray(entry)
        )
      ) {
        invalid = true;
      }
      for (const entry of boundedEntries) {
        if (entry !== null && typeof entry === "object" && !Array.isArray(entry)) {
          consider(entry as Record<string, unknown>);
        }
      }
      continue;
    }
    if (Array.isArray(value) || typeof value !== "object") {
      invalid = true;
      continue;
    }
    consider(value as Record<string, unknown>);
  }
  if (matchCount > 1) invalid = true;
  return { bucket, invalid };
}

function getFieldPath(bucket: Record<string, unknown>, root: unknown, path: string): unknown {
  return path === "$" || path.startsWith("$.") ? getPath(root, path) : getPath(bucket, path);
}

/**
 * Aggregate-path lookup: segments ending in `[]` flat-map arrays, so
 * `data[].results[].amount.value` collects every matching leaf. Bounded at
 * 128 elements per array level like every other provider-controlled fan-out.
 */
interface CollectedPath {
  values: unknown[];
  truncated: boolean;
  invalidStructure: boolean;
}

function collectPath(obj: unknown, dotPath: string): CollectedPath {
  let frontier: unknown[] = [obj];
  let truncated = false;
  let invalidStructure = false;
  for (const rawSegment of dotPath.split(".")) {
    const segment = rawSegment as string;
    const next: unknown[] = [];
    const isFlatMap = segment.endsWith("[]");
    const key = isFlatMap ? segment.slice(0, -2) : segment;
    for (const node of frontier) {
      if (node === null || typeof node !== "object") {
        invalidStructure = true;
        continue;
      }
      const value = (node as Record<string, unknown>)[key];
      if (isFlatMap) {
        if (Array.isArray(value)) {
          if (value.length > 128) truncated = true;
          next.push(...value.slice(0, 128));
        } else {
          invalidStructure = true;
        }
      } else {
        next.push(value);
      }
    }
    frontier = next;
    if (frontier.length === 0) {
      return { values: [], truncated, invalidStructure };
    }
  }
  return { values: frontier, truncated, invalidStructure };
}

/** Normalizes to second-precision ISO-8601 with a trailing Z. */
function toIso(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function isStrictInternetDateTime(value: string): boolean {
  const match = /^(\d{4})-(0[1-9]|1[0-2])-([0-9]{2})T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(?:\.[0-9]{1,9})?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):?[0-5][0-9]|14:?00))$/.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (year < 1970 || year > 2099) return false;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day >= 1 && day <= (days[month - 1] ?? 0);
}

function parseReset(
  value: unknown,
  format: WindowSpec["resetFormat"],
  lenient: boolean
): string | null | undefined {
  if (value === null) return null;
  if (value === undefined) return undefined;
  if (format === "iso8601") {
    if (
      typeof value !== "string" ||
      // Match Foundation's ISO8601DateFormatter(.withInternetDateTime), with
      // the separately supported fractional-seconds option. JavaScript's
      // unrestricted Date parser also accepts values such as "0", date-only
      // strings, and locale dates, which would diverge from the app.
      !isStrictInternetDateTime(value)
    ) return undefined;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return undefined;
    return toIso(date);
  }
  const numeric = windowNumber(value, lenient);
  if (numeric === null || !Number.isSafeInteger(numeric) || numeric < 0) return undefined;
  const maximum = format === "unixMillis" ? 4_102_444_800_000 : 4_102_444_800;
  if (numeric >= maximum) return undefined;
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
  if (typeof value === "string") {
    const trimmed = value.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
    if (trimmed.length === 0) return null;
    if (!/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(trimmed)) {
      return null;
    }
    const parsed = Number(trimmed);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function readBucket(
  spec: ProviderSpec,
  bucket: Record<string, unknown>,
  root: unknown,
  windowSpec: Pick<
    WindowSpec,
    "id" | "resetFormat" | "windowSeconds" | "secondary" | "fields" | "idByWindowSeconds" | "duration"
  > & {
    label?: string | null;
  }
): UsageWindow | null {
  if (!spec.responseFields) return null;
  const utilizationKey = windowSpec.fields?.utilization ?? spec.responseFields.utilization;
  const resetsAtKey = windowSpec.fields?.resetsAt ?? spec.responseFields.resetsAt;
  const lenient = spec.responseFields.allowStringNumbers === true;

  let utilization: number;
  const calculation = windowSpec.fields;
  if (calculation?.used && calculation.limit) {
    const used = windowNumber(getFieldPath(bucket, root, calculation.used), lenient);
    const limit = windowNumber(getFieldPath(bucket, root, calculation.limit), lenient);
    if (used === null || limit === null || used < 0 || limit <= 0) return null;
    utilization = (used / limit) * 100;
  } else {
    const rawUtilization = windowNumber(getFieldPath(bucket, root, utilizationKey), lenient);
    if (rawUtilization === null || rawUtilization < 0 || rawUtilization > 100) return null;
    utilization =
      spec.responseFields.utilizationKind === "remaining" ? 100 - rawUtilization : rawUtilization;
  }
  if (!Number.isFinite(utilization) || utilization < 0) return null;

  const reset = parseReset(getFieldPath(bucket, root, resetsAtKey), windowSpec.resetFormat, lenient);
  if (reset === undefined) return null;

  let windowSeconds: number | null = windowSpec.windowSeconds ?? null;
  if (windowSpec.duration) {
    windowSeconds = windowDurationSeconds(bucket, windowSpec.duration);
    if (windowSeconds === null) return null;
  }
  if (spec.responseFields.windowSeconds) {
    const fromResponse = windowNumber(
      getFieldPath(bucket, root, spec.responseFields.windowSeconds),
      lenient
    );
    if (fromResponse !== null && Number.isSafeInteger(fromResponse) && fromResponse > 0) {
      windowSeconds = fromResponse;
    }
  }

  let resolvedId = windowSpec.id;
  if (windowSpec.idByWindowSeconds && Object.keys(windowSpec.idByWindowSeconds).length > 0) {
    if (windowSeconds === null) return null;
    const durationId = windowSpec.idByWindowSeconds[String(windowSeconds)];
    if (!durationId) return null;
    resolvedId = durationId;
  }

  return {
    id: resolvedId,
    label: windowSpec.label ?? null,
    utilization: Math.min(100, Math.max(0, utilization)),
    resetsAt: reset,
    windowSeconds,
    secondary: windowSpec.secondary,
  };
}

function windowCandidateUnavailable(
  spec: ProviderSpec,
  bucket: Record<string, unknown>,
  root: unknown,
  windowSpec: Pick<WindowSpec, "fields">
): boolean {
  if (!spec.responseFields) return false;
  const fields = windowSpec.fields;
  if (fields?.used && fields.limit) {
    const used = getFieldPath(bucket, root, fields.used);
    const limit = getFieldPath(bucket, root, fields.limit);
    if (!isPresent(used) || !isPresent(limit)) return true;
    const parsedLimit = windowNumber(limit, spec.responseFields.allowStringNumbers === true);
    return parsedLimit === 0;
  }
  const utilizationKey = fields?.utilization ?? spec.responseFields.utilization;
  return !isPresent(getFieldPath(bucket, root, utilizationKey));
}

/** Classifies provider-defined failures carried inside an HTTP 2xx body.
 * Missing configured fields are schema drift, known auth codes are
 * authExpired, and other explicit provider failures are network/provider
 * errors. A null result means the envelope is healthy or not configured. */
export function classifyResponseEnvelope(
  spec: ProviderSpec,
  body: unknown
): "authExpired" | "network" | "schemaChanged" | null {
  if (!isValidDecodedJSON(body)) return "schemaChanged";
  const envelope = spec.responseEnvelope;
  if (!envelope) return null;
  const code = conditionScalar(getPath(body, envelope.codeKey), {
    key: envelope.codeKey,
    equals: envelope.okCode,
    valueType: envelope.codeValueType,
  });
  if (code === null) return "schemaChanged";
  const success = envelope.successKey
    ? conditionScalar(getPath(body, envelope.successKey), {
        key: envelope.successKey,
        equals: envelope.successValue ?? "true",
        valueType: envelope.successValueType,
      })
    : envelope.successValue ?? null;
  if (envelope.successKey && success === null) return "schemaChanged";
  const codeOK = code === envelope.okCode;
  const successOK = !envelope.successKey || success === (envelope.successValue ?? "true");
  if (codeOK && successOK) return null;
  return envelope.authCodes?.includes(code) ? "authExpired" : "network";
}

function metricNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const trimmed = value.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
    if (trimmed.length === 0) return null;
    if (!/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(trimmed)) {
      return null;
    }
    const parsed = Number(trimmed);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizedIdSuffix(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9]/gu, "_");
}

function normalizedMetricId(raw: string, kind: UsageMetricKind): string {
  return `${kind}_${normalizedIdSuffix(raw)}`;
}

function boundedProviderText(raw: unknown, maximumLength: number): string | null {
  if (
    typeof raw !== "string" ||
    raw.length === 0 ||
    raw.trim().length === 0 ||
    raw !== raw.trim() ||
    raw.length > maximumLength ||
    // Cc AND Cf, matching Swift's CharacterSet.controlCharacters exactly (it
    // covers both categories). Cc alone let zero-width and bidi-override
    // characters through, which (a) created provider ids the two mappers
    // disagreed about - a window visible in the CLI and silently absent
    // from the app - and (b) left the only sanitizer between
    // provider-controlled text and rendered terminal output blind to bidi
    // spoofing.
    /[\p{Cc}\p{Cf}\p{Cs}]/u.test(raw)
  ) {
    return null;
  }
  return raw;
}

/**
 * Maps a raw usage response through the provider's window spec.
 * Returns null when nothing maps at all — the schemaChanged signal.
 * Null/missing buckets are optional (e.g. no Opus quota on this plan), while
 * present malformed buckets retain partial output and set `incomplete`.
 */
export function mapUsageResponse(spec: ProviderSpec, body: unknown): MappedUsage | null {
  if (
    body === null ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    !isValidDecodedJSON(body)
  ) return null;

  const windows: UsageWindow[] = [];
  const windowIds = new Set<string>();
  const resolvedFallbackGroups = new Set<string>();
  let incomplete = (spec.incompleteWhen ?? []).some((condition) =>
    matchesConditions(body as Record<string, unknown>, [condition])
  ) || (spec.requiredConditions ?? []).some((condition) =>
    !matchesConditions(body as Record<string, unknown>, [condition])
  ) || (spec.requiredPaths ?? []).some((path) => getPath(body, path) === undefined)
    || (spec.absentOrNullPaths ?? []).some((path) => {
      const value = getPath(body, path);
      return value !== undefined && value !== null;
    }) || !exhaustiveCollectionsAreValid(spec, body);
  for (const windowSpec of spec.windows) {
    if (windowSpec.fallbackGroup && resolvedFallbackGroups.has(windowSpec.fallbackGroup)) {
      continue;
    }
    const resolution = resolveWindowBucket(
      body,
      windowSpec.sourceKey,
      windowSpec.sourceKeys,
      windowSpec.sourceContainer,
      windowSpec.conditions,
      windowSpec.omitWhen,
      windowSpec.anyConditions,
      windowSpec.duration,
      windowSpec.identityAliases
    );
    if (resolution.invalid) incomplete = true;
    const bucket = resolution.bucket;
    if (!bucket) continue;
    const mapped = readBucket(spec, bucket, body, windowSpec);
    if (!mapped) {
      const unavailable = windowCandidateUnavailable(spec, bucket, body, windowSpec);
      if (!unavailable || windowSpec.requiredWhenPresent !== false) incomplete = true;
      continue;
    }
    if (!windowIds.has(mapped.id)) {
      windowIds.add(mapped.id);
      windows.push(mapped);
    } else {
      // Duration-derived ids are semantic identities. If two static buckets
      // collapse to the same id, silently keeping the first can hide a real
      // session/weekly lane while still satisfying minimumWindows.
      incomplete = true;
    }
    if (windowSpec.fallbackGroup) resolvedFallbackGroups.add(windowSpec.fallbackGroup);
  }

  if (spec.additionalWindows) {
    const aw = spec.additionalWindows;
    const extra = getPath(body, aw.sourceKey);
    if (Array.isArray(extra)) {
      if (extra.length > 128) incomplete = true;
      let mappedEntries = 0;
      for (const entry of extra.slice(0, 128)) {
        if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
          if (aw.requiredWhenPresent) incomplete = true;
          continue;
        }
        const record = entry as Record<string, unknown>;
        // Optional per-entry filter (e.g. keep only kind === "weekly_scoped").
        if (aw.filter) {
          const filterValue = scalarString(getPath(record, aw.filter.key));
          if (filterValue === null) {
            if (aw.requiredWhenPresent) incomplete = true;
            continue;
          }
          if (filterValue !== aw.filter.equals) continue;
        }
        if (aw.conditions?.length && !matchesConditions(record, aw.conditions)) {
          // A well-formed explicit mismatch (Claude is_active=false) means the
          // lane is legitimately ineligible. A missing or non-scalar condition
          // after the kind filter matched is schema drift.
          if (
            aw.requiredWhenPresent &&
            conditionContractInvalid(record, aw.conditions)
          ) {
            incomplete = true;
          }
          continue;
        }
        const rawId = boundedProviderText(getPath(record, aw.idKey), 128);
        if (!rawId) {
          if (aw.requiredWhenPresent) incomplete = true;
          continue;
        }
        // A prefix means synthesize a stable normalized id
        // (weekly_scoped_fable). Reject a suffix containing no ASCII identity
        // characters; accepting punctuation-only or non-ASCII-only text would
        // collapse distinct provider lanes into underscore aliases.
        const normalizedSuffix = normalizedIdSuffix(rawId);
        if (aw.idPrefix && !/[a-z0-9]/.test(normalizedSuffix)) {
          incomplete = true;
          continue;
        }
        if (aw.idFormat === "asciiSlug" && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(rawId)) {
          incomplete = true;
          continue;
        }
        // Without a prefix, the bounded raw id stands (Codex metered_feature).
        const id = aw.idPrefix ? `${aw.idPrefix}_${normalizedSuffix}` : rawId;
        const label = aw.labelKey ? boundedProviderText(getPath(record, aw.labelKey), 64) : null;
        // A declared provider label is part of the contract. Codex model lanes
        // rely on limit_name both for display and for Models-tab identity, so
        // silently accepting a missing/blank label would report Live while
        // hiding valid quota data from the user.
        if (aw.labelKey && !label) {
          incomplete = true;
          continue;
        }
        const entryWindows = aw.entryWindows?.length ? aw.entryWindows : [null];
        let mappedForEntry = 0;
        for (const entryWindow of entryWindows) {
          const resolution = entryWindow
            ? resolveWindowBucket(
                record,
                entryWindow.sourceKey,
                undefined,
                entryWindow.sourceContainer,
                undefined
              )
            : { bucket: record, invalid: false };
          if (resolution.invalid) incomplete = true;
          const bucket = resolution.bucket;
          if (!bucket) continue;
          const suffix = entryWindow
            ? entryWindow.idSuffix
            : null;
          const baseId = suffix ? `${id}_${suffix}` : id;
          const mapped = readBucket(spec, bucket, record, {
            id: baseId,
            resetFormat: entryWindow?.resetFormat ?? aw.resetFormat ?? "unixSeconds",
            secondary: entryWindow?.secondary ?? aw.secondary,
            label:
              label && entryWindow?.labelSuffix
                ? `${label} · ${entryWindow.labelSuffix}`
                : label,
            ...(entryWindow?.windowSeconds !== undefined
              ? { windowSeconds: entryWindow.windowSeconds }
              : aw.windowSeconds !== undefined
                ? { windowSeconds: aw.windowSeconds }
                : {}),
            ...(entryWindow?.fields
              ? { fields: entryWindow.fields }
              : aw.fields
                ? { fields: aw.fields }
                : {}),
          });
          if (!mapped) {
            incomplete = true;
            continue;
          }
          let finalWindow = mapped;
          if (entryWindow) {
            const durationKey = mapped.windowSeconds === null
              ? null
              : String(mapped.windowSeconds);
            const durationIds = entryWindow.idSuffixByWindowSeconds ?? {};
            const durationLabels = entryWindow.labelSuffixByWindowSeconds ?? {};
            const durationSuffix = durationKey === null ? undefined : durationIds[durationKey];
            const durationLabelSuffix = durationKey === null ? undefined : durationLabels[durationKey];
            if (Object.keys(durationIds).length > 0 && !durationSuffix) {
              incomplete = true;
              continue;
            }
            if (Object.keys(durationLabels).length > 0 && !durationLabelSuffix) {
              incomplete = true;
              continue;
            }
            finalWindow = {
              ...mapped,
              ...(durationSuffix ? { id: `${id}_${durationSuffix}` } : {}),
              ...(label && durationLabelSuffix
                ? { label: `${label} · ${durationLabelSuffix}` }
                : {}),
            };
          }
          if (!windowIds.has(finalWindow.id)) {
            windowIds.add(finalWindow.id);
            windows.push(finalWindow);
          } else {
            incomplete = true;
            continue;
          }
          mappedForEntry += 1;
        }
        if (aw.requiredWhenPresent && mappedForEntry === 0) incomplete = true;
        if (mappedForEntry > 0) mappedEntries += 1;
      }
      // Codex has no eligibility filter: a present, non-empty lane array made
      // entirely of garbage is schema drift. Claude does filter limits[] by
      // kind, so a real array with zero weekly_scoped entries is legitimate.
      if (
        aw.requiredWhenPresent &&
        !aw.filter &&
        extra.length > 0 &&
        mappedEntries === 0
      ) {
        incomplete = true;
      }
    } else if (extra !== undefined && aw.requiredWhenPresent) {
      // A present dynamic-window source with the wrong container type is
      // never equivalent to an absent optional source.
      incomplete = true;
    }
  }

  const metrics: UsageMetric[] = [];
  const metricIds = new Set<string>();
  for (const mapping of spec.metricMappings ?? []) {
    // Duplicate ids are ordered fallbacks. Once a canonical candidate maps,
    // later legacy candidates are irrelevant and must not introduce drift
    // from stale or malformed denomination metadata.
    if (metricIds.has(mapping.id)) continue;
    if (mapping.fallbackBlockedBy?.some((path) => isPresent(getPath(body, path)))) {
      continue;
    }
    if (mapping.conditions?.length) {
      const familyPresent = mapping.presencePaths?.some((path) => isPresent(getPath(body, path))) ?? false;
      if (conditionContractInvalid(body as Record<string, unknown>, mapping.conditions)) {
        if (familyPresent) incomplete = true;
        continue;
      }
      if (!matchesConditions(body as Record<string, unknown>, mapping.conditions)) continue;
    }
    const rawSource = getPath(body, mapping.sourceKey);
    if (
      mapping.presencePaths?.some((path) => isPresent(getPath(body, path))) &&
      !isPresent(rawSource)
    ) {
      incomplete = true;
      continue;
    }
    if (
      mapping.aggregate !== "sum" &&
      isPresent(rawSource) &&
      metricNumber(rawSource) === null
    ) {
      incomplete = true;
      continue;
    }
    const missingNumericRequirement = mapping.requires?.some(
      (path) => metricNumber(getPath(body, path)) === null
    ) ?? false;
    const missingPresenceRequirement = mapping.requiresPresent?.some(
      (path) => !isPresent(getPath(body, path))
    ) ?? false;
    if (missingNumericRequirement || missingPresenceRequirement) {
      if (
        mapping.incompleteWhenAnyRequiredPresent &&
        [...(mapping.requires ?? []), ...(mapping.requiresPresent ?? [])]
          .some((path) => isPresent(getPath(body, path)))
      ) {
        incomplete = true;
      }
      continue;
    }
    if (mapping.equalFields?.some((paths) => {
      const values = paths.map((path) => scalarString(getPath(body, path)));
      return values.some((value) => value === null) || new Set(values).size > 1;
    })) {
      incomplete = true;
      continue;
    }
    if (mapping.requiresPositive?.some((path) => {
      const value = metricNumber(getPath(body, path));
      return value === null || value <= 0;
    })) {
      continue;
    }
    let value: number | null;
    if (mapping.aggregate === "sum") {
      // A zero-spend month legitimately sums to 0 (root array present but
      // empty); a missing root key, or leaves that all fail to parse, means
      // the shape changed. The distinction keeps fresh accounts showing
      // $0.00 instead of schemaChanged.
      const firstSegment = mapping.sourceKey.split(".")[0] ?? "";
      const firstKey = firstSegment.endsWith("[]") ? firstSegment.slice(0, -2) : firstSegment;
      const root = (body as Record<string, unknown>)[firstKey];
      // The "root present but empty" case that legitimately sums to 0 is an
      // empty ARRAY. A non-array root (an error envelope, a pagination wrapper
      // a provider added) collects no leaves either, and treating that as a
      // zero-spend month reports a confident $0.00 for what is a schema change.
      if (
        root === undefined ||
        root === null ||
        (firstSegment.endsWith("[]") && !Array.isArray(root))
      ) {
        value = null;
      } else {
        const collected = collectPath(body, mapping.sourceKey);
        const numbers = collected.values
          .map((leaf) => metricNumber(leaf))
          .filter((n): n is number => n !== null);
        if (
          collected.truncated ||
          collected.invalidStructure ||
          numbers.length !== collected.values.length
        ) {
          incomplete = true;
          value = null;
        } else {
          if (mapping.aggregateUnitKey) {
            const units = collectPath(body, mapping.aggregateUnitKey);
            const expected = mapping.aggregateExpectedUnit;
            if (
              units.truncated ||
              units.invalidStructure ||
              units.values.length !== collected.values.length ||
              !expected ||
              units.values.some((unit) => scalarString(unit) !== expected)
            ) {
              incomplete = true;
              value = null;
            } else {
              value = numbers.reduce((a, b) => a + b, 0);
            }
          } else {
            value = numbers.reduce((a, b) => a + b, 0);
          }
        }
      }
    } else {
      value = metricNumber(getPath(body, mapping.sourceKey));
    }
    if (value === null) continue;
    let usedExponent = false;
    if (mapping.exponentKey) {
      const rawExponent = getPath(body, mapping.exponentKey);
      if (rawExponent !== undefined && rawExponent !== null) {
        const exponent = metricNumber(rawExponent);
        if (
          exponent === null ||
          !Number.isSafeInteger(exponent) ||
          exponent < 0 ||
          exponent > 18
        ) {
          // The provider supplied denomination metadata but it is unusable.
          // Falling back to a guessed scale can create a 10x/100x money error.
          // Omit this candidate and mark the response incomplete; a later
          // legacy candidate with the same id must not make the status Live.
          incomplete = true;
          continue;
        }
        value /= 10 ** exponent;
        usedExponent = true;
      }
    }
    if (!usedExponent && typeof mapping.scale === "number" && Number.isFinite(mapping.scale)) {
      value *= mapping.scale;
    }
    if (!Number.isFinite(value)) continue;
    let unit: string | null = mapping.unit ?? null;
    if (mapping.unitKey) {
      const rawUnit = getPath(body, mapping.unitKey);
      if (isPresent(rawUnit)) {
        const resolved = boundedProviderText(rawUnit, 32);
        if (!resolved) {
          incomplete = true;
          continue;
        }
        unit = resolved;
      }
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
    if (entries.length > 128) incomplete = true;
    for (const entry of entries.slice(0, 128)) {
      if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
        incomplete = true;
        continue;
      }
      const record = entry as Record<string, unknown>;
      const rawId = boundedProviderText(getPath(record, collection.idKey), 128);
      const value = metricNumber(getPath(record, collection.valueKey));
      if (!rawId || value === null) {
        incomplete = true;
        continue;
      }
      let unit: string | null = null;
      if (collection.unitKey) {
        const rawUnit = getPath(record, collection.unitKey);
        if (isPresent(rawUnit)) {
          unit = boundedProviderText(rawUnit, 32);
          if (!unit) {
            incomplete = true;
            continue;
          }
        }
      }
      const metric = {
        id: normalizedMetricId(rawId, collection.kind),
        label: `${collection.label} (${unit ?? rawId})`,
        kind: collection.kind,
        value,
        unit,
        secondary: collection.secondary,
      };
      if (metricIds.has(metric.id)) {
        incomplete = true;
        continue;
      }
      metricIds.add(metric.id);
      metrics.push(metric);
    }
  }

  const recognizedEmpty = responseIsRecognizedEmpty(spec, body);
  if (windows.length === 0 && metrics.length === 0 && !recognizedEmpty) return null;

  let planLabel: string | null = null;
  if (spec.planKey) {
    const rawPlan = getPath(body, spec.planKey);
    planLabel = boundedProviderText(rawPlan, 128);
    // A plan key listed in requiredPaths is a required, non-null provider
    // string. This is how Codex mirrors its upstream non-optional plan_type
    // contract without making optional plan labels mandatory elsewhere.
    if ((spec.requiredPaths?.includes(spec.planKey) || isPresent(rawPlan)) && !planLabel) {
      incomplete = true;
    }
  }

  return { planLabel, windows, metrics, incomplete, recognizedEmpty };
}

import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { REPO_ROOT } from "./helpers.js";

const EVIDENCE_CLASSES = new Set([
  "live_sanitized",
  "vendor_example",
  "community_research",
  "synthetic_derived",
]);

interface ProvenanceSource {
  url: string;
  checkedOn: string;
  notes: string;
}

interface ProvenanceEntry {
  input: string;
  expected: string | null;
  evidenceClass: string;
  sourceIds: string[];
  verifiedOn: string;
  notes: string;
}

interface ProvenanceManifest {
  version: number;
  evidenceClasses: Record<string, string>;
  sources: Record<string, ProvenanceSource>;
  fixtures: ProvenanceEntry[];
}

const fixtureDir = path.join(REPO_ROOT, "protocol", "fixtures");
const manifestPath = path.join(REPO_ROOT, "protocol", "fixture-provenance.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as ProvenanceManifest;
const fixtureFiles = readdirSync(fixtureDir).filter((name) => name.endsWith(".json")).sort();

function duplicateObjectKeys(raw: string): string[] {
  let offset = 0;
  const duplicates: string[] = [];

  const skipWhitespace = () => {
    while (/\s/.test(raw[offset] ?? "")) offset += 1;
  };

  const parseString = (): string => {
    const start = offset;
    if (raw[offset] !== '"') throw new Error(`expected string at offset ${offset}`);
    offset += 1;
    let escaped = false;
    while (offset < raw.length) {
      const character = raw[offset]!;
      offset += 1;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        return JSON.parse(raw.slice(start, offset)) as string;
      }
    }
    throw new Error(`unterminated string at offset ${start}`);
  };

  const parseValue = (): void => {
    skipWhitespace();
    if (raw[offset] === "{") {
      parseObject();
      return;
    }
    if (raw[offset] === "[") {
      parseArray();
      return;
    }
    if (raw[offset] === '"') {
      parseString();
      return;
    }
    const start = offset;
    while (offset < raw.length && !/[\s,}\]]/.test(raw[offset]!)) offset += 1;
    JSON.parse(raw.slice(start, offset));
  };

  const parseArray = (): void => {
    offset += 1;
    skipWhitespace();
    if (raw[offset] === "]") {
      offset += 1;
      return;
    }
    while (true) {
      parseValue();
      skipWhitespace();
      if (raw[offset] === "]") {
        offset += 1;
        return;
      }
      if (raw[offset] !== ",") throw new Error(`expected array separator at offset ${offset}`);
      offset += 1;
    }
  };

  const parseObject = (): void => {
    offset += 1;
    const keys = new Set<string>();
    skipWhitespace();
    if (raw[offset] === "}") {
      offset += 1;
      return;
    }
    while (true) {
      skipWhitespace();
      const key = parseString();
      if (keys.has(key)) duplicates.push(key);
      keys.add(key);
      skipWhitespace();
      if (raw[offset] !== ":") throw new Error(`expected object colon at offset ${offset}`);
      offset += 1;
      parseValue();
      skipWhitespace();
      if (raw[offset] === "}") {
        offset += 1;
        return;
      }
      if (raw[offset] !== ",") throw new Error(`expected object separator at offset ${offset}`);
      offset += 1;
    }
  };

  parseValue();
  skipWhitespace();
  if (offset !== raw.length) throw new Error(`unexpected trailing JSON at offset ${offset}`);
  return duplicates;
}

function isDateOnly(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value;
}

describe("fixture provenance", () => {
  it("contains no duplicate object keys that JSON.parse would silently overwrite", () => {
    const contractFiles = [
      path.join(REPO_ROOT, "protocol", "providers.json"),
      manifestPath,
      ...fixtureFiles.map((name) => path.join(fixtureDir, name)),
    ];
    for (const file of contractFiles) {
      expect(duplicateObjectKeys(readFileSync(file, "utf8")), file).toEqual([]);
    }
  });

  it("covers every fixture input and expected output exactly once", () => {
    const inputs = fixtureFiles.filter((name) => !name.endsWith("-expected.json"));
    const expectedFiles = fixtureFiles.filter((name) => name.endsWith("-expected.json"));
    const manifestInputs = manifest.fixtures.map((entry) => entry.input);
    const manifestExpected = manifest.fixtures.flatMap((entry) => (entry.expected ? [entry.expected] : []));

    expect(manifest.version).toBe(1);
    expect(manifestInputs.sort()).toEqual(inputs);
    expect(new Set(manifestInputs).size).toBe(manifestInputs.length);
    expect(manifestExpected.sort()).toEqual(expectedFiles);
    expect(new Set(manifestExpected).size).toBe(manifestExpected.length);

    for (const entry of manifest.fixtures) {
      expect(entry.input, entry.input).not.toContain("/");
      const sibling = entry.input.replace(/\.json$/, "-expected.json");
      expect(entry.expected, entry.input).toBe(expectedFiles.includes(sibling) ? sibling : null);
    }
  });

  it("uses only reviewed evidence classes, dated sources, and meaningful notes", () => {
    expect(Object.keys(manifest.evidenceClasses).sort()).toEqual([...EVIDENCE_CLASSES].sort());

    for (const [sourceId, source] of Object.entries(manifest.sources)) {
      expect(source.url, sourceId).toMatch(/^https:\/\//);
      expect(isDateOnly(source.checkedOn), sourceId).toBe(true);
      expect(source.notes.trim().length, sourceId).toBeGreaterThanOrEqual(20);
    }

    for (const entry of manifest.fixtures) {
      expect(EVIDENCE_CLASSES.has(entry.evidenceClass), entry.input).toBe(true);
      expect(isDateOnly(entry.verifiedOn), entry.input).toBe(true);
      expect(entry.notes.trim().length, entry.input).toBeGreaterThanOrEqual(20);
      expect(entry.sourceIds.length, entry.input).toBeGreaterThan(0);
      expect(new Set(entry.sourceIds).size, entry.input).toBe(entry.sourceIds.length);
      for (const sourceId of entry.sourceIds) {
        expect(manifest.sources[sourceId], `${entry.input}: ${sourceId}`).toBeDefined();
      }
    }

    const referencedSources = new Set(manifest.fixtures.flatMap((entry) => entry.sourceIds));
    expect([...referencedSources].sort()).toEqual(Object.keys(manifest.sources).sort());
  });

  it("does not promote modeled fixtures to live captures without an explicit review", () => {
    const liveInputs = manifest.fixtures
      .filter((entry) => entry.evidenceClass === "live_sanitized")
      .map((entry) => entry.input)
      .sort();

    // These are the only fixture files whose repository history explicitly
    // records a production capture. Additions require evidence in this test
    // and in protocol/fixture-provenance.json.
    expect(liveInputs).toEqual(["claude-429.json", "claude-usage-scoped-limits.json"]);
  });
});

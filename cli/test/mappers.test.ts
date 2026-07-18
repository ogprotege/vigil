import { describe, expect, it } from "vitest";
import { readdirSync } from "node:fs";
import path from "node:path";
import { loadRegistry, type ProviderId } from "../src/spec/registry.js";
import { mapUsageResponse } from "../src/providers/map.js";
import { loadFixture, REPO_ROOT } from "./helpers.js";

interface ExpectedFile {
  planLabel?: string;
  windows: Array<{
    id: string;
    utilization: number;
    resetsAt: string | null;
    windowSeconds: number;
    secondary: boolean;
  }>;
}

const registry = loadRegistry();
const fixtureDir = path.join(REPO_ROOT, "protocol", "fixtures");

// Every X.json with an X-expected.json sibling is a parity case; the provider
// is the filename prefix. This exact pairing is asserted by VigilKit too.
const parityCases = readdirSync(fixtureDir)
  .filter((f) => f.endsWith("-expected.json"))
  .map((expected) => ({
    expected,
    fixture: expected.replace("-expected.json", ".json"),
    providerId: expected.split("-")[0] as ProviderId,
  }));

describe("fixture parity", () => {
  it("has at least one case per provider", () => {
    const providers = new Set(parityCases.map((c) => c.providerId));
    expect(providers).toEqual(new Set(["claude", "codex"]));
  });

  for (const { fixture, expected, providerId } of parityCases) {
    it(`${fixture} maps to ${expected}`, () => {
      const spec = registry.providers[providerId];
      const mapped = mapUsageResponse(spec, loadFixture(fixture));
      const want = loadFixture(expected) as ExpectedFile;
      expect(mapped).not.toBeNull();
      expect(mapped!.windows).toEqual(
        want.windows.map((w) => ({ ...w, windowSeconds: w.windowSeconds ?? null }))
      );
      expect(mapped!.planLabel).toBe(want.planLabel ?? null);
    });
  }
});

describe("schema-drift tolerance", () => {
  it("returns null (schemaChanged) when nothing maps", () => {
    expect(mapUsageResponse(registry.providers.claude, { totally: "different" })).toBeNull();
    expect(mapUsageResponse(registry.providers.claude, null)).toBeNull();
    expect(mapUsageResponse(registry.providers.claude, "string")).toBeNull();
  });

  it("skips malformed buckets but keeps good ones", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: "not-a-number", resets_at: "2026-07-18T21:00:00Z" },
      seven_day: { utilization: 12, resets_at: "2026-07-20T07:00:00Z" },
    });
    expect(mapped).not.toBeNull();
    expect(mapped!.windows.map((w) => w.id)).toEqual(["weekly"]);
  });

  it("clamps utilization into 0..100", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 240, resets_at: null },
    });
    expect(mapped!.windows[0]!.utilization).toBe(100);
  });

  it("skips unparseable additional_rate_limits entries without failing", () => {
    const mapped = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        "garbage",
        { name: "ok-lane", used_percent: 5, reset_at: 1784408400, limit_window_seconds: 60 },
        { name: "no-numbers" },
      ],
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual(["session", "ok-lane"]);
  });

  it("reads nested rate_limit objects in additional entries", () => {
    const mapped = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        { name: "nested-lane", rate_limit: { used_percent: 7, reset_at: 1784408400, limit_window_seconds: 60 } },
      ],
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual(["session", "nested-lane"]);
    expect(mapped!.windows[1]!.utilization).toBe(7);
  });
});

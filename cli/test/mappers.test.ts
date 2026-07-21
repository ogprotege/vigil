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
    label?: string | null;
    utilization: number;
    resetsAt: string | null;
    windowSeconds: number;
    secondary: boolean;
  }>;
  metrics?: Array<{
    id: string;
    label: string;
    kind: "balance" | "spend" | "limit" | "remaining";
    value: number;
    unit: string | null;
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
    expect(providers).toEqual(new Set(Object.keys(registry.providers)));
  });

  for (const { fixture, expected, providerId } of parityCases) {
    it(`${fixture} maps to ${expected}`, () => {
      const spec = registry.providers[providerId];
      const mapped = mapUsageResponse(spec, loadFixture(fixture));
      const want = loadFixture(expected) as ExpectedFile;
      expect(mapped).not.toBeNull();
      expect(mapped!.windows).toEqual(
        want.windows.map((w) => ({
          ...w,
          windowSeconds: w.windowSeconds ?? null,
          label: w.label ?? null,
        }))
      );
      expect(mapped!.metrics).toEqual(want.metrics ?? []);
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

  it("deduplicates provider window and metric IDs without replacing primary values", () => {
    const windows = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        { name: "session", used_percent: 99, reset_at: 1784408400, limit_window_seconds: 60 },
        { name: "lane", used_percent: 5, reset_at: 1784408400, limit_window_seconds: 60 },
        { name: "lane", used_percent: 90, reset_at: 1784408400, limit_window_seconds: 60 },
      ],
    });
    expect(windows!.windows.map((window) => [window.id, window.utilization])).toEqual([
      ["session", 10],
      ["lane", 5],
    ]);

    const metrics = mapUsageResponse(registry.providers.deepseek, {
      balance_infos: [
        { currency: "USD", total_balance: "10" },
        { currency: "usd", total_balance: "999" },
      ],
    });
    expect(metrics!.metrics).toHaveLength(1);
    expect(metrics!.metrics[0]!.value).toBe(10);
  });

  it("rejects oversized reset dates and ignores unsafe window durations", () => {
    expect(
      mapUsageResponse(registry.providers.codex, {
        rate_limit: {
          primary_window: {
            used_percent: 10,
            reset_at: 1e300,
            limit_window_seconds: 1e300,
          },
        },
      })
    ).toBeNull();

    const mapped = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: {
          used_percent: 10,
          reset_at: 1784408400,
          limit_window_seconds: 1e300,
        },
      },
    });
    expect(mapped!.windows[0]!.windowSeconds).toBeNull();
  });

  it("maps Claude limits[] weekly_scoped entries, filtering other kinds and skipping malformed ones", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      seven_day: { utilization: 40, resets_at: "2026-07-27T07:00:00Z" },
      limits: [
        { kind: "weekly_scoped", scope: { model: { display_name: "Fable" } }, utilization: 55, resets_at: "2026-07-27T07:00:00Z" },
        { kind: "monthly_overage", scope: { model: { display_name: "Ignore" } }, utilization: 5, resets_at: "2026-07-27T07:00:00Z" },
        { kind: "weekly_scoped", scope: { model: { display_name: "Broken" } }, resets_at: "2026-07-27T07:00:00Z" },
      ],
    });
    const scoped = mapped!.windows.filter((w) => w.id.startsWith("weekly_scoped"));
    expect(scoped.map((w) => [w.id, w.label])).toEqual([["weekly_scoped_fable", "Fable"]]);
    expect(scoped[0]!.utilization).toBe(55);
    expect(scoped[0]!.windowSeconds).toBe(604800);
  });

  it("keeps a scoped window but drops an over-long label", () => {
    const longName = "M".repeat(80); // > 64 (label cap) but <= 128 (id cap)
    const mapped = mapUsageResponse(registry.providers.claude, {
      seven_day: { utilization: 40, resets_at: "2026-07-27T07:00:00Z" },
      limits: [
        { kind: "weekly_scoped", scope: { model: { display_name: longName } }, utilization: 33, resets_at: "2026-07-27T07:00:00Z" },
      ],
    });
    const scoped = mapped!.windows.find((w) => w.id.startsWith("weekly_scoped"));
    expect(scoped).toBeDefined();
    expect(scoped!.label).toBeNull();
    expect(scoped!.utilization).toBe(33);
  });

  it("resolves a metric unit from unitKey and falls back to the static unit", () => {
    const withCurrency = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: null },
      extra_usage: { is_enabled: true, monthly_limit: 50, used_credits: 5, utilization: 10, currency: "EUR" },
    });
    expect(withCurrency!.metrics.find((m) => m.id === "extra_used")!.unit).toBe("EUR");

    const withoutCurrency = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: null },
      extra_usage: { is_enabled: true, monthly_limit: 50, used_credits: 5, utilization: 10 },
    });
    expect(withoutCurrency!.metrics.find((m) => m.id === "extra_used")!.unit).toBe("USD");
  });

  it("carries a null label on static (non-scoped) windows", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: null },
    });
    expect(mapped!.windows[0]!.label).toBeNull();
  });

  it("drops oversized or control-bearing provider labels", () => {
    const windows = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400 },
      },
      additional_rate_limits: [
        { name: "bad\u001b[2J", used_percent: 99, reset_at: 1784408400 },
        { name: "x".repeat(129), used_percent: 99, reset_at: 1784408400 },
      ],
    });
    expect(windows!.windows.map((window) => window.id)).toEqual(["session"]);

    expect(
      mapUsageResponse(registry.providers.deepseek, {
        balance_infos: [{ currency: "USD\n", total_balance: "10" }],
      })
    ).toBeNull();
  });
});

// Mirrors MapperDivergenceTests in packages/VigilKit — cases whose correct
// outcome is null (schemaChanged) cannot be expressed as a fixture pair, so
// both implementations pin them explicitly instead.
describe("aggregate drift detection (Swift parity)", () => {
  const registry = loadRegistry();

  it("treats an absent aggregate leaf as a shape change, not $0.00", () => {
    expect(
      mapUsageResponse(registry.providers.github, {
        usageItems: [{ date: "2026-07-02", product: "copilot" }, { date: "x" }],
      })
    ).toBeNull();
    expect(
      mapUsageResponse(registry.providers.openai, {
        data: [{ results: [{ amount: { currency: "usd" } }] }],
      })
    ).toBeNull();
  });

  it("treats a non-array aggregate root as a shape change, not $0.00", () => {
    expect(mapUsageResponse(registry.providers.github, { usageItems: { message: "not found" } })).toBeNull();
    expect(mapUsageResponse(registry.providers.github, { usageItems: "nope" })).toBeNull();
    expect(mapUsageResponse(registry.providers.openai, { data: { error: "x" } })).toBeNull();
    expect(mapUsageResponse(registry.providers.openai, { data: true })).toBeNull();
  });

  it("still reports a genuinely empty period as zero", () => {
    const mapped = mapUsageResponse(registry.providers.github, { usageItems: [] });
    expect(mapped?.metrics.find((m) => m.id === "spend_month")?.value).toBe(0);
  });

  it("keeps a partial aggregate honest: real number kept, absent one dropped", () => {
    const mapped = mapUsageResponse(registry.providers.github, {
      usageItems: [{ netQuantity: 125 }],
    });
    expect(mapped?.metrics.map((m) => m.id)).toEqual(["credits_used"]);
  });

  it("rejects Unicode format characters the way the Swift sanitizer does", () => {
    expect(
      mapUsageResponse(registry.providers.deepseek, {
        balance_infos: [{ currency: "US‍D", total_balance: "5" }],
      })
    ).toBeNull();
  });

  it("accepts fractional-second ISO resets (Swift parity)", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 50, resets_at: "2026-07-18T21:00:00.500Z" },
    });
    expect(mapped?.windows[0]?.id).toBe("session");
    expect(mapped?.windows[0]?.resetsAt).toBe("2026-07-18T21:00:00Z");
  });
});

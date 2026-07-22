import { describe, expect, it } from "vitest";
import { readdirSync } from "node:fs";
import path from "node:path";
import { loadRegistry, type ProviderId } from "../src/spec/registry.js";
import { mapUsageResponse } from "../src/providers/map.js";
import { loadFixture, REPO_ROOT } from "./helpers.js";

interface ExpectedFile {
  planLabel?: string;
  incomplete?: boolean;
  recognizedEmpty?: boolean;
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
      if (want.incomplete !== undefined) {
        expect(mapped!.incomplete).toBe(want.incomplete);
      }
      if (want.recognizedEmpty !== undefined) {
        expect(mapped!.recognizedEmpty).toBe(want.recognizedEmpty);
      }
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
    expect(mapped!.incomplete).toBe(true);

    const wrongContainer = mapUsageResponse(registry.providers.claude, {
      five_hour: "changed-wrapper",
      seven_day: { utilization: 12, resets_at: "2026-07-20T07:00:00Z" },
    });
    expect(wrongContainer!.windows.map((w) => w.id)).toEqual(["weekly"]);
    expect(wrongContainer!.incomplete).toBe(true);
  });

  it("rejects impossible direct percentages and defines over-limit ratio policy", () => {
    for (const utilization of [-40, 240]) {
      const mapped = mapUsageResponse(registry.providers.claude, {
        five_hour: { utilization, resets_at: null },
        seven_day: { utilization: 12, resets_at: null },
      });
      expect(mapped!.windows.map((window) => window.id)).toEqual(["weekly"]);
      expect(mapped!.incomplete).toBe(true);
    }

    const negativeRatio = mapUsageResponse(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      individualUsage: {
        plan: { used: -1, limit: 100 },
        overall: { used: 1, limit: 2 },
      },
    });
    expect(negativeRatio!.windows[0]!.utilization).toBe(50);
    expect(negativeRatio!.incomplete).toBe(true);

    const overLimitRatio = mapUsageResponse(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      individualUsage: { plan: { used: 120, limit: 100 } },
    });
    expect(overLimitRatio!.windows[0]!.utilization).toBe(100);
    expect(overLimitRatio!.incomplete).toBe(false);
  });

  it("distinguishes a missing reset key from an explicit null reset", () => {
    const missing = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10 },
      seven_day: { utilization: 12, resets_at: null },
    });
    expect(missing!.windows.map((window) => window.id)).toEqual(["weekly"]);
    expect(missing!.windows[0]!.resetsAt).toBeNull();
    expect(missing!.incomplete).toBe(true);
  });

  it("marks an eligible Codex lane incomplete when none of its nested windows map", () => {
    const mapped = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
        secondary_window: null,
      },
      additional_rate_limits: [
        "garbage",
        {
          limit_name: "Broken lane",
          metered_feature: "broken_lane",
          rate_limit: { primary_window: { reset_at: 1784408400 } },
        },
      ],
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual(["session"]);
    expect(mapped!.incomplete).toBe(true);
  });

  it("marks an eligible dynamic lane incomplete when its identifier is missing", () => {
    const mapped = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        {
          limit_name: "Unidentified lane",
          rate_limit: {
            primary_window: { used_percent: 7, reset_at: 1784408400, limit_window_seconds: 18000 },
          },
        },
      ],
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual(["session"]);
    expect(mapped!.incomplete).toBe(true);
  });

  it("drops a Codex dynamic lane whose duration has no declared identity", () => {
    const body = {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [{
        limit_name: "Unknown duration",
        metered_feature: "unknown_duration",
        rate_limit: {
          primary_window: { used_percent: 7, reset_at: 1784408400, limit_window_seconds: 86400 },
        },
      }],
    };
    const mapped = mapUsageResponse(registry.providers.codex, body);
    expect(mapped!.windows.map((window) => window.id)).toEqual(["session"]);
    expect(mapped!.incomplete).toBe(true);
  });

  it("also requires a known duration when only a label suffix map is configured", () => {
    const codex = registry.providers.codex;
    const primary = codex.additionalWindows!.entryWindows![0]!;
    const spec = {
      ...codex,
      additionalWindows: {
        ...codex.additionalWindows!,
        entryWindows: [{
          ...primary,
          idSuffixByWindowSeconds: {},
          labelSuffixByWindowSeconds: { "18000": "5 hours" },
        }],
      },
    };
    const mapped = mapUsageResponse(spec, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [{
        limit_name: "Unknown label duration",
        metered_feature: "unknown_label_duration",
        rate_limit: {
          primary_window: { used_percent: 7, reset_at: 1784408400, limit_window_seconds: 86400 },
        },
      }],
    });
    expect(mapped!.windows.map((window) => window.id)).toEqual(["session"]);
    expect(mapped!.incomplete).toBe(true);
  });

  it("fans one real Codex additional-rate-limit entry into two windows", () => {
    const mapped = mapUsageResponse(registry.providers.codex, {
      plan_type: "pro",
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
        secondary_window: null,
      },
      additional_rate_limits: [
        {
          limit_name: "Nested lane",
          metered_feature: "nested_lane",
          rate_limit: {
            primary_window: { used_percent: 7, reset_at: 1784408400, limit_window_seconds: 18000 },
            secondary_window: { used_percent: 9, reset_at: 1784530800, limit_window_seconds: 604800 },
          },
        },
      ],
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual([
      "session",
      "nested_lane_session",
      "nested_lane_weekly",
    ]);
    expect(mapped!.windows[1]!.utilization).toBe(7);
    expect(mapped!.windows[2]!.utilization).toBe(9);
    expect(mapped!.windows[1]!.label).toBe("Nested lane · 5 hours");
    expect(mapped!.windows[2]!.label).toBe("Nested lane · Weekly");
    expect(mapped!.incomplete).toBe(false);
  });

  it("compares dynamic filters through JSON scalar strings", () => {
    const claude = registry.providers.claude;
    const spec = {
      ...claude,
      additionalWindows: {
        ...claude.additionalWindows!,
        filter: { key: "kind", equals: "7" },
      },
    };
    const mapped = mapUsageResponse(spec, {
      limits: [
        {
          kind: 7,
          is_active: true,
          scope: { model: { display_name: "Numeric filter" } },
          percent: 25,
          resets_at: "2026-07-27T07:00:00Z",
        },
      ],
    });
    expect(mapped?.windows.map((window) => window.id)).toEqual(["weekly_scoped_numeric_filter"]);
  });

  it("continues past an omitted array candidate to the next valid bucket", () => {
    const mapped = mapUsageResponse(registry.providers.minimax, {
      model_remains: [
        {
          model_name: "general",
          current_interval_status: 3,
          current_interval_remaining_percent: 100,
          end_time: 1784408400000,
        },
        {
          model_name: "general",
          current_interval_status: 1,
          current_interval_remaining_percent: 80,
          end_time: 1784408400000,
        },
      ],
      base_resp: { status_code: 0 },
    });
    expect(mapped!.windows.map((w) => w.id)).toEqual(["session"]);
    expect(mapped!.windows[0]!.utilization).toBe(20);
  });

  it("deduplicates provider window and metric IDs without replacing primary values", () => {
    const windows = mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        { limit_name: "Lane", metered_feature: "lane", rate_limit: { primary_window: { used_percent: 5, reset_at: 1784408400, limit_window_seconds: 18000 } } },
        { limit_name: "Lane", metered_feature: "lane", rate_limit: { primary_window: { used_percent: 90, reset_at: 1784408400, limit_window_seconds: 18000 } } },
      ],
    });
    expect(windows!.windows.map((window) => [window.id, window.utilization])).toEqual([
      ["session", 10],
      ["lane_session", 5],
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

  it("rejects oversized reset dates and unsafe window durations", () => {
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

    expect(mapUsageResponse(registry.providers.codex, {
      rate_limit: {
        primary_window: {
          used_percent: 10,
          reset_at: 1784408400,
          limit_window_seconds: 1e300,
        },
      },
    })).toBeNull();
  });

  it("maps Claude limits[] weekly_scoped entries, filtering other kinds and skipping malformed ones", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      seven_day: { utilization: 40, resets_at: "2026-07-27T07:00:00Z" },
      limits: [
        { kind: "weekly_scoped", is_active: true, scope: { model: { display_name: "Fable" } }, percent: 55, resets_at: "2026-07-27T07:00:00.392792+00:00" },
        { kind: "monthly_overage", scope: { model: { display_name: "Ignore" } }, percent: 5, resets_at: "2026-07-27T07:00:00Z" },
        { kind: "weekly_scoped", is_active: false, scope: { model: { display_name: "Broken" } }, resets_at: "2026-07-27T07:00:00Z" },
      ],
    });
    const scoped = mapped!.windows.filter((w) => w.id.startsWith("weekly_scoped"));
    expect(scoped.map((w) => [w.id, w.label])).toEqual([["weekly_scoped_fable", "Fable"]]);
    expect(scoped[0]!.utilization).toBe(55);
    expect(scoped[0]!.windowSeconds).toBe(604800);
    // Live entries carry microsecond precision; both mappers normalize to
    // whole seconds so a fixture can express the result.
    expect(scoped[0]!.resetsAt).toBe("2026-07-27T07:00:00Z");
  });

  it("rejects a scoped window whose required provider label is over-long", () => {
    const longName = "M".repeat(80); // > 64 (label cap) but <= 128 (id cap)
    const mapped = mapUsageResponse(registry.providers.claude, {
      seven_day: { utilization: 40, resets_at: "2026-07-27T07:00:00Z" },
      limits: [
        { kind: "weekly_scoped", is_active: true, scope: { model: { display_name: longName } }, percent: 33, resets_at: "2026-07-27T07:00:00Z" },
      ],
    });
    const scoped = mapped!.windows.find((w) => w.id.startsWith("weekly_scoped"));
    expect(scoped).toBeUndefined();
    expect(mapped!.incomplete).toBe(true);
  });

  it("resolves a metric unit and fails closed when required currency disappears", () => {
    const withCurrency = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: null },
      seven_day: null,
      seven_day_sonnet: null,
      seven_day_opus: null,
      extra_usage: { is_enabled: true, monthly_limit: 50, used_credits: 5, utilization: 10, currency: "EUR" },
    });
    expect(withCurrency!.metrics.find((m) => m.id === "extra_used")!.unit).toBe("EUR");

    const withoutCurrency = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: null },
      seven_day: null,
      seven_day_sonnet: null,
      seven_day_opus: null,
      extra_usage: { is_enabled: true, monthly_limit: 50, used_credits: 5, utilization: 10 },
    });
    expect(withoutCurrency!.metrics.find((m) => m.id === "extra_used")).toBeUndefined();
    expect(withoutCurrency!.incomplete).toBe(true);
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
        primary_window: { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: [
        { limit_name: "Bad", metered_feature: "bad\u001b[2J", rate_limit: {} },
        { limit_name: "Long", metered_feature: "x".repeat(129), rate_limit: {} },
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
    expect(mapped?.metrics.map((m) => m.id)).toEqual(["credits_billable"]);
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

// Mirrors WindowDriftDetectionTests in packages/VigilKit. A provider that
// declares quota windows but maps none of them from a 200 has drifted, even if
// a metric still mapped — the hole that let Claude report "Live" beside a lone
// dollar figure while every window was silently discarded.
describe("window drift detection (Swift parity)", () => {
  const registry = loadRegistry();

  it("maps a metric but zero windows for a window-declaring provider", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: "nonsense", resets_at: "not-a-date" },
      seven_day: { utilization: "nonsense", resets_at: "not-a-date" },
      extra_usage: { is_enabled: true, used_credits: 7.5, monthly_limit: 50, currency: "USD" },
    });
    // The mapper itself still returns a result; service.ts is what downgrades
    // the status to schemaChanged. Pin the precondition that makes it fire.
    expect(mapped).not.toBeNull();
    expect(mapped!.windows).toHaveLength(0);
    expect(mapped!.metrics.length).toBeGreaterThan(0);
  });

  it("a healthy Claude response still maps windows", () => {
    const mapped = mapUsageResponse(registry.providers.claude, {
      five_hour: { utilization: 12, resets_at: "2026-07-22T02:09:59.392525+00:00" },
      extra_usage: { is_enabled: true, used_credits: 0, monthly_limit: 50, currency: "USD" },
    });
    expect(mapped!.windows).toHaveLength(1);
  });

  it("metric-only providers declare no windows, so drift never applies", () => {
    expect(registry.providers.openrouter.windows ?? []).toHaveLength(0);
    expect(registry.providers.openrouter.additionalWindows ?? null).toBeNull();
  });
});

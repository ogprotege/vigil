import { describe, expect, it } from "vitest";
import { classifyUsageBody } from "../src/service.js";
import { loadRegistry, type ProviderId } from "../src/spec/registry.js";
import { loadFixture } from "./helpers.js";

const registry = loadRegistry();

const canonicalBodies: Array<[ProviderId, string]> = [
  ["claude", "claude-usage-spend-canonical.json"],
  ["codex", "codex-usage-ok.json"],
  ["openrouter", "openrouter-usage-ok.json"],
  ["deepseek", "deepseek-balance-ok.json"],
  ["moonshot", "moonshot-balance-ok.json"],
  ["moonshot_cn", "moonshot_cn-balance-debt.json"],
  ["minimax", "minimax-usage-ok.json"],
  ["minimax_cn", "minimax_cn-usage-exhausted.json"],
  ["openai", "openai-costs-ok.json"],
  ["github", "github-billing-ok.json"],
  ["xai", "xai-balance-ok.json"],
  ["zai", "zai-quota-ok.json"],
  ["cursor", "cursor-usage-ok.json"],
  ["kimi_code", "kimi_code-usage-ok.json"],
];

describe("canonical HTTP 200 provider classification", () => {
  it("covers every registry provider exactly once", () => {
    expect(new Set(canonicalBodies.map(([providerId]) => providerId)))
      .toEqual(new Set(Object.keys(registry.providers)));
  });

  it.each(canonicalBodies)("classifies %s canonical fixture as ok", (providerId, fixture) => {
    const result = classifyUsageBody(registry.providers[providerId], loadFixture(fixture));
    expect(result.status).toBe("ok");
    expect(result.windows.length + result.metrics.length).toBeGreaterThan(0);
  });

  it("fails closed on OpenAI pagination and unsafe aggregate subsets", () => {
    const canonical = loadFixture("openai-costs-ok.json") as Record<string, unknown>;
    const paginated = { ...canonical, has_more: true };
    const paginatedResult = classifyUsageBody(registry.providers.openai, paginated);
    expect(paginatedResult.status).toBe("schemaChanged");
    expect(paginatedResult.metrics.find((metric) => metric.id === "spend_month")?.value).toBe(15);

    const missingPaginationFlag = { ...canonical };
    delete missingPaginationFlag.has_more;
    expect(classifyUsageBody(registry.providers.openai, missingPaginationFlag).status)
      .toBe("schemaChanged");

    const nonnumeric = {
      ...canonical,
      data: [
        { results: [{ amount: { value: 10 } }, { amount: { value: "changed" } }] },
      ],
      has_more: false,
    };
    const nonnumericResult = classifyUsageBody(registry.providers.openai, nonnumeric);
    expect(nonnumericResult.status).toBe("schemaChanged");
    expect(nonnumericResult.metrics.find((metric) => metric.id === "spend_month")).toBeUndefined();

    const truncated = {
      ...canonical,
      data: Array.from({ length: 129 }, () => ({ results: [{ amount: { value: 1 } }] })),
      has_more: false,
    };
    const truncatedResult = classifyUsageBody(registry.providers.openai, truncated);
    expect(truncatedResult.status).toBe("schemaChanged");
    expect(truncatedResult.metrics.find((metric) => metric.id === "spend_month")).toBeUndefined();

    const nestedTruncation = {
      ...canonical,
      data: [{
        results: Array.from({ length: 129 }, () => ({ amount: { value: 1 } })),
      }],
      has_more: false,
    };
    const nestedResult = classifyUsageBody(registry.providers.openai, nestedTruncation);
    expect(nestedResult.status).toBe("schemaChanged");
    expect(nestedResult.metrics.find((metric) => metric.id === "spend_month")).toBeUndefined();
  });

  it("fails closed when paired money fields or currency metadata are partial", () => {
    const partialOpenRouter = loadFixture("openrouter-usage-ok.json") as {
      data: Record<string, unknown>;
    };
    delete partialOpenRouter.data.limit_remaining;
    const openRouterResult = classifyUsageBody(registry.providers.openrouter, partialOpenRouter);
    expect(openRouterResult.status).toBe("schemaChanged");
    expect(openRouterResult.metrics.find((metric) => metric.id === "limit")).toBeUndefined();
    expect(openRouterResult.metrics.find((metric) => metric.id === "remaining")).toBeUndefined();

    const claude = loadFixture("claude-usage-spend-canonical.json") as {
      spend: { used: Record<string, unknown> };
    };
    claude.spend.used.currency = "USD\u001b";
    const claudeResult = classifyUsageBody(registry.providers.claude, claude);
    expect(claudeResult.status).toBe("schemaChanged");
    expect(claudeResult.metrics.find((metric) => metric.id === "extra_used")).toBeUndefined();
    expect(claudeResult.metrics.find((metric) => metric.id === "extra_limit")).toBeUndefined();
  });

  it("fails closed when provider-required families disappear behind a valid subset", () => {
    const openRouter = loadFixture("openrouter-usage-ok.json") as {
      data: Record<string, unknown>;
    };
    delete openRouter.data.byok_usage_monthly;
    delete openRouter.data.limit_reset;
    expect(classifyUsageBody(registry.providers.openrouter, openRouter).status)
      .toBe("schemaChanged");

    const codex = loadFixture("codex-usage-ok.json") as Record<string, unknown>;
    delete codex.plan_type;
    expect(classifyUsageBody(registry.providers.codex, codex).status).toBe("schemaChanged");

    const moonshot = loadFixture("moonshot-balance-ok.json") as {
      data: Record<string, unknown>;
    };
    delete moonshot.data.cash_balance;
    expect(classifyUsageBody(registry.providers.moonshot, moonshot).status)
      .toBe("schemaChanged");

    const moonshotStatus = loadFixture("moonshot-balance-ok.json") as Record<string, unknown>;
    moonshotStatus.scode = "changed";
    expect(classifyUsageBody(registry.providers.moonshot, moonshotStatus).status)
      .toBe("schemaChanged");

    const zai = loadFixture("zai-quota-ok.json") as {
      data: { limits: Array<Record<string, unknown>> };
    };
    const timeLimit = zai.data.limits.find((entry) => entry.type === "TIME_LIMIT")!;
    delete timeLimit.currentValue;
    delete timeLimit.usage;
    delete timeLimit.remaining;
    const zaiResult = classifyUsageBody(registry.providers.zai, zai);
    expect(zaiResult.status).toBe("schemaChanged");
    expect(zaiResult.windows.map((window) => window.id)).toEqual(["session", "weekly"]);

    const cursor = loadFixture("cursor-usage-ok.json") as {
      individualUsage: Record<string, unknown>;
    };
    cursor.individualUsage.onDemand = { enabled: true, limit: 10_000 };
    expect(classifyUsageBody(registry.providers.cursor, cursor).status)
      .toBe("schemaChanged");

    cursor.individualUsage.onDemand = { enabled: false };
    expect(classifyUsageBody(registry.providers.cursor, cursor).status).toBe("ok");

    cursor.individualUsage.onDemand = { used: 500, limit: 1_000 };
    expect(classifyUsageBody(registry.providers.cursor, cursor).status)
      .toBe("schemaChanged");

    const disabledSpend = loadFixture("claude-usage-spend-canonical.json") as {
      spend: Record<string, unknown>;
    };
    disabledSpend.spend.enabled = false;
    const disabledSpendResult = classifyUsageBody(registry.providers.claude, disabledSpend);
    expect(disabledSpendResult.status).toBe("ok");
    expect(disabledSpendResult.metrics).toEqual([]);

    for (const enabled of [undefined, "true", 1]) {
      const claude = loadFixture("claude-usage-spend-canonical.json") as {
        spend: Record<string, unknown>;
      };
      if (enabled === undefined) delete claude.spend.enabled;
      else claude.spend.enabled = enabled;
      expect(classifyUsageBody(registry.providers.claude, claude).status)
        .toBe("schemaChanged");
    }
  });

  it("validates optional MiniMax status enums when present", () => {
    const cases: Array<["minimax" | "minimax_cn", string, "model_remains" | "data"]> = [
      ["minimax", "minimax-usage-ok.json", "model_remains"],
      ["minimax_cn", "minimax_cn-usage-exhausted.json", "data"],
    ];
    for (const [providerId, fixture, wrapper] of cases) {
      const withoutStatus = loadFixture(fixture) as Record<string, unknown>;
      const root = wrapper === "data"
        ? (withoutStatus.data as { model_remains: Array<Record<string, unknown>> })
        : (withoutStatus as { model_remains: Array<Record<string, unknown>> });
      for (const entry of root.model_remains) {
        delete entry.current_interval_status;
        delete entry.current_weekly_status;
      }
      expect(classifyUsageBody(registry.providers[providerId], withoutStatus).status).toBe("ok");

      for (const field of ["current_interval_status", "current_weekly_status"] as const) {
        for (const malformed of ["3", true, {}, 1.5, 4]) {
          const body = loadFixture(fixture) as Record<string, unknown>;
          const payload = wrapper === "data"
            ? (body.data as { model_remains: Array<Record<string, unknown>> })
            : (body as { model_remains: Array<Record<string, unknown>> });
          payload.model_remains[0]![field] = malformed;
          expect(
            classifyUsageBody(registry.providers[providerId], body).status,
            `${providerId} ${field}=${JSON.stringify(malformed)}`
          ).toBe("schemaChanged");
        }
      }
    }
  });

  it("fails closed on a malformed present optional scalar metric", () => {
    const body = loadFixture("openrouter-usage-ok.json") as {
      data: Record<string, unknown>;
    };
    body.data.byok_usage_daily = "changed";
    const result = classifyUsageBody(registry.providers.openrouter, body);
    expect(result.status).toBe("schemaChanged");
    expect(result.metrics.find((metric) => metric.id === "byok_usage_daily")).toBeUndefined();
    expect(result.metrics.find((metric) => metric.id === "usage_monthly")).toBeDefined();
  });

  it("fails closed on a present static window with the wrong container", () => {
    const result = classifyUsageBody(registry.providers.claude, {
      five_hour: "changed-wrapper",
      seven_day: { utilization: 12, resets_at: "2026-07-20T07:00:00Z" },
    });
    expect(result.status).toBe("schemaChanged");
    expect(result.windows.map((window) => window.id)).toEqual(["weekly"]);
  });

  it("requires Internet-date-time resets instead of JavaScript date guesses", () => {
    for (const reset of [
      "0",
      "1582-10-10T00:00:00Z",
      "2100-01-01T00:00:00Z",
      "2026-01-01T24:00:00.1Z",
      "2026-01-01T00:00:00.1234567890Z",
      "2026-01-01T00:00:00+14:01",
      "2026-07-22T17:00:00+24:00",
    ]) {
      const result = classifyUsageBody(registry.providers.claude, {
        five_hour: { utilization: 12, resets_at: reset },
        seven_day: { utilization: 34, resets_at: "2026-07-27T17:00:00Z" },
      });
      expect(result.status).toBe("schemaChanged");
      expect(result.windows.map((window) => window.id)).toEqual(["weekly"]);
    }
  });

  it("accepts only decimal string numbers in metrics and lenient windows", () => {
    for (const encoded of ["0b10", "0o10", "0x10", "\uFEFF1", "\u00A01", "1\u00A0"]) {
      const balance = classifyUsageBody(registry.providers.deepseek, {
        balance_infos: [{ currency: "USD", total_balance: encoded }],
      });
      expect(balance.status).toBe("schemaChanged");
      expect(balance.metrics).toEqual([]);

      const kimi = loadFixture("kimi_code-usage-ok.json") as {
        limits: Array<{ detail: Record<string, unknown> }>;
      };
      kimi.limits[0]!.detail.used = encoded;
      const usage = classifyUsageBody(registry.providers.kimi_code, kimi);
      expect(usage.status).toBe("schemaChanged");
      expect(usage.windows.map((window) => window.id)).toEqual(["weekly"]);
    }
  });

  it("fails closed on a Codex lane with an unknown duration identity", () => {
    const result = classifyUsageBody(registry.providers.codex, {
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
    });
    expect(result.status).toBe("schemaChanged");
    expect(result.windows.map((window) => window.id)).toEqual(["session"]);
  });

  it("fails closed on duplicate static identities and mixed dynamic garbage", () => {
    const primary = { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 };
    const duplicateStatic = classifyUsageBody(registry.providers.codex, {
      rate_limit: { primary_window: primary, secondary_window: primary },
    });
    expect(duplicateStatic.status).toBe("schemaChanged");
    expect(duplicateStatic.windows.map((window) => window.id)).toEqual(["session"]);

    const mixedDynamic = classifyUsageBody(registry.providers.codex, {
      rate_limit: { primary_window: primary },
      additional_rate_limits: [
        {
          limit_name: "Valid model",
          metered_feature: "valid_model",
          rate_limit: { primary_window: primary },
        },
        "changed-entry",
      ],
    });
    expect(mixedDynamic.status).toBe("schemaChanged");
    expect(mixedDynamic.windows.map((window) => window.id)).toEqual([
      "session",
      "valid_model_session",
    ]);
  });

  it("fails closed on blank or colliding dynamic window identifiers", () => {
    const primary = { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 };
    const blank = classifyUsageBody(registry.providers.codex, {
      rate_limit: { primary_window: primary },
      additional_rate_limits: [{
        limit_name: "Blank",
        metered_feature: "   ",
        rate_limit: { primary_window: primary },
      }],
    });
    expect(blank.status).toBe("schemaChanged");
    expect(blank.windows.map((window) => window.id)).toEqual(["session"]);

    const duplicate = classifyUsageBody(registry.providers.codex, {
      rate_limit: { primary_window: primary },
      additional_rate_limits: [0, 1].map(() => ({
        limit_name: "Duplicate",
        metered_feature: "duplicate",
        rate_limit: { primary_window: primary },
      })),
    });
    expect(duplicate.status).toBe("schemaChanged");
    expect(duplicate.windows.map((window) => window.id)).toEqual(["session", "duplicate_session"]);
  });

  it("fails closed when dynamic model labels disappear or prefixed ids collapse", () => {
    const primary = { used_percent: 10, reset_at: 1784408400, limit_window_seconds: 18000 };
    for (const limitName of [undefined, "   "]) {
      const lane: Record<string, unknown> = {
        metered_feature: "model_without_label",
        rate_limit: { primary_window: primary },
      };
      if (limitName !== undefined) lane.limit_name = limitName;
      const result = classifyUsageBody(registry.providers.codex, {
        rate_limit: { primary_window: primary },
        additional_rate_limits: [lane],
      });
      expect(result.status).toBe("schemaChanged");
      expect(result.windows.map((window) => window.id)).toEqual(["session"]);
    }

    const collapsed = classifyUsageBody(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: "2026-07-22T17:00:00Z" },
      limits: [{
        kind: "weekly_scoped",
        is_active: true,
        percent: 20,
        resets_at: "2026-07-27T17:00:00Z",
        scope: { model: { display_name: "---" } },
      }],
    });
    expect(collapsed.status).toBe("schemaChanged");
    expect(collapsed.windows.map((window) => window.id)).toEqual(["session"]);

    const missingCondition = classifyUsageBody(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: "2026-07-22T17:00:00Z" },
      limits: [{
        kind: "weekly_scoped",
        percent: 20,
        resets_at: "2026-07-27T17:00:00Z",
        scope: { model: { display_name: "Fable" } },
      }],
    });
    expect(missingCondition.status).toBe("schemaChanged");
    expect(missingCondition.windows.map((window) => window.id)).toEqual(["session"]);

    const missingFilter = classifyUsageBody(registry.providers.claude, {
      five_hour: { utilization: 10, resets_at: "2026-07-22T17:00:00Z" },
      limits: [{
        is_active: true,
        percent: 20,
        resets_at: "2026-07-27T17:00:00Z",
        scope: { model: { display_name: "Fable" } },
      }],
    });
    expect(missingFilter.status).toBe("schemaChanged");
    expect(missingFilter.windows.map((window) => window.id)).toEqual(["session"]);
  });

  it("normalizes Unicode dynamic ids identically to Swift", () => {
    for (const [displayName, expectedId] of [
      ["A😀B", "weekly_scoped_a_b"],
      ["K", "weekly_scoped_k"],
      ["İ", "weekly_scoped_i_"],
    ]) {
      const result = classifyUsageBody(registry.providers.claude, {
        five_hour: { utilization: 10, resets_at: "2026-07-22T17:00:00Z" },
        seven_day: null,
        seven_day_sonnet: null,
        seven_day_opus: null,
        limits: [{
          kind: "weekly_scoped",
          is_active: true,
          percent: 20,
          resets_at: "2026-07-27T17:00:00Z",
          scope: { model: { display_name: displayName } },
        }],
      });
      expect(result.status).toBe("ok");
      expect(result.windows.map((window) => window.id)).toEqual(["session", expectedId]);
    }
  });

  it("uses Cursor fallback candidates without masking malformed data", () => {
    const ratioOnly = classifyUsageBody(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      membershipType: "pro",
      individualUsage: { plan: { used: 25, limit: 100 } },
    });
    expect(ratioOnly.status).toBe("ok");
    expect(ratioOnly.windows.map((window) => window.id)).toEqual(["plan"]);
    expect(ratioOnly.windows[0]!.utilization).toBe(25);

    const malformedPreferred = classifyUsageBody(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      individualUsage: { plan: { totalPercentUsed: "changed", used: 25, limit: 100 } },
    });
    expect(malformedPreferred.status).toBe("schemaChanged");
    expect(malformedPreferred.windows[0]!.utilization).toBe(25);

    const resolvedPreferred = classifyUsageBody(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      individualUsage: { plan: { totalPercentUsed: 10, used: "stale", limit: 100 } },
    });
    expect(resolvedPreferred.status).toBe("ok");
    expect(resolvedPreferred.windows[0]!.utilization).toBe(10);

    const unlimited = classifyUsageBody(registry.providers.cursor, {
      billingCycleEnd: "2026-05-11T00:00:00.000Z",
      membershipType: "pro",
      individualUsage: {
        plan: { totalPercentUsed: 10 },
        onDemand: { enabled: true, used: 500, limit: 0 },
      },
      teamUsage: {},
    });
    expect(unlimited.status).toBe("ok");
    expect(unlimited.metrics.map((metric) => [metric.id, metric.value])).toEqual([
      ["spend_ondemand", 5],
    ]);
  });

  it("fails closed on malformed or colliding metric-collection entries", () => {
    const result = classifyUsageBody(registry.providers.deepseek, {
      balance_infos: [
        { currency: "USD", total_balance: "10" },
        "garbage",
        { currency: "EUR" },
        { currency: "US-D", total_balance: "1" },
        { currency: "US_D", total_balance: "2" },
      ],
    });
    expect(result.status).toBe("schemaChanged");
    expect(result.metrics.map((metric) => [metric.id, metric.value])).toEqual([
      ["balance_usd", 10],
      ["balance_us_d", 1],
    ]);
  });

  it("marks every provider-controlled fan-out over 128 entries incomplete", () => {
    const codex = {
      rate_limit: {
        primary_window: { used_percent: 1, reset_at: 1784408400, limit_window_seconds: 18000 },
      },
      additional_rate_limits: Array.from({ length: 129 }, (_, index) => ({
        limit_name: `Lane ${index}`,
        metered_feature: `lane_${index}`,
        rate_limit: {
          primary_window: { used_percent: 1, reset_at: 1784408400, limit_window_seconds: 18000 },
        },
      })),
    };
    expect(classifyUsageBody(registry.providers.codex, codex).status).toBe("schemaChanged");

    const deepSeek = {
      balance_infos: Array.from({ length: 129 }, (_, index) => ({
        currency: `U${index}`,
        total_balance: "1",
      })),
    };
    expect(classifyUsageBody(registry.providers.deepseek, deepSeek).status).toBe("schemaChanged");

    const limits = [
      { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 1, nextResetTime: 1782724971179 },
      { type: "TOKENS_LIMIT", unit: 6, number: 1, percentage: 2, nextResetTime: 1782724971179 },
      ...Array.from({ length: 127 }, () => ({
        type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 3, nextResetTime: 1782724971179,
      })),
    ];
    const zai = { code: 200, success: true, data: { limits } };
    expect(classifyUsageBody(registry.providers.zai, zai).status).toBe("schemaChanged");
  });

  it("fails closed on mixed valid and malformed static-array entries", () => {
    const body = {
      code: 200,
      success: true,
      data: {
        limits: [
          { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 1, nextResetTime: 1782724971179 },
          { type: "TOKENS_LIMIT", unit: 6, number: 1, percentage: 2, nextResetTime: 1782724971179 },
          "changed-entry",
        ],
      },
    };
    const result = classifyUsageBody(registry.providers.zai, body);
    expect(result.status).toBe("schemaChanged");
    expect(result.windows.map((window) => window.id)).toEqual(["session", "weekly"]);
  });
});

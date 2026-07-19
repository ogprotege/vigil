import { describe, expect, it } from "vitest";
import { renderSnapshot } from "../src/commands/status.js";
import type { ProviderSnapshot } from "../src/providers/types.js";
import { sanitizeTerminalText } from "../src/util/terminal.js";

describe("terminal output safety", () => {
  it("strips ANSI, OSC, C0, and C1 controls and bounds untrusted fields", () => {
    const malicious =
      "\u001b[2Jvisible\u001b]52;c;Y2xpcGJvYXJk\u0007\ntext\u009b31mred";
    expect(sanitizeTerminalText(malicious)).toBe("visibletextred");
    expect(sanitizeTerminalText("abcdef", 4)).toBe("abc…");
  });

  it("sanitizes provider response labels before rendering", () => {
    const snapshot: ProviderSnapshot = {
      providerId: "fixture",
      accountLabel: null,
      planLabel: "pro\u001b[2J",
      fetchedAt: "2026-07-18T20:00:00Z",
      status: "ok",
      windows: [
        {
          id: "quota\u001b]0;owned\u0007",
          utilization: 25,
          resetsAt: null,
          windowSeconds: null,
          secondary: false,
        },
      ],
      metrics: [
        {
          id: "balance",
          label: "Balance\u001b[31m",
          kind: "balance",
          value: 5,
          unit: "USD\u001b[0m",
          secondary: false,
        },
      ],
    };

    const rendered = renderSnapshot(
      snapshot,
      "Provider\u001b[3J",
      new Date("2026-07-18T20:00:00Z")
    );
    expect(rendered).toContain("Provider (pro)");
    expect(rendered).toContain("quota");
    expect(rendered).toContain("Balance");
    expect(rendered).toContain("5 USD");
    expect(rendered).not.toContain("\u001b");
    expect(rendered).not.toContain("owned");
  });
});

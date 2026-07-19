import { describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";

/**
 * Absolute poll-floor tripwire.
 *
 * CLAUDE.md: "Never poll Claude faster than 5 minutes. Do not lower
 * `minSeconds` in `providers.json`." A registry edit that changes these
 * numbers must be a conscious, reviewed decision — this test exists so such
 * an edit cannot sail through CI silently in either direction.
 */
describe("poll floor tripwire (protocol/providers.json)", () => {
  const registry = loadRegistry();

  it("keeps claude's poll.minSeconds at exactly 300", () => {
    // Exactly 300, not >= 300: raising the floor changes shipped app/widget
    // behavior and hand-mirrored Swift constants, so it must also be a
    // deliberate reviewed change, not a drive-by edit.
    expect(registry.providers["claude"]?.poll.minSeconds).toBe(300);
  });

  it("keeps every provider at or above the 5-minute floor with coherent backoff", () => {
    const ids = Object.keys(registry.providers);
    expect(ids.length).toBeGreaterThan(0);
    for (const [id, spec] of Object.entries(registry.providers)) {
      expect(spec.poll.minSeconds, `${id}: poll.minSeconds must never drop below 300`).toBeGreaterThanOrEqual(300);
      expect(spec.poll.jitterSeconds, `${id}: poll.jitterSeconds must be non-negative`).toBeGreaterThanOrEqual(0);
      expect(
        spec.poll.backoff429BaseSeconds,
        `${id}: a 429 backoff shorter than the normal interval would poll a rate-limited provider faster than a healthy one`
      ).toBeGreaterThanOrEqual(spec.poll.minSeconds);
    }
  });
});

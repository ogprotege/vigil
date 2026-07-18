import { describe, expect, it } from "vitest";
import { redact, redactedMessage } from "../src/util/redact.js";
import { makeJwt } from "./helpers.js";

describe("redact", () => {
  it("scrubs Anthropic tokens", () => {
    expect(redact("failed with sk-ant-oat01-SECRETSECRET in url")).toBe("failed with [redacted] in url");
  });

  it("scrubs JWTs", () => {
    const jwt = makeJwt({ secret: true });
    expect(redact(`request ${jwt} failed`)).not.toContain(jwt.split(".")[1]);
  });

  it("scrubs bearer values", () => {
    expect(redact("Authorization: Bearer abcdef123456789")).not.toContain("abcdef123456789");
  });

  it("wraps unknown error shapes", () => {
    expect(redactedMessage(new Error("boom sk-ant-oat01-XYZXYZXYZ"))).toBe("boom [redacted]");
    expect(redactedMessage("plain sk-ant-api03-KEYKEYKEYKEY")).toBe("plain [redacted]");
  });
});

import { describe, expect, it } from "vitest";
import {
  SUPPORTED_REGISTRY_VERSION,
  parseRegistry,
} from "../src/spec/registry.js";

describe("provider registry version contract", () => {
  it("accepts exactly registry v2", () => {
    const registry = parseRegistry(JSON.stringify({
      version: SUPPORTED_REGISTRY_VERSION,
      providers: {},
    }));
    expect(registry.version).toBe(2);
  });

  it.each([1, 3, 200])("rejects unsupported registry version %s", (version) => {
    expect(() => parseRegistry(JSON.stringify({ version, providers: {} })))
      .toThrow(/unsupported; expected 2/);
  });

  it("rejects a missing or nonnumeric registry version", () => {
    expect(() => parseRegistry(JSON.stringify({ providers: {} })))
      .toThrow(/invalid registry shape/);
    expect(() => parseRegistry(JSON.stringify({ version: "2", providers: {} })))
      .toThrow(/invalid registry shape/);
  });
});

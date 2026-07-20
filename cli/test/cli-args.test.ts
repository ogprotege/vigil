import { describe, expect, it } from "vitest";
import { parseCli, selectLinkMode } from "../src/cli.js";

const deps = { version: "9.9.9", help: "HELP TEXT" };

describe("parseCli", () => {
  it("prints the version to stdout and exits 0 for --version", () => {
    const outcome = parseCli(["--version"], deps);
    expect(outcome).toEqual({ kind: "print", text: "9.9.9", stream: "stdout", exitCode: 0 });
  });

  it("accepts -V as a version alias", () => {
    const outcome = parseCli(["-V"], deps);
    expect(outcome).toEqual({ kind: "print", text: "9.9.9", stream: "stdout", exitCode: 0 });
  });

  it("prints the help text to stdout and exits 0 for --help", () => {
    const outcome = parseCli(["--help"], deps);
    expect(outcome).toEqual({ kind: "print", text: "HELP TEXT", stream: "stdout", exitCode: 0 });
  });

  it("suggests the closest option on an unknown flag typo", () => {
    const outcome = parseCli(["--lop"], deps);
    expect(outcome.kind).toBe("print");
    if (outcome.kind !== "print") throw new Error("unreachable");
    expect(outcome.stream).toBe("stderr");
    expect(outcome.exitCode).toBe(1);
    expect(outcome.text).toContain('Unknown option "--lop"');
    expect(outcome.text).toContain("Did you mean --loop?");
  });

  it("reports an unknown flag without a suggestion when nothing is close", () => {
    const outcome = parseCli(["--zzzzzz"], deps);
    expect(outcome.kind).toBe("print");
    if (outcome.kind !== "print") throw new Error("unreachable");
    expect(outcome.exitCode).toBe(1);
    expect(outcome.text).toContain('Unknown option "--zzzzzz"');
    expect(outcome.text).not.toContain("Did you mean");
    expect(outcome.text).toContain("--help");
  });

  it("reports an unknown command with the valid commands", () => {
    const outcome = parseCli(["statuss"], deps);
    expect(outcome.kind).toBe("print");
    if (outcome.kind !== "print") throw new Error("unreachable");
    expect(outcome.exitCode).toBe(1);
    expect(outcome.text).toContain('Unknown command "statuss"');
    expect(outcome.text).toContain("status");
  });

  it("defaults to the link command with no arguments", () => {
    const outcome = parseCli([], deps);
    expect(outcome.kind).toBe("invoke");
    if (outcome.kind !== "invoke") throw new Error("unreachable");
    expect(outcome.invocation.command).toBe("link");
    expect(outcome.invocation.classicFlagUsed).toBe(false);
  });

  it("parses the status command", () => {
    const outcome = parseCli(["status"], deps);
    expect(outcome.kind).toBe("invoke");
    if (outcome.kind !== "invoke") throw new Error("unreachable");
    expect(outcome.invocation.command).toBe("status");
  });

  it("treats --provider as a classic-mode flag and captures its value", () => {
    const outcome = parseCli(["--provider", "claude,codex"], deps);
    if (outcome.kind !== "invoke") throw new Error("unreachable");
    expect(outcome.invocation.provider).toBe("claude,codex");
    expect(outcome.invocation.classicFlagUsed).toBe(true);
  });

  it("treats --json as a classic-mode flag", () => {
    const outcome = parseCli(["--json", "--yes"], deps);
    if (outcome.kind !== "invoke") throw new Error("unreachable");
    expect(outcome.invocation.flags.json).toBe(true);
    expect(outcome.invocation.flags.yes).toBe(true);
    expect(outcome.invocation.classicFlagUsed).toBe(true);
  });

  it("does not treat --big/--no-clear/--no-verify as classic-mode flags", () => {
    const outcome = parseCli(["--big", "--no-clear", "--no-verify"], deps);
    if (outcome.kind !== "invoke") throw new Error("unreachable");
    expect(outcome.invocation.flags.big).toBe(true);
    expect(outcome.invocation.flags.noClear).toBe(true);
    expect(outcome.invocation.flags.noVerify).toBe(true);
    expect(outcome.invocation.classicFlagUsed).toBe(false);
  });
});

describe("selectLinkMode", () => {
  it("chooses the wizard when interactive and no classic flag was used", () => {
    expect(selectLinkMode({ classicFlagUsed: false, stdinTTY: true, stdoutTTY: true })).toBe("wizard");
  });

  it("falls back to classic when a classic flag was used", () => {
    expect(selectLinkMode({ classicFlagUsed: true, stdinTTY: true, stdoutTTY: true })).toBe("classic");
  });

  it("falls back to classic when stdin is not a TTY", () => {
    expect(selectLinkMode({ classicFlagUsed: false, stdinTTY: false, stdoutTTY: true })).toBe("classic");
  });

  it("falls back to classic when stdout is not a TTY", () => {
    expect(selectLinkMode({ classicFlagUsed: false, stdinTTY: true, stdoutTTY: false })).toBe("classic");
  });
});

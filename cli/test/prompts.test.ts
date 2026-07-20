import { afterEach, describe, expect, it } from "vitest";
import { PassThrough } from "node:stream";
import { InputManager, type PromptIO } from "../src/ui/prompts.js";

interface Harness {
  manager: InputManager;
  input: PassThrough;
  output: string[];
  interrupts: number;
}

let active: Harness | null = null;

function harness(overrides: Partial<PromptIO> = {}): Harness {
  const input = new PassThrough();
  const output: string[] = [];
  let interrupts = 0;
  const io: PromptIO = {
    input,
    write: (text) => output.push(text),
    onInterrupt: () => {
      interrupts += 1;
    },
    ...overrides,
  };
  const manager = new InputManager(io);
  active = { manager, input, output, interrupts: 0 };
  // Keep the counter live via a getter-ish snapshot on read.
  Object.defineProperty(active, "interrupts", { get: () => interrupts });
  return active;
}

afterEach(() => {
  active?.manager.close();
  active?.input.end();
  active = null;
});

describe("confirmStrict", () => {
  it("returns true for y", async () => {
    const h = harness();
    h.input.write("y\n");
    expect(await h.manager.confirmStrict("Show the codes?")).toBe(true);
  });

  it("returns false for n", async () => {
    const h = harness();
    h.input.write("n\n");
    expect(await h.manager.confirmStrict("Show the codes?")).toBe(false);
  });

  it("re-prompts on an empty line instead of accepting a bare Enter", async () => {
    const h = harness();
    h.input.write("\n");
    h.input.write("y\n");
    const result = await h.manager.confirmStrict("Show the codes?");
    expect(result).toBe(true);
    expect(h.output.join("")).toContain("Please type y or n");
  });

  it("defaults to false (never reveal) after too many blank lines", async () => {
    const h = harness();
    h.input.write("\n\n\n\n");
    expect(await h.manager.confirmStrict("Show the codes?")).toBe(false);
  });
});

describe("multiToggle", () => {
  it("toggles the named item and returns the selection on Enter", async () => {
    const h = harness();
    h.input.write("2\n");
    h.input.write("\n");
    const result = await h.manager.multiToggle("Pick accounts", [
      { label: "Claude", selected: true },
      { label: "OpenRouter", selected: false },
    ]);
    expect(result).toEqual([true, true]);
    // Re-rendered after the toggle, so the second item appears at least twice.
    expect(h.output.join("").match(/OpenRouter/g)?.length).toBeGreaterThanOrEqual(2);
  });

  it("never toggles a disabled item", async () => {
    const h = harness();
    h.input.write("2\n");
    h.input.write("\n");
    const result = await h.manager.multiToggle("Pick accounts", [
      { label: "Claude", selected: true },
      { label: "Codex", selected: false, disabled: "run codex login first" },
    ]);
    expect(result).toEqual([true, false]);
  });
});

describe("textInput", () => {
  it("masks a secret so the key never appears in the output stream", async () => {
    const h = harness();
    h.input.write("sk-secret-123\n");
    const value = await h.manager.textInput("Paste key: ", { mask: true });
    expect(value).toBe("sk-secret-123");
    expect(h.output.join("")).not.toContain("sk-secret-123");
    expect(h.output.join("")).toContain("•");
  });

  it("returns an empty string when allowEmpty and the user just presses Enter", async () => {
    const h = harness();
    h.input.write("\n");
    expect(await h.manager.textInput("Key (Enter to skip): ", { allowEmpty: true })).toBe("");
  });
});

describe("waitAnyKey", () => {
  it("resolves as soon as a key arrives", async () => {
    const h = harness();
    h.input.write(" ");
    await h.manager.waitAnyKey("Press any key...");
    expect(h.output.join("")).toContain("Press any key...");
  });

  it("invokes the interrupt handler on Ctrl+C", async () => {
    const h = harness();
    h.input.write("\x03");
    await h.manager.waitAnyKey("Press any key...");
    expect(h.interrupts).toBe(1);
  });
});

describe("sequential prompts from one stream", () => {
  it("reads batched input token-by-token without dropping or misrouting", async () => {
    const h = harness();
    // All the answers arrive at once, as they can from a fast paste or pipe.
    h.input.write("\n2\ny\n");
    const toggled = await h.manager.multiToggle("Pick", [{ label: "A", selected: true }]);
    const choice = await h.manager.choose("Q", ["x", "y", "z"], 0);
    const confirmed = await h.manager.confirmStrict("ok?");
    expect(toggled).toEqual([true]); // bare Enter accepts the default
    expect(choice).toBe(1); // "2" -> index 1
    expect(confirmed).toBe(true); // "y"
  });
});

describe("question", () => {
  it("rejects with an AbortError when the signal fires before input", async () => {
    const h = harness();
    const controller = new AbortController();
    const pending = h.manager.question("Paste URL: ", { signal: controller.signal });
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  });

  it("returns the typed line trimmed", async () => {
    const h = harness();
    h.input.write("  https://example.com/callback  \n");
    expect(await h.manager.question("Paste URL: ")).toBe("https://example.com/callback");
  });
});

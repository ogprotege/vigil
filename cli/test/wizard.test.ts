import { afterEach, describe, expect, it } from "vitest";
import { loadRegistry } from "../src/spec/registry.js";
import {
  runWizard,
  gatherSelectedAccounts,
  type WizardPrompts,
  type ProviderScan,
} from "../src/commands/wizard.js";
import type { ToggleItem } from "../src/ui/prompts.js";
import {
  CLAUDE_CREDS_FILE,
  codexCredsFile,
  json,
  loadFixture,
  makeFakeHome,
  startFixtureServer,
  fixtureHttp,
  type FixtureServer,
} from "./helpers.js";

const registry = loadRegistry();

let server: FixtureServer | null = null;
afterEach(async () => {
  await server?.close();
  server = null;
});

class FakePrompts implements WizardPrompts {
  private choices: number[];
  private texts: string[];
  private confirmValue: boolean;
  private toggle?: (items: ToggleItem[]) => boolean[];

  constructor(opts: {
    choices?: number[];
    texts?: string[];
    confirm?: boolean;
    toggle?: (items: ToggleItem[]) => boolean[];
  }) {
    this.choices = opts.choices ?? [];
    this.texts = opts.texts ?? [];
    this.confirmValue = opts.confirm ?? true;
    this.toggle = opts.toggle;
  }

  async confirmStrict(): Promise<boolean> {
    return this.confirmValue;
  }
  async choose(_title: string, _options: string[], defaultIndex: number): Promise<number> {
    return this.choices.length > 0 ? this.choices.shift()! : defaultIndex;
  }
  async multiToggle(_title: string, items: ToggleItem[]): Promise<boolean[]> {
    return this.toggle ? this.toggle(items) : items.map((item) => item.selected);
  }
  async textInput(_label: string, opts?: { mask?: boolean; allowEmpty?: boolean }): Promise<string> {
    if (this.texts.length > 0) return this.texts.shift()!;
    return opts?.allowEmpty ? "" : "";
  }
  async waitKey(): Promise<void> {}
}

function selectByLabel(...needles: string[]): (items: ToggleItem[]) => boolean[] {
  return (items) => items.map((item) => needles.some((n) => item.label.includes(n)));
}

describe("runWizard", () => {
  it("links found Claude (copied) and Codex accounts by accepting defaults", async () => {
    server = await startFixtureServer({
      "/api/oauth/usage": json(200, loadFixture("claude-usage-ok.json")),
      "/backend-api/wham/usage": json(200, loadFixture("codex-usage-ok.json")),
    });
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE, codex: codexCredsFile() });

    const out: string[] = [];
    const err: string[] = [];
    const code = await runWizard({
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      http: fixtureHttp(server.url),
      now: () => new Date("2026-07-18T20:01:00Z"),
      big: false,
      clear: false,
      verify: true,
      columns: 400,
      out: (t) => out.push(t),
      err: (t) => err.push(t),
      sid: "ABCD",
      // Accept the default selection (both found accounts), choose "copy" for
      // Claude (index 1), consent yes.
      prompts: new FakePrompts({ choices: [1], confirm: true }),
    });

    expect(code).toBe(0);
    expect(err.join("\n")).toContain("Found 2 of 14");
    expect(err.join("\n")).toContain("✓ Claude: verified");
    expect(err.join("\n")).toContain("✓ ChatGPT / Codex: verified");
    // The interactive path renders scannable QR art (not the raw vigil1 lines).
    expect(out.join("")).toContain("Vigil link — code 1 of");
  });

  it("gathers a manually typed API key as a non-refreshable manual credential", async () => {
    const scan: ProviderScan = {
      id: "openrouter",
      spec: registry.providers.openrouter!,
      discovery: { credentials: null, location: null, checkedLocations: [] },
    };
    const gathered = await gatherSelectedAccounts([scan], {
      registry,
      big: false,
      clear: false,
      verify: false,
      out: () => {},
      err: () => {},
      prompts: new FakePrompts({ texts: ["sk-or-manual-key"] }),
    });
    expect(gathered).toHaveLength(1);
    expect(gathered[0]!.providerId).toBe("openrouter");
    expect(gathered[0]!.accessToken).toBe("sk-or-manual-key");
    // "manual" is not "mint", so buildPayload never marks it refreshable.
    expect(gathered[0]!.source).toBe("manual");
  });

  it("skips a missing provider when the user presses Enter past the key prompt", async () => {
    const scan: ProviderScan = {
      id: "openrouter",
      spec: registry.providers.openrouter!,
      discovery: { credentials: null, location: null, checkedLocations: [] },
    };
    const gathered = await gatherSelectedAccounts([scan], {
      registry,
      big: false,
      clear: false,
      verify: false,
      out: () => {},
      err: () => {},
      prompts: new FakePrompts({ texts: [""] }),
    });
    expect(gathered).toHaveLength(0);
  });

  it("runs the full manual-key path end to end and renders a QR", async () => {
    const { homeDir } = await makeFakeHome({});
    const out: string[] = [];
    const code = await runWizard({
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      now: () => new Date("2026-07-18T20:01:00Z"),
      big: false,
      clear: false,
      verify: false,
      columns: 400,
      out: (t) => out.push(t),
      err: () => {},
      sid: "ABCD",
      prompts: new FakePrompts({
        toggle: selectByLabel("OpenRouter"),
        texts: ["sk-or-manual-key"],
        confirm: true,
      }),
    });
    expect(code).toBe(0);
    expect(out.join("")).toContain("Vigil link — code 1 of");
  });

  it("shows nothing when the user declines the credential-display consent", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const out: string[] = [];
    const code = await runWizard({
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      now: () => new Date("2026-07-18T20:01:00Z"),
      big: false,
      clear: false,
      verify: false,
      columns: 400,
      out: (t) => out.push(t),
      err: () => {},
      sid: "ABCD",
      prompts: new FakePrompts({ choices: [1], confirm: false }),
    });

    expect(code).toBe(1);
    expect(out.join("")).not.toContain("vigil1:");
  });

  it("stops with guidance when the user selects nothing", async () => {
    const { homeDir } = await makeFakeHome({ claude: CLAUDE_CREDS_FILE });
    const err: string[] = [];
    const code = await runWizard({
      registry,
      discovery: { homeDir, platform: "linux", env: {} },
      now: () => new Date("2026-07-18T20:01:00Z"),
      big: false,
      clear: false,
      verify: false,
      columns: 400,
      out: () => {},
      err: (t) => err.push(t),
      sid: "ABCD",
      prompts: new FakePrompts({ toggle: () => [], confirm: true }),
    });

    expect(code).toBe(1);
    expect(err.join("\n")).toContain("Nothing selected");
  });
});

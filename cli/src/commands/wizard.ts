import type { ProviderId, ProviderSpec, Registry } from "../spec/registry.js";
import { providerIds } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import { discoverProvider, type DiscoveryResult } from "../discovery/index.js";
import type { HttpOptions } from "../http.js";
import type { PollGateOptions } from "../polling.js";
import type { Credentials } from "../providers/types.js";
import { hasMintAdapter, mintProvider } from "../oauth/index.js";
import type { MintOptions } from "../oauth/claudeMint.js";
import type { ToggleItem } from "../ui/prompts.js";
import { emitLink } from "./link.js";
import { redactedMessage } from "../util/redact.js";
import { sanitizeTerminalText } from "../util/terminal.js";

/** The interactive surface the wizard needs; InputManager satisfies it. */
export interface WizardPrompts {
  confirmStrict(question: string): Promise<boolean>;
  choose(title: string, options: string[], defaultIndex: number): Promise<number>;
  multiToggle(title: string, items: ToggleItem[]): Promise<boolean[]>;
  textInput(label: string, opts?: { mask?: boolean; allowEmpty?: boolean }): Promise<string>;
  waitKey(): Promise<void>;
}

export interface WizardOptions {
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  poll?: PollGateOptions | false;
  mint?: MintOptions;
  now?: () => Date;
  big: boolean;
  clear: boolean;
  verify: boolean;
  columns?: number;
  out: (text: string) => void;
  err: (text: string) => void;
  prompts: WizardPrompts;
  sleep?: (ms: number) => Promise<void>;
  sid?: string;
}

export interface ProviderScan {
  id: ProviderId;
  spec: ProviderSpec;
  discovery: DiscoveryResult;
}

function accountIdLabel(id: ProviderId): string {
  if (id === "github") return "GitHub username";
  if (id === "xai") return "xAI team ID";
  return "Account ID";
}

/** Human note for a discovered credential's source (never a credential value). */
function foundLabel(scan: ProviderScan): string {
  const creds = scan.discovery.credentials;
  const plan = creds?.plan ? ` (${sanitizeTerminalText(creds.plan)})` : "";
  const where =
    scan.discovery.location === "keychain"
      ? "macOS Keychain sign-in"
      : scan.id === "claude"
        ? "Claude Code sign-in"
        : scan.id === "codex"
          ? "Codex CLI sign-in"
          : scan.discovery.location ?? "found";
  return `${sanitizeTerminalText(where)}${plan}`;
}

/** How a not-found provider could be added, or null if it can't from the CLI. */
function missingHint(scan: ProviderScan): { addable: boolean; note: string } {
  if (hasMintAdapter(scan.id, scan.spec)) {
    return { addable: true, note: "sign in with your browser" };
  }
  const env = scan.spec.discovery.environment;
  if (env?.accessToken) {
    const extra = env.accountId ? ` + ${env.accountId}` : "";
    return { addable: true, note: `enter an API key now (env ${env.accessToken}${extra})` };
  }
  if (scan.spec.discovery.adapter === "codex" || scan.id === "codex") {
    return { addable: false, note: "not signed in — run `codex login`, then re-run" };
  }
  return { addable: false, note: "can't be added from the CLI" };
}

async function scanProviders(opts: WizardOptions): Promise<ProviderScan[]> {
  const ids = providerIds(opts.registry, true);
  return Promise.all(
    ids.map(async (id): Promise<ProviderScan> => {
      const spec = opts.registry.providers[id]!;
      let discovery: DiscoveryResult;
      try {
        discovery = await discoverProvider(id, spec, opts.discovery);
      } catch {
        discovery = { credentials: null, location: null, checkedLocations: [] };
      }
      return { id, spec, discovery };
    })
  );
}

async function mintOne(scan: ProviderScan, opts: WizardOptions): Promise<Credentials | null> {
  try {
    opts.err(`Opening your browser to authorize Vigil with ${scan.spec.displayName}...`);
    return await mintProvider(scan.id, scan.spec, opts.mint);
  } catch (error) {
    opts.err(
      `Couldn't sign in to ${scan.spec.displayName} ` +
        `(${sanitizeTerminalText(redactedMessage(error))}).`
    );
    return null;
  }
}

async function promptForKey(scan: ProviderScan, opts: WizardOptions): Promise<Credentials | null> {
  const env = scan.spec.discovery.environment;
  if (!env?.accessToken) return null;
  opts.err(`\n${scan.spec.displayName} — API key`);
  if (scan.spec.manualEntryHint) opts.err(`  ${sanitizeTerminalText(scan.spec.manualEntryHint)}`);
  const key = await opts.prompts.textInput("  Paste key (hidden; press Enter to skip): ", {
    mask: true,
    allowEmpty: true,
  });
  if (!key) {
    opts.err(`  Skipped ${scan.spec.displayName}.`);
    return null;
  }
  let accountId: string | undefined;
  if (env.accountId) {
    const value = await opts.prompts.textInput(`  ${accountIdLabel(scan.id)}: `, { allowEmpty: true });
    accountId = value || undefined;
  }
  return {
    providerId: scan.id,
    accessToken: key,
    ...(accountId ? { accountId } : {}),
    label: scan.spec.displayName,
    source: "manual",
  };
}

/** Resolve the credentials for one selected provider (discovered, minted, or
 * manually typed). Returns null when the user skips or a step fails. */
async function gatherOne(scan: ProviderScan, opts: WizardOptions): Promise<Credentials | null> {
  const mintable = hasMintAdapter(scan.id, scan.spec);
  if (scan.discovery.credentials) {
    if (mintable) {
      const choice = await opts.prompts.choose(
        `How should Vigil connect to ${scan.spec.displayName}?`,
        [
          "Browser sign-in (recommended). Vigil refreshes its token while the provider permits",
          `Copy the ${scan.spec.displayName} sign-in — no browser, but it can't renew and will expire`,
        ],
        0
      );
      if (choice === 0) {
        const minted = await mintOne(scan, opts);
        return minted ?? scan.discovery.credentials;
      }
      return scan.discovery.credentials;
    }
    return scan.discovery.credentials;
  }
  // Not found on this computer.
  if (mintable) return mintOne(scan, opts);
  if (scan.spec.discovery.environment?.accessToken) return promptForKey(scan, opts);
  return null;
}

/** Resolve every selected provider to credentials, skipping the ones the user
 * declines or that fail to set up. */
export async function gatherSelectedAccounts(
  selected: ProviderScan[],
  opts: WizardOptions
): Promise<Credentials[]> {
  const gathered: Credentials[] = [];
  for (const scan of selected) {
    const creds = await gatherOne(scan, opts);
    if (creds) gathered.push(creds);
  }
  return gathered;
}

export async function runWizard(opts: WizardOptions): Promise<number> {
  opts.err("Vigil Link — bring your AI accounts under watch on your iPhone.");
  opts.err(
    "Credentials never touch a server; they only leave this computer inside the QR codes you scan."
  );
  opts.err("\nScanning this computer for provider credentials...");

  const scans = await scanProviders(opts);
  const found = scans.filter((scan) => scan.discovery.credentials);
  const missing = scans.filter((scan) => !scan.discovery.credentials);

  opts.err(`\nFound ${found.length} of ${scans.length} supported providers:`);
  if (found.length === 0) opts.err("  (none yet)");
  for (const scan of found) opts.err(`  ✓ ${scan.spec.displayName} — ${foundLabel(scan)}`);
  opts.err("\nNot found (add now, or later on your iPhone → Add account → Paste a provider key):");
  for (const scan of missing) {
    opts.err(`  ✗ ${scan.spec.displayName} — ${missingHint(scan).note}`);
  }

  // Build the picker: found preselected; addable-missing offered unselected;
  // unaddable-missing shown disabled with the reason.
  const items: ToggleItem[] = scans.map((scan) => {
    if (scan.discovery.credentials) {
      return { label: `${scan.spec.displayName} — ${foundLabel(scan)}`, selected: true };
    }
    const hint = missingHint(scan);
    if (!hint.addable) {
      return { label: scan.spec.displayName, selected: false, disabled: hint.note };
    }
    return { label: `${scan.spec.displayName} — ${hint.note}`, selected: false };
  });

  const chosen = await opts.prompts.multiToggle("\nWhich accounts should Vigil watch?", items);
  const selected = scans.filter((_, index) => chosen[index]);
  if (selected.length === 0) {
    opts.err(
      "Nothing selected — no accounts to link. Re-run `npx vigil-link` and pick at least one, " +
        "or add a provider directly on your iPhone."
    );
    return 1;
  }

  opts.err("");
  const gathered = await gatherSelectedAccounts(selected, opts);
  if (gathered.length === 0) {
    opts.err("No account could be set up. Re-run `npx vigil-link` to try again.");
    return 1;
  }

  opts.err("\nOpen Vigil on your iPhone → Add account → Scan code.");
  const code = await emitLink(
    {
      json: false,
      yes: false,
      big: opts.big,
      clear: opts.clear,
      verify: opts.verify,
      registry: opts.registry,
      ...(opts.discovery ? { discovery: opts.discovery } : {}),
      ...(opts.http ? { http: opts.http } : {}),
      ...(opts.poll !== undefined ? { poll: opts.poll } : {}),
      ...(opts.now ? { now: opts.now } : {}),
      out: opts.out,
      err: opts.err,
      confirm: (question) => opts.prompts.confirmStrict(question),
      waitKey: () => opts.prompts.waitKey(),
      ...(opts.columns !== undefined ? { columns: opts.columns } : {}),
      ...(opts.sleep ? { sleep: opts.sleep } : {}),
      ...(opts.sid ? { sid: opts.sid } : {}),
    },
    gathered
  );

  if (code === 0) {
    opts.err(
      "Tip: API-key providers can also be added straight on your iPhone — " +
        "Add account → Paste a provider key."
    );
  }
  return code;
}

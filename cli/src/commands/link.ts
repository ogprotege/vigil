import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import type { HttpOptions } from "../http.js";
import type { PollGateOptions } from "../polling.js";
import type { Credentials } from "../providers/types.js";
import { collectCredentials } from "./status.js";
import { getSnapshot } from "../service.js";
import { hasMintAdapter, mintProvider } from "../oauth/index.js";
import type { MintOptions } from "../oauth/claudeMint.js";
import { buildPayload, chunkEncoded, encodePayload, makeSid } from "../qr/payload.js";
import { renderQr } from "../qr/render.js";
import { redactedMessage } from "../util/redact.js";
import { sanitizeTerminalText } from "../util/terminal.js";

export interface LinkOptions {
  providers: ProviderId[];
  /** "mint" (default): mint Claude its own pair; "copy": reuse existing CLI creds. */
  mode: "mint" | "copy";
  json: boolean;
  /**
   * Explicit consent (--yes) to emit credential-bearing output without an
   * interactive confirmation. Required in --json mode and whenever stdin is
   * not a TTY (no `confirm` callback); the threat model promises consent is
   * always obtained before credentials are displayed.
   */
  yes: boolean;
  loop: boolean;
  big: boolean;
  clear: boolean;
  verify: boolean;
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  poll?: PollGateOptions | false;
  mint?: MintOptions;
  now?: () => Date;
  out: (text: string) => void;
  err: (text: string) => void;
  confirm?: (question: string) => Promise<boolean>;
  waitForKey?: (message: string) => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
  sid?: string;
}

export async function collectLinkAccounts(opts: LinkOptions): Promise<Credentials[]> {
  const accounts: Credentials[] = [];
  const copyProviders: ProviderId[] = [];

  for (const providerId of opts.providers) {
    const spec = opts.registry.providers[providerId];
    if (!spec) {
      opts.err(`Provider "${providerId}" is missing from the loaded registry. Skipping.`);
      continue;
    }
    if (opts.mode === "mint" && hasMintAdapter(providerId, spec)) {
      try {
        opts.err(
          `Opening your browser to authorize Vigil with ${spec.displayName} (its own token, separate from the provider CLI)...`
        );
        accounts.push(await mintProvider(providerId, spec, opts.mint));
        continue;
      } catch (mintError) {
        opts.err(
          `Mint flow failed (${sanitizeTerminalText(redactedMessage(mintError))}); ` +
            "falling back to discovering existing credentials."
        );
      }
    }
    copyProviders.push(providerId);
  }

  if (copyProviders.length > 0) {
    const { found, missing } = await collectCredentials(opts.registry, copyProviders, opts.discovery);
    accounts.push(...found);
    for (const item of missing) {
      const displayName = sanitizeTerminalText(
        opts.registry.providers[item.providerId]?.displayName ?? item.providerId
      );
      opts.err(`No ${displayName} credentials found on this machine. Skipping.`);
    }
  }
  return accounts;
}

async function verifyAccounts(opts: LinkOptions, accounts: Credentials[]): Promise<Credentials[]> {
  const verified: Credentials[] = [];
  const now = opts.now ?? (() => new Date());
  const poll =
    opts.poll === false
      ? undefined
      : {
          homeDir: opts.discovery?.homeDir,
          env: opts.discovery?.env,
          ...opts.poll,
          now,
        };
  const results = await Promise.all(accounts.map(async (creds) => {
    const spec = opts.registry.providers[creds.providerId];
    if (!spec) {
      return {
        credentials: null,
        messages: [
          `✗ ${sanitizeTerminalText(creds.providerId)}: missing registry entry. Not including in link payload.`,
        ],
      };
    }
    const { snapshot, credentials, pollSafetyWarning } = await getSnapshot(opts.registry, creds, {
      ...opts.http,
      now,
      poll,
    });
    const displayName = sanitizeTerminalText(spec.displayName);
    const messages: string[] = [];
    if (pollSafetyWarning) {
      messages.push(
        `⚠ ${displayName}: poll safety result could not be saved ` +
          `(${pollSafetyWarning.reason}); conservative pause remains until ${pollSafetyWarning.retryAt}`
      );
    }
    if (snapshot.status === "ok" || snapshot.status === "rateLimited") {
      // rateLimited still proves the credential reaches the provider.
      messages.push(`✓ ${displayName}: verified (${snapshot.status})`);
      return { credentials, messages };
    } else {
      const retry =
        snapshot.status === "deferred" && snapshot.retryAt ? ` until ${snapshot.retryAt}` : "";
      messages.push(
        `✗ ${displayName}: ${snapshot.status}${retry}. Not including in link payload.`
      );
      return { credentials: null, messages };
    }
  }));
  for (const result of results) {
    for (const message of result.messages) opts.err(message);
    if (result.credentials) verified.push(result.credentials);
  }
  return verified;
}

const CONSENT =
  "The QR codes about to be shown contain your account credentials.\n" +
  "Anyone who can see or record your screen can capture them. Continue?";

export async function runLink(opts: LinkOptions): Promise<number> {
  const now = opts.now ?? (() => new Date());

  // Consent gate, checked before any discovery or minting: without an
  // interactive prompt available, credential-bearing output requires --yes.
  if (!opts.yes && (opts.json || !opts.confirm)) {
    opts.err(
      opts.json
        ? "Refusing to print credentials: --json emits credential-bearing lines without an interactive confirmation. Re-run with --yes to consent."
        : "Refusing to print credentials without --yes when stdin is not interactive. Re-run with --yes to consent, or run from a terminal."
    );
    return 1;
  }

  let accounts = await collectLinkAccounts(opts);
  if (accounts.length === 0) {
    opts.err(
      "Nothing to link. Configure credentials for at least one selected provider, then re-run `vigil-link doctor`."
    );
    return 1;
  }
  if (opts.verify) {
    accounts = await verifyAccounts(opts, accounts);
    if (accounts.length === 0) {
      opts.err("No account verified successfully; not rendering a link code.");
      return 1;
    }
  }

  const payload = buildPayload(accounts, Math.floor(now().getTime() / 1000));
  const encoded = encodePayload(payload);
  const sid = opts.sid ?? makeSid();

  if (opts.json) {
    opts.err("⚠ The following line(s) contain credentials. Paste them into the Vigil app, then clear your scroll-back.");
    opts.out(chunkEncoded(encoded, sid).join("\n"));
    // Intentional: --json usually feeds a pipe, and the CLI cannot clear a
    // piped stream, so the caution above is the only mitigation we can offer.
    opts.err("vigil-link cannot clear a piped stream — clear your terminal scroll-back yourself once the app has the code.");
    return 0;
  }

  if (opts.yes) {
    opts.err("⚠ --yes: skipping the credential-display confirmation. The codes below contain your account credentials.");
  } else if (opts.confirm && !(await opts.confirm(CONSENT))) {
    opts.err("Cancelled — nothing was shown.");
    return 1;
  }

  const chunks = chunkEncoded(encoded, sid);
  const wait = opts.waitForKey ?? (async () => {});
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  if (opts.loop && chunks.length > 1) {
    opts.err(`Cycling ${chunks.length} codes every 3s — press Ctrl+C when the app shows all captured.`);
    // Two full passes is enough for the app to capture all chunks in any order.
    for (let pass = 0; pass < 2; pass++) {
      for (let i = 0; i < chunks.length; i++) {
        opts.out(`\nVigil link — code ${i + 1} of ${chunks.length} (open Vigil → Add Account → Scan)\n`);
        opts.out(await renderQr(chunks[i]!, { big: opts.big }));
        await sleep(3000);
      }
    }
  } else {
    for (let i = 0; i < chunks.length; i++) {
      opts.out(`\nVigil link — code ${i + 1} of ${chunks.length} (open Vigil → Add Account → Scan)\n`);
      opts.out(await renderQr(chunks[i]!, { big: opts.big }));
      if (i < chunks.length - 1) await wait("Press Enter for the next code...");
    }
    await wait("Press Enter once the app has captured everything...");
  }

  if (opts.clear) {
    // ANSI clear screen + scrollback, best effort.
    opts.out("[2J[3J[H");
    opts.err("Screen cleared. Done — check the Vigil app.");
  } else {
    opts.err("Done — check the Vigil app. (Screen NOT cleared: --no-clear)");
  }
  return 0;
}

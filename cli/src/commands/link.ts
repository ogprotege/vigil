import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import type { HttpOptions } from "../http.js";
import type { Credentials } from "../providers/types.js";
import { collectCredentials } from "./status.js";
import { getSnapshot } from "../service.js";
import { mintClaude, type MintOptions } from "../oauth/claudeMint.js";
import { buildPayload, chunkEncoded, encodePayload, makeSid } from "../qr/payload.js";
import { renderQr } from "../qr/render.js";

export interface LinkOptions {
  providers: ProviderId[];
  /** "mint" (default): mint Claude its own pair; "copy": reuse existing CLI creds. */
  mode: "mint" | "copy";
  json: boolean;
  loop: boolean;
  big: boolean;
  clear: boolean;
  verify: boolean;
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
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
    if (providerId === "claude" && opts.mode === "mint") {
      const spec = opts.registry.providers.claude;
      if (!spec.oauth) throw new Error("claude oauth spec missing");
      try {
        opts.err("Opening your browser to authorize Vigil with Claude (its own token — never fights Claude Code's)...");
        accounts.push(await mintClaude(spec.oauth, opts.mint));
        continue;
      } catch (mintError) {
        opts.err(`Mint flow failed (${(mintError as Error).message}); falling back to copying existing credentials.`);
      }
    }
    copyProviders.push(providerId);
  }

  if (copyProviders.length > 0) {
    const { found, missing } = await collectCredentials(opts.registry, copyProviders, opts.discovery);
    accounts.push(...found);
    for (const providerId of missing) {
      opts.err(`No ${opts.registry.providers[providerId].displayName} credentials found on this machine — skipping.`);
    }
  }
  return accounts;
}

async function verifyAccounts(opts: LinkOptions, accounts: Credentials[]): Promise<Credentials[]> {
  const verified: Credentials[] = [];
  for (const creds of accounts) {
    const { snapshot, credentials } = await getSnapshot(opts.registry, creds, { ...opts.http, now: opts.now });
    if (snapshot.status === "ok" || snapshot.status === "rateLimited") {
      // rateLimited still proves the credential reaches the provider.
      verified.push(credentials);
      opts.err(`✓ ${opts.registry.providers[creds.providerId].displayName}: verified (${snapshot.status})`);
    } else {
      opts.err(`✗ ${opts.registry.providers[creds.providerId].displayName}: ${snapshot.status} — not including in link payload`);
    }
  }
  return verified;
}

const CONSENT =
  "The QR codes about to be shown contain your account credentials.\n" +
  "Anyone who can see or record your screen can capture them. Continue?";

export async function runLink(opts: LinkOptions): Promise<number> {
  const now = opts.now ?? (() => new Date());
  let accounts = await collectLinkAccounts(opts);
  if (accounts.length === 0) {
    opts.err("Nothing to link. Sign in to Claude Code and/or the Codex CLI first, then re-run.");
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
    opts.err("⚠ The following line contains credentials. Paste it into the Vigil app, then clear your scroll-back.");
    const [single] = chunkEncoded(encoded, sid, Math.max(encoded.length, 1));
    opts.out(single!);
    return 0;
  }

  if (opts.confirm && !(await opts.confirm(CONSENT))) {
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

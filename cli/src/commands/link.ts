import type { ProviderId, Registry } from "../spec/registry.js";
import type { DiscoveryOptions } from "../discovery/paths.js";
import type { HttpOptions } from "../http.js";
import type { PollGateOptions } from "../polling.js";
import type { Credentials, ProviderSnapshot, SnapshotStatus } from "../providers/types.js";
import { collectCredentials } from "./status.js";
import { getSnapshot, type PollSafetyWarning } from "../service.js";
import { hasMintAdapter, mintProvider } from "../oauth/index.js";
import type { MintOptions } from "../oauth/claudeMint.js";
import { buildPayload, chunkEncoded, encodePayload, makeSid } from "../qr/payload.js";
import { presentChunks } from "../qr/present.js";
import { redactedMessage } from "../util/redact.js";
import { sanitizeTerminalText } from "../util/terminal.js";
import { humanizeUntil } from "../util/time.js";

/**
 * Everything the handoff back-end (verify -> payload -> consent -> present)
 * needs, independent of how the account list was gathered. Both the classic
 * flow (`runLink`) and the wizard (`runWizard`) build a `Credentials[]` and
 * pass it to `emitLink` with these options.
 */
export interface EmitLinkOptions {
  json: boolean;
  /**
   * Explicit consent (--yes) to emit credential-bearing output without an
   * interactive confirmation. Required in --json mode and whenever stdin is
   * not a TTY (no `confirm` callback); the threat model promises consent is
   * always obtained before credentials are displayed.
   */
  yes: boolean;
  big: boolean;
  clear: boolean;
  verify: boolean;
  registry: Registry;
  discovery?: DiscoveryOptions;
  http?: HttpOptions;
  poll?: PollGateOptions | false;
  now?: () => Date;
  out: (text: string) => void;
  err: (text: string) => void;
  confirm?: (question: string) => Promise<boolean>;
  /** Resolves on the next keypress; drives QR cycling. Absent => draw once. */
  waitKey?: () => Promise<void>;
  /** Terminal width, for auto-sizing the QR. Undefined keeps the compact code. */
  columns?: number;
  sleep?: (ms: number) => Promise<void>;
  sid?: string;
}

export interface LinkOptions extends EmitLinkOptions {
  providers: ProviderId[];
  /** "mint" (default): mint Claude its own pair; "copy": reuse existing CLI creds. */
  mode: "mint" | "copy";
  /** @deprecated Multi-chunk codes now cycle until a keypress by default. */
  loop: boolean;
  mint?: MintOptions;
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

/**
 * The result of live-verifying one candidate account before handoff.
 *
 * - `verified`: the provider answered (ok or rateLimited — reachability proven).
 * - `deferred`: the local cross-process poll gate refused the request (this
 *   computer polled recently). The credential is still handoff-worthy; the
 *   phone verifies it on its own next refresh, so we never drop it.
 * - `failed`: the provider rejected the credential or was unreachable
 *   (authExpired / network / schemaChanged). Excluded from the payload.
 */
export interface VerifyOutcome {
  kind: "verified" | "deferred" | "failed";
  credentials: Credentials;
  displayName: string;
  /** Absent only for the (near-impossible) missing-registry guard. */
  snapshot?: ProviderSnapshot;
  pollSafetyWarning?: PollSafetyWarning;
}

function classifyStatus(status: SnapshotStatus): VerifyOutcome["kind"] {
  if (status === "ok" || status === "rateLimited") return "verified";
  if (status === "deferred") return "deferred";
  return "failed";
}

/**
 * Live-verifies every candidate account and classifies the result. Pure with
 * respect to output: callers render the human messages (see
 * `verifyOutcomeMessages`) and decide inclusion, so the wizard and the classic
 * flow can present the same outcomes differently.
 */
export async function verifyLinkAccounts(
  opts: EmitLinkOptions,
  accounts: Credentials[]
): Promise<VerifyOutcome[]> {
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
  return Promise.all(
    accounts.map(async (creds): Promise<VerifyOutcome> => {
      const spec = opts.registry.providers[creds.providerId];
      if (!spec) {
        return {
          kind: "failed",
          credentials: creds,
          displayName: sanitizeTerminalText(creds.providerId),
        };
      }
      const { snapshot, credentials, pollSafetyWarning } = await getSnapshot(opts.registry, creds, {
        ...opts.http,
        now,
        poll,
      });
      return {
        kind: classifyStatus(snapshot.status),
        credentials,
        displayName: sanitizeTerminalText(spec.displayName),
        snapshot,
        ...(pollSafetyWarning ? { pollSafetyWarning } : {}),
      };
    })
  );
}

function failedMessage(name: string, status: SnapshotStatus | undefined): string {
  switch (status) {
    case "authExpired":
      return (
        `✗ ${name}: the provider rejected these credentials (expired or revoked). ` +
        "Not included — refresh them (open the provider's own CLI or sign in again), then re-run."
      );
    case "network":
      return `✗ ${name}: couldn't reach the provider (network problem). Not included — check your connection and re-run.`;
    case "schemaChanged":
      return `✗ ${name}: the provider returned an unexpected response. Not included — check for a vigil-link update.`;
    default:
      return `✗ ${name}: verification failed (${status ?? "unknown"}). Not included.`;
  }
}

/** Human-readable lines for one verification outcome, for the classic flow. */
export function verifyOutcomeMessages(outcome: VerifyOutcome, now: Date): string[] {
  const name = outcome.displayName;
  const messages: string[] = [];
  if (outcome.pollSafetyWarning) {
    messages.push(
      `⚠ ${name}: poll safety result could not be saved ` +
        `(${outcome.pollSafetyWarning.reason}); conservative pause remains until ${outcome.pollSafetyWarning.retryAt}`
    );
  }
  if (outcome.kind === "verified") {
    messages.push(`✓ ${name}: verified (${outcome.snapshot?.status ?? "ok"})`);
  } else if (outcome.kind === "deferred") {
    const next = outcome.snapshot?.retryAt
      ? `; next allowed in ${humanizeUntil(outcome.snapshot.retryAt, now)}`
      : "";
    messages.push(
      `◌ ${name}: couldn't verify right now — this computer polled recently ` +
        `(Vigil waits 5 minutes between checks${next}). ` +
        "Including it anyway; your iPhone will verify it on its next refresh."
    );
    if (outcome.snapshot?.deferredReason === "corruptState" && outcome.snapshot.pollStatePath) {
      messages.push(
        `  ⚠ poll-state file is corrupt or unreadable: ${sanitizeTerminalText(outcome.snapshot.pollStatePath)}`
      );
      messages.push("  recovery: delete that file to reset this provider's poll clock");
    }
  } else {
    messages.push(failedMessage(name, outcome.snapshot?.status));
  }
  return messages;
}

const CONSENT =
  "The QR codes about to be shown contain your account credentials.\n" +
  "Anyone who can see or record your screen can capture them. Continue?";

export async function runLink(opts: LinkOptions): Promise<number> {
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

  const accounts = await collectLinkAccounts(opts);
  if (accounts.length === 0) {
    opts.err(
      "Nothing to link. Configure credentials for at least one selected provider, then re-run `vigil-link doctor`."
    );
    return 1;
  }
  return emitLink(opts, accounts);
}

/**
 * Shared handoff back-end: verify (dropping only hard failures, keeping
 * deferred accounts), build the payload, obtain display consent, and render the
 * QR (or print the paste-code in --json mode). Both the classic flow and the
 * wizard funnel their gathered accounts through here.
 */
export async function emitLink(opts: EmitLinkOptions, gathered: Credentials[]): Promise<number> {
  const now = opts.now ?? (() => new Date());
  let accounts = gathered;

  if (opts.verify) {
    const outcomes = await verifyLinkAccounts(opts, accounts);
    for (const outcome of outcomes) {
      for (const message of verifyOutcomeMessages(outcome, now())) opts.err(message);
    }
    // Verified and deferred accounts both ship: a deferred one just means this
    // computer polled recently, and the phone will verify it on its own.
    accounts = outcomes
      .filter((outcome) => outcome.kind === "verified" || outcome.kind === "deferred")
      .map((outcome) => outcome.credentials);
    if (accounts.length === 0) {
      opts.err(
        "Nothing left to link — no selected account could be verified or included. " +
          "Fix the errors above and re-run."
      );
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
  await presentChunks(
    chunks,
    { size: opts.big ? "big" : "auto" },
    {
      out: opts.out,
      err: opts.err,
      clear: opts.clear,
      ...(opts.columns !== undefined ? { columns: opts.columns } : {}),
      ...(opts.waitKey ? { waitKey: opts.waitKey } : {}),
      ...(opts.sleep ? { sleep: opts.sleep } : {}),
    }
  );
  return 0;
}

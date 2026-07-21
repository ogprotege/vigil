#!/usr/bin/env node
import { createRequire } from "node:module";
import { createInterface } from "node:readline/promises";
import { loadRegistry, providerIds, type ProviderId, type Registry } from "./spec/registry.js";
import { parseCli, selectLinkMode } from "./cli.js";
import { statusReport } from "./commands/status.js";
import { doctorReport } from "./commands/doctor.js";
import { runLink } from "./commands/link.js";
import { runWizard, type WizardPrompts } from "./commands/wizard.js";
import { InputManager } from "./ui/prompts.js";
import { CLEAR_SCREEN } from "./qr/present.js";
import type { MintOptions } from "./oauth/claudeMint.js";
import { redactedMessage } from "./util/redact.js";
import { sanitizeTerminalText } from "./util/terminal.js";

const require = createRequire(import.meta.url);
const packageVersion = (require("../package.json") as { version: string }).version;

const HELP = `vigil-link — link your AI accounts to the Vigil usage monitor

Usage:
  npx vigil-link            Guided setup: scan this computer, pick accounts, show the QR
  npx vigil-link status     Show your usage windows in the terminal
  npx vigil-link doctor     Diagnose credential discovery ( --live adds a network check )
  npx vigil-link --version  Print the vigil-link version

Link options (advanced — plain \`npx vigil-link\` needs none of these):
  --provider <ids>   Comma-separated registry IDs (default: enabled providers)
  --mint             Mint Vigil its own Claude token via browser sign-in (default)
  --copy             Copy existing CLI credentials instead of minting
  --json             Print the paste-code to stdout instead of rendering QRs
  --yes              Consent to credential-bearing output without a prompt
                     (required with --json or when stdin is not a terminal)
  --big              Render larger QR blocks (finicky terminals)
  --no-clear         Don't clear the terminal after linking
  --no-verify        Skip the live verification fetch before rendering

vigil-link never writes credentials or usage values to disk. It stores only
per-provider poll timestamps and 429 counters in the user cache directory.
`;

function parseProviders(value: string | undefined, registry: Registry): ProviderId[] {
  if (!value) return providerIds(registry);
  const known = Object.keys(registry.providers);
  const ids = [...new Set(value.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean))];
  if (ids.length === 0) throw new Error("--provider requires at least one provider ID");
  for (const id of ids) {
    if (!Object.hasOwn(registry.providers, id)) {
      throw new Error(`unknown provider "${id}" (known: ${known.join(", ")})`);
    }
  }
  return ids;
}

async function main(): Promise<number> {
  const outcome = parseCli(process.argv.slice(2), { version: packageVersion, help: HELP });
  if (outcome.kind === "print") {
    const stream = outcome.stream === "stdout" ? process.stdout : process.stderr;
    stream.write(outcome.text + "\n");
    return outcome.exitCode;
  }

  const { command, provider, flags, classicFlagUsed } = outcome.invocation;
  const registry = loadRegistry();
  const providers = parseProviders(provider, registry);

  if (command === "status") {
    process.stdout.write((await statusReport({ registry }, providers)) + "\n");
    return 0;
  }

  if (command === "doctor") {
    process.stdout.write(await doctorReport({ registry, live: flags.live }, providers));
    return 0;
  }

  if (flags.loop) {
    process.stderr.write(
      "Note: --loop is deprecated — multi-code handoff now cycles automatically until you press a key.\n"
    );
  }

  const out = (text: string) => process.stdout.write(text.endsWith("\n") ? text : text + "\n");
  const err = (text: string) => process.stderr.write(text + "\n");

  const mode = selectLinkMode({
    classicFlagUsed,
    stdinTTY: process.stdin.isTTY === true,
    stdoutTTY: process.stdout.isTTY === true,
  });

  if (mode === "wizard") {
    const manager = new InputManager({
      input: process.stdin,
      write: (text) => process.stderr.write(text),
      onInterrupt: () => {
        // Abort should never leave a credential-bearing QR on screen: scrub it.
        process.stdout.write(CLEAR_SCREEN);
        process.exit(130);
      },
    });
    try {
      const prompts: WizardPrompts = {
        confirmStrict: (question) => manager.confirmStrict(question),
        choose: (title, options, defaultIndex) => manager.choose(title, options, defaultIndex),
        multiToggle: (title, items) => manager.multiToggle(title, items),
        textInput: (label, textOpts) => manager.textInput(label, textOpts),
        waitKey: () => manager.nextKey(),
      };
      return await runWizard({
        registry,
        big: flags.big,
        clear: !flags.noClear,
        verify: !flags.noVerify,
        columns: process.stdout.columns,
        out,
        err,
        prompts,
        mint: delayedMintPrompt(manager),
      });
    } finally {
      manager.close();
    }
  }

  const interactive = process.stdin.isTTY === true && !flags.json;
  const rl = interactive ? createInterface({ input: process.stdin, output: process.stderr }) : null;
  try {
    return await runLink({
      providers,
      mode: flags.copy ? "copy" : "mint",
      json: flags.json,
      yes: flags.yes,
      loop: flags.loop,
      big: flags.big,
      clear: !flags.noClear,
      verify: !flags.noVerify,
      registry,
      out,
      err,
      columns: process.stdout.columns,
      confirm: rl
        ? async (question) => {
            const answer = await rl.question(`${question} [y/N] `);
            return answer.trim().toLowerCase().startsWith("y");
          }
        : undefined,
      waitKey: rl
        ? async () => {
            await rl.question("");
          }
        : undefined,
      mint: rl
        ? {
            promptPaste: async (url, signal) => {
              process.stderr.write(
                  `\nIf the browser didn't open, visit:\n${sanitizeTerminalText(url, 4096)}\n\n` +
                  `Waiting for the browser... If it shows a connection error after you\n` +
                  `authorize, paste that page's full URL (or the code) below instead.\n`
              );
              // The signal is load-bearing, not decorative. This prompt is a
              // racing recovery lane: when the loopback lane wins, mintClaude
              // aborts it. Without honoring the signal the question stays
              // pending on the shared readline interface, and Node drops the
              // callback of the NEXT question issued while one is pending — so
              // every later prompt (the consent gate, the QR dismissal) never
              // resolves and the CLI hangs forever with credentials on screen.
              try {
                return await rl.question("Paste URL/code here (or just wait): ", { signal });
              } catch (error) {
                // Abort is the normal outcome when the browser lane wins.
                if ((error as { name?: string })?.name === "AbortError") {
                  return await new Promise<string>(() => {});
                }
                throw error;
              }
            },
          }
        : undefined,
    });
  } finally {
    rl?.close();
  }
}

/** Resolves after `ms`, or early if the signal aborts. Never rejects. */
function abortableDelay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    timer.unref?.();
    const onAbort = () => {
      clearTimeout(timer);
      resolve();
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/**
 * Mint options whose paste prompt only appears if the browser flow stalls: it
 * waits ~15s, and cancels itself (no spurious prompt) when the loopback lane
 * wins, so the happy path never shows the "paste a URL" step.
 */
function delayedMintPrompt(manager: InputManager): MintOptions {
  return {
    promptPaste: async (url, signal) => {
      await abortableDelay(15_000, signal);
      if (signal?.aborted) return "";
      process.stderr.write(
        "\nStill waiting for the browser. If it showed an error after you approved, " +
          "paste that page's full URL (or the code) here.\n" +
          `Or open this link yourself:\n${sanitizeTerminalText(url, 4096)}\n`
      );
      try {
        return await manager.question("Paste URL/code here: ", { signal });
      } catch {
        return ""; // aborted because another lane resolved the flow
      }
    },
  };
}

main()
  .then((code) => process.exit(code))
  .catch((err: unknown) => {
    process.stderr.write(`error: ${sanitizeTerminalText(redactedMessage(err))}\n`);
    process.exit(1);
  });

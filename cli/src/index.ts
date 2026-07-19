#!/usr/bin/env node
import { parseArgs } from "node:util";
import { createInterface } from "node:readline/promises";
import { loadRegistry, providerIds, type ProviderId, type Registry } from "./spec/registry.js";
import { statusReport } from "./commands/status.js";
import { doctorReport } from "./commands/doctor.js";
import { runLink } from "./commands/link.js";
import { redactedMessage } from "./util/redact.js";
import { sanitizeTerminalText } from "./util/terminal.js";

const HELP = `vigil-link — link your AI accounts to the Vigil usage monitor

Usage:
  npx vigil-link            Link accounts to the app (QR handoff)
  npx vigil-link status     Show your usage windows in the terminal
  npx vigil-link doctor     Diagnose credential discovery ( --live adds a network check )

Link options:
  --provider <ids>   Comma-separated registry IDs (default: enabled providers)
  --mint             Mint Vigil its own Claude token via browser sign-in (default)
  --copy             Copy existing CLI credentials instead of minting
  --json             Print the paste-code to stdout instead of rendering QRs
  --yes              Consent to credential-bearing output without a prompt
                     (required with --json or when stdin is not a terminal)
  --loop             Auto-cycle multi-chunk QRs every 3s (hands-free scanning)
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
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      provider: { type: "string" },
      mint: { type: "boolean" },
      copy: { type: "boolean" },
      json: { type: "boolean" },
      yes: { type: "boolean" },
      loop: { type: "boolean" },
      big: { type: "boolean" },
      "no-clear": { type: "boolean" },
      "no-verify": { type: "boolean" },
      live: { type: "boolean" },
      help: { type: "boolean" },
    },
  });

  if (values.help) {
    process.stdout.write(HELP);
    return 0;
  }

  const command = positionals[0] ?? "link";
  const registry = loadRegistry();
  const providers = parseProviders(values.provider, registry);

  if (command === "status") {
    process.stdout.write((await statusReport({ registry }, providers)) + "\n");
    return 0;
  }

  if (command === "doctor") {
    process.stdout.write(await doctorReport({ registry, live: values.live ?? false }, providers));
    return 0;
  }

  if (command !== "link") {
    process.stderr.write(`unknown command "${command}"\n\n${HELP}`);
    return 1;
  }

  const interactive = process.stdin.isTTY === true && !values.json;
  const rl = interactive ? createInterface({ input: process.stdin, output: process.stderr }) : null;
  try {
    return await runLink({
      providers,
      mode: values.copy ? "copy" : "mint",
      json: values.json ?? false,
      yes: values.yes ?? false,
      loop: values.loop ?? false,
      big: values.big ?? false,
      clear: !(values["no-clear"] ?? false),
      verify: !(values["no-verify"] ?? false),
      registry,
      out: (text) => process.stdout.write(text.endsWith("\n") ? text : text + "\n"),
      err: (text) => process.stderr.write(text + "\n"),
      confirm: rl
        ? async (question) => {
            const answer = await rl.question(`${question} [y/N] `);
            return answer.trim().toLowerCase().startsWith("y");
          }
        : undefined,
      waitForKey: rl
        ? async (message) => {
            await rl.question(message);
          }
        : undefined,
      mint: rl
        ? {
            promptPaste: async (url) => {
              process.stderr.write(
                  `\nIf the browser didn't open, visit:\n${sanitizeTerminalText(url, 4096)}\n\n` +
                  `Waiting for the browser... If it shows a connection error after you\n` +
                  `authorize, paste that page's full URL (or the code) below instead.\n`
              );
              return rl.question("Paste URL/code here (or just wait): ");
            },
          }
        : undefined,
    });
  } finally {
    rl?.close();
  }
}

main()
  .then((code) => process.exit(code))
  .catch((err: unknown) => {
    process.stderr.write(`error: ${sanitizeTerminalText(redactedMessage(err))}\n`);
    process.exit(1);
  });

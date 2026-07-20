import { parseArgs } from "node:util";

export interface CliFlags {
  mint: boolean;
  copy: boolean;
  json: boolean;
  yes: boolean;
  loop: boolean;
  big: boolean;
  noClear: boolean;
  noVerify: boolean;
  live: boolean;
}

export interface ParsedInvocation {
  command: "link" | "status" | "doctor";
  provider?: string;
  flags: CliFlags;
  /** True when any flag that forces the classic (non-wizard) link flow was passed. */
  classicFlagUsed: boolean;
}

export type CliOutcome =
  | { kind: "invoke"; invocation: ParsedInvocation }
  | { kind: "print"; text: string; stream: "stdout" | "stderr"; exitCode: number };

export interface CliDeps {
  version: string;
  help: string;
}

const COMMANDS = ["link", "status", "doctor"] as const;

// Long-form option names, used both by parseArgs and by the did-you-mean hint.
const OPTION_NAMES = [
  "provider",
  "mint",
  "copy",
  "json",
  "yes",
  "loop",
  "big",
  "no-clear",
  "no-verify",
  "live",
  "help",
  "version",
];

/** Flags that force the classic scripted link flow instead of the wizard. */
const CLASSIC_FLAGS = new Set(["provider", "mint", "copy", "json", "yes", "loop"]);

function levenshtein(a: string, b: string): number {
  const rows = a.length + 1;
  const cols = b.length + 1;
  const dist: number[][] = Array.from({ length: rows }, () => new Array<number>(cols).fill(0));
  for (let i = 0; i < rows; i++) dist[i]![0] = i;
  for (let j = 0; j < cols; j++) dist[0]![j] = j;
  for (let i = 1; i < rows; i++) {
    for (let j = 1; j < cols; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dist[i]![j] = Math.min(
        dist[i - 1]![j]! + 1,
        dist[i]![j - 1]! + 1,
        dist[i - 1]![j - 1]! + cost
      );
    }
  }
  return dist[a.length]![b.length]!;
}

function closest(candidate: string, options: readonly string[]): string | null {
  let best: string | null = null;
  let bestDistance = Infinity;
  for (const option of options) {
    const distance = levenshtein(candidate, option);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = option;
    }
  }
  // Only suggest when the typo is genuinely close (a third of the length, min 2).
  const threshold = Math.max(2, Math.ceil(candidate.length / 3));
  return best !== null && bestDistance <= threshold ? best : null;
}

function unknownOptionMessage(rawOption: string, help: string): string {
  const stripped = rawOption.replace(/^--?/, "");
  const suggestion = closest(stripped, OPTION_NAMES);
  const lines = [`Unknown option "${rawOption}".`];
  if (suggestion) lines.push(`Did you mean --${suggestion}?`);
  lines.push("Run `npx vigil-link --help` for usage.");
  void help;
  return lines.join(" ");
}

function extractUnknownOption(error: unknown): string | null {
  if (!(error instanceof Error)) return null;
  const match = /Unknown option '([^']+)'/.exec(error.message);
  return match ? match[1]! : null;
}

export function parseCli(argv: string[], deps: CliDeps): CliOutcome {
  let values: ReturnType<typeof parseArgs>["values"];
  let positionals: string[];
  try {
    const parsed = parseArgs({
      args: argv,
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
        help: { type: "boolean", short: "h" },
        version: { type: "boolean", short: "V" },
      },
    });
    values = parsed.values;
    positionals = parsed.positionals;
  } catch (error) {
    const rawOption = extractUnknownOption(error);
    const text = rawOption
      ? unknownOptionMessage(rawOption, deps.help)
      : `${error instanceof Error ? error.message : String(error)}. Run \`npx vigil-link --help\` for usage.`;
    return { kind: "print", text, stream: "stderr", exitCode: 1 };
  }

  if (values.version) {
    return { kind: "print", text: deps.version, stream: "stdout", exitCode: 0 };
  }
  if (values.help) {
    return { kind: "print", text: deps.help, stream: "stdout", exitCode: 0 };
  }

  const command = positionals[0] ?? "link";
  if (!COMMANDS.includes(command as (typeof COMMANDS)[number])) {
    const suggestion = closest(command, COMMANDS);
    const lines = [`Unknown command "${command}".`];
    if (suggestion) lines.push(`Did you mean \`${suggestion}\`?`);
    lines.push(`Valid commands: ${COMMANDS.join(", ")}.`);
    return { kind: "print", text: lines.join(" "), stream: "stderr", exitCode: 1 };
  }

  const flags: CliFlags = {
    mint: values.mint === true,
    copy: values.copy === true,
    json: values.json === true,
    yes: values.yes === true,
    loop: values.loop === true,
    big: values.big === true,
    noClear: values["no-clear"] === true,
    noVerify: values["no-verify"] === true,
    live: values.live === true,
  };

  const classicFlagUsed = OPTION_NAMES.some(
    (name) => CLASSIC_FLAGS.has(name) && values[name] !== undefined
  );

  return {
    kind: "invoke",
    invocation: {
      command: command as ParsedInvocation["command"],
      ...(typeof values.provider === "string" ? { provider: values.provider } : {}),
      flags,
      classicFlagUsed,
    },
  };
}

export type LinkMode = "wizard" | "classic";

export function selectLinkMode(input: {
  classicFlagUsed: boolean;
  stdinTTY: boolean;
  stdoutTTY: boolean;
}): LinkMode {
  if (input.classicFlagUsed) return "classic";
  if (!input.stdinTTY || !input.stdoutTTY) return "classic";
  return "wizard";
}

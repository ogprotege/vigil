import { renderQr } from "./render.js";

/** Clear the visible screen and scrollback, then home the cursor. Best effort:
 * some terminals ignore the 3J (scrollback) sequence. */
export const CLEAR_SCREEN = "\x1b[2J\x1b[3J\x1b[H";
const CURSOR_HOME = "\x1b[H";
const CLEAR_BELOW = "\x1b[0J";
const CYCLE_INTERVAL_MS = 3000;

export type QrSize = "auto" | "big" | "small";

export interface PresentDeps {
  out: (text: string) => void;
  err: (text: string) => void;
  /** Terminal width; undefined for non-TTY (then we keep the compact default). */
  columns?: number;
  clear: boolean;
  /** Resolves on the next keypress. Absent => draw once and don't wait
   * (non-interactive --yes). */
  waitKey?: () => Promise<void>;
  sleep?: (ms: number) => Promise<void>;
}

// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;]*m/g;

function widest(block: string): number {
  // The big QR paints each module with SGR color escapes; measure the visible
  // width (escapes stripped) so a wide-but-colorful code isn't mistaken for one
  // that overflows the terminal.
  return block
    .split("\n")
    .reduce((max, line) => Math.max(max, line.replace(ANSI, "").length), 0);
}

/**
 * Choose big vs small for the whole session from the largest chunk, so every
 * code renders at one consistent size:
 * - explicit big/small honored as-is;
 * - auto with unknown width keeps the compact default (non-TTY);
 * - auto with a known width uses big when it fits, else small.
 * Returns whether even the small code overflows the terminal.
 */
async function decideSize(
  chunks: string[],
  size: QrSize,
  columns: number | undefined
): Promise<{ big: boolean; tooNarrow: boolean }> {
  const longest = chunks.reduce((a, b) => (b.length > a.length ? b : a), chunks[0] ?? "");
  if (size === "big") return { big: true, tooNarrow: false };
  if (size === "small") {
    const small = await renderQr(longest, { big: false });
    return { big: false, tooNarrow: columns !== undefined && widest(small) > columns };
  }
  // auto
  if (columns === undefined) return { big: false, tooNarrow: false };
  const big = await renderQr(longest, { big: true });
  if (widest(big) <= columns) return { big: true, tooNarrow: false };
  const small = await renderQr(longest, { big: false });
  return { big: false, tooNarrow: widest(small) > columns };
}

/**
 * Renders the vigil1 QR chunks to the terminal. A single chunk draws once and
 * waits for a keypress; multiple chunks cycle in place (redrawing over the
 * previous frame) until a keypress, so the scrollback stays clean and the app
 * can capture them in any order without manual advancing.
 */
export async function presentChunks(
  chunks: string[],
  opts: { size: QrSize },
  deps: PresentDeps
): Promise<void> {
  const total = chunks.length;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const { big, tooNarrow } = await decideSize(chunks, opts.size, deps.columns);
  if (tooNarrow) {
    deps.err(
      "Your terminal is too narrow for a scannable code — widen the window or reduce the font size, then re-run."
    );
  }

  const frame = async (index: number, inPlace: boolean): Promise<void> => {
    const prefix = inPlace ? CURSOR_HOME + CLEAR_BELOW : "";
    const header = `\nVigil link — code ${index + 1} of ${total} (open Vigil → Add Account → Scan)\n`;
    deps.out(prefix + header + (await renderQr(chunks[index]!, { big })));
  };

  if (total === 1 || !deps.waitKey) {
    // Single code, or a non-interactive draw: render each once, no cycling.
    for (let i = 0; i < total; i++) await frame(i, false);
    if (deps.waitKey) {
      deps.err(
        "Scan it with Vigil on your iPhone, then press any key here to finish and clear the screen."
      );
      await deps.waitKey();
    }
  } else {
    deps.err("Cycling the codes — press any key once Vigil shows every code captured (Ctrl+C to abort).");
    let stopped = false;
    const keyDone = deps.waitKey().then(() => {
      stopped = true;
    });
    let index = 0;
    let first = true;
    while (!stopped) {
      await frame(index, !first);
      first = false;
      await Promise.race([keyDone, sleep(CYCLE_INTERVAL_MS)]);
      index = (index + 1) % total;
    }
    await keyDone;
  }

  if (deps.clear) {
    deps.out(CLEAR_SCREEN);
    deps.err("Screen cleared. Done — check the Vigil app on your iPhone.");
  } else {
    deps.err("Done — check the Vigil app on your iPhone. (Screen NOT cleared: --no-clear)");
  }
}

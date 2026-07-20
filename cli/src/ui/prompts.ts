/**
 * Hand-rolled terminal prompts over an injected input stream.
 *
 * The whole surface is stream-driven (no node:readline, no raw-mode cursor
 * rendering) so it unit-tests against a PassThrough and keeps vigil-link's
 * runtime dependency footprint at a single package (see ADR-0007). One
 * InputManager owns stdin for the process lifetime; every read is a pull off
 * the same buffer, so line prompts and raw-mode reads can never fight over the
 * stream.
 */

export interface PromptIO {
  input: NodeJS.ReadableStream & Partial<{ isTTY: boolean; setRawMode(mode: boolean): void }>;
  /** Prompt-and-progress sink. In production this writes to stderr, keeping
   * stdout reserved for the QR/paste payload. */
  write: (text: string) => void;
  /** Called on Ctrl+C during a raw-mode read (raw mode suppresses the
   * terminal's own SIGINT). Defaults to exiting with code 130. */
  onInterrupt?: () => void;
}

export interface ToggleItem {
  label: string;
  selected: boolean;
  /** When set, the item is shown but cannot be toggled; the string is the
   * reason (e.g. "run codex login first"). */
  disabled?: string;
}

function abortError(): Error {
  const error = new Error("The operation was aborted");
  error.name = "AbortError";
  return error;
}

export class InputManager {
  private buffer = "";
  private ended = false;
  private pending: Array<(chunk: string) => void> = [];
  private readonly onData = (chunk: Buffer | string) => this.feed(chunk.toString("utf8" as BufferEncoding));
  private readonly onEnd = () => {
    this.ended = true;
    while (this.pending.length > 0) this.pending.shift()!("");
  };

  constructor(private readonly io: PromptIO) {
    io.input.on("data", this.onData as (chunk: unknown) => void);
    io.input.on("end", this.onEnd);
  }

  close(): void {
    this.setRaw(false);
    this.io.input.off("data", this.onData as (chunk: unknown) => void);
    this.io.input.off("end", this.onEnd);
  }

  private feed(chunk: string): void {
    if (this.pending.length > 0) {
      this.pending.shift()!(chunk);
    } else {
      this.buffer += chunk;
    }
  }

  private nextChunk(signal?: AbortSignal): Promise<string> {
    if (this.buffer.length > 0) {
      const chunk = this.buffer;
      this.buffer = "";
      return Promise.resolve(chunk);
    }
    if (this.ended) return Promise.resolve("");
    return new Promise<string>((resolve, reject) => {
      const consumer = (chunk: string) => {
        if (signal) signal.removeEventListener("abort", onAbort);
        resolve(chunk);
      };
      const onAbort = () => {
        const index = this.pending.indexOf(consumer);
        if (index >= 0) this.pending.splice(index, 1);
        reject(abortError());
      };
      if (signal) {
        if (signal.aborted) {
          reject(abortError());
          return;
        }
        signal.addEventListener("abort", onAbort, { once: true });
      }
      this.pending.push(consumer);
    });
  }

  private setRaw(on: boolean): void {
    const input = this.io.input;
    if (input.isTTY && typeof input.setRawMode === "function") input.setRawMode(on);
  }

  private interrupt(): void {
    (this.io.onInterrupt ?? (() => process.exit(130)))();
  }

  private async readLine(opts: { signal?: AbortSignal; mask?: boolean } = {}): Promise<string> {
    let line = "";
    for (;;) {
      const chunk = await this.nextChunk(opts.signal);
      if (chunk === "") return line; // EOF
      for (let i = 0; i < chunk.length; i++) {
        const ch = chunk[i]!;
        if (ch === "\n" || ch === "\r") {
          let next = i + 1;
          if (ch === "\r" && chunk[next] === "\n") next += 1;
          const rest = chunk.slice(next);
          if (rest) this.buffer = rest + this.buffer;
          return line;
        }
        if (ch === "\x03") {
          // Ctrl+C during a raw-mode (masked) read.
          this.interrupt();
          const rest = chunk.slice(i + 1);
          if (rest) this.buffer = rest + this.buffer;
          return line;
        }
        if (ch === "\x7f" || ch === "\b") {
          if (line.length > 0) {
            line = line.slice(0, -1);
            if (opts.mask) this.io.write("\b \b");
          }
          continue;
        }
        line += ch;
        if (opts.mask) this.io.write("•");
      }
    }
  }

  /** Strict yes/no. A bare Enter re-prompts (never accepted as a default), so
   * an accidental keystroke can neither confirm nor reveal. After too many
   * unanswered prompts it returns false — the safe direction for a consent gate. */
  async confirmStrict(question: string, opts: { maxReprompts?: number } = {}): Promise<boolean> {
    const max = opts.maxReprompts ?? 3;
    for (let attempt = 0; attempt <= max; attempt++) {
      this.io.write(`${question} [y/n] `);
      const answer = (await this.readLine()).trim().toLowerCase();
      if (answer === "y" || answer === "yes") return true;
      if (answer === "n" || answer === "no") return false;
      if (answer === "") {
        this.io.write("Please type y or n.\n");
        continue;
      }
      this.io.write(`Didn't understand "${answer}". Type y or n.\n`);
    }
    return false;
  }

  /** Single choice from a numbered list; bare Enter selects defaultIndex. */
  async choose(title: string, options: string[], defaultIndex: number): Promise<number> {
    this.io.write(title + "\n");
    options.forEach((option, i) => this.io.write(`  ${i + 1}. ${option}\n`));
    for (;;) {
      this.io.write(`Choose [${defaultIndex + 1}]: `);
      const answer = (await this.readLine()).trim();
      if (answer === "") return defaultIndex;
      const value = Number(answer);
      if (Number.isInteger(value) && value >= 1 && value <= options.length) return value - 1;
      this.io.write(`Enter a number between 1 and ${options.length}.\n`);
    }
  }

  /** Numbered multi-select. The user types indices to toggle and presses Enter
   * to accept; the list re-renders after each toggle. Disabled items are shown
   * but cannot be toggled. */
  async multiToggle(title: string, items: ToggleItem[]): Promise<boolean[]> {
    const selected = items.map((item) => item.selected);
    for (;;) {
      this.io.write(title + "\n");
      items.forEach((item, i) => {
        const box = item.disabled ? "—" : selected[i] ? "x" : " ";
        const suffix = item.disabled ? ` (${item.disabled})` : "";
        this.io.write(`  ${i + 1} [${box}] ${item.label}${suffix}\n`);
      });
      this.io.write('Press Enter to continue, or type numbers to toggle (e.g. "2" or "1 3"): ');
      const answer = (await this.readLine()).trim();
      if (answer === "") return selected;
      for (const token of answer.split(/\s+/)) {
        const value = Number(token);
        if (Number.isInteger(value) && value >= 1 && value <= items.length) {
          const index = value - 1;
          if (!items[index]!.disabled) selected[index] = !selected[index];
        }
      }
    }
  }

  /** Free text. `mask` hides the value (for secrets — the key never reaches the
   * output stream). `allowEmpty` lets a bare Enter return "" (used for optional
   * keys the user wants to skip). Values stay in memory only (ADR-0004). */
  async textInput(label: string, opts: { mask?: boolean; allowEmpty?: boolean } = {}): Promise<string> {
    for (;;) {
      this.io.write(label);
      if (opts.mask) this.setRaw(true);
      let value: string;
      try {
        value = await this.readLine({ mask: opts.mask });
      } finally {
        if (opts.mask) {
          this.setRaw(false);
          this.io.write("\n");
        }
      }
      value = value.trim();
      if (value !== "" || opts.allowEmpty) return value;
      this.io.write("A value is required.\n");
    }
  }

  /** A line prompt that can be cancelled via AbortSignal — used for the OAuth
   * paste lane so the loopback callback can retire a pending question. */
  async question(query: string, opts: { signal?: AbortSignal } = {}): Promise<string> {
    this.io.write(query);
    return (await this.readLine({ signal: opts.signal })).trim();
  }

  /** Wait for a single keystroke (raw mode, no prompt). Ctrl+C triggers
   * onInterrupt. Used to advance/stop QR cycling. */
  async nextKey(): Promise<void> {
    this.setRaw(true);
    try {
      const chunk = await this.nextChunk();
      if (chunk.includes("\x03")) this.interrupt();
    } finally {
      this.setRaw(false);
    }
  }

  /** Print a message, then wait for a single keystroke. */
  async waitAnyKey(message: string): Promise<void> {
    this.io.write(message);
    await this.nextKey();
    this.io.write("\n");
  }
}

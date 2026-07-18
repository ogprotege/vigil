import os from "node:os";
import path from "node:path";

export interface ExecResult {
  stdout: string;
}

export type ExecFn = (command: string, args: string[]) => Promise<ExecResult>;

export interface DiscoveryOptions {
  homeDir?: string;
  platform?: NodeJS.Platform;
  env?: Record<string, string | undefined>;
  execFile?: ExecFn;
}

export function homeDir(opts: DiscoveryOptions): string {
  return opts.homeDir ?? os.homedir();
}

export function expandHome(p: string, opts: DiscoveryOptions): string {
  if (p.startsWith("~/") || p === "~") {
    return path.join(homeDir(opts), p.slice(2));
  }
  return p;
}

export async function defaultExecFile(command: string, args: string[]): Promise<ExecResult> {
  const { execFile } = await import("node:child_process");
  return new Promise((resolve, reject) => {
    execFile(command, args, { maxBuffer: 1024 * 1024 }, (err, stdout) => {
      if (err) reject(err);
      else resolve({ stdout });
    });
  });
}

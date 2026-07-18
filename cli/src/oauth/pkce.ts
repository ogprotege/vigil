import { createHash, randomBytes } from "node:crypto";

export interface Pkce {
  verifier: string;
  challenge: string;
  state: string;
}

export function generatePkce(): Pkce {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  // Anthropic's consent endpoint rejects short random state values with
  // "invalid request format"; state must be the 43-char verifier itself
  // (Claude Code's own convention, verified live 2026-07-18).
  return { verifier, challenge, state: verifier };
}

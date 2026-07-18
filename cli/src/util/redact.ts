const PATTERNS: RegExp[] = [
  // Anthropic OAuth/API tokens
  /sk-ant-[A-Za-z0-9_-]{8,}/g,
  // JWTs (Codex access/id tokens)
  /eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}(\.[A-Za-z0-9_-]{4,})?/g,
  // Any bearer value that slipped into a message
  /Bearer\s+[A-Za-z0-9._~+/=-]{8,}/g,
];

export function redact(text: string): string {
  let out = text;
  for (const pattern of PATTERNS) {
    out = out.replace(pattern, "[redacted]");
  }
  return out;
}

export function redactedMessage(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  return redact(raw);
}

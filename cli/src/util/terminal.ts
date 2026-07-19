/**
 * Removes terminal control sequences from one untrusted field. Callers keep
 * their own trusted newlines and indentation outside the sanitized value.
 */
export function sanitizeTerminalText(value: string, maximumLength = 512): string {
  const sanitized = value
    // OSC hyperlinks, titles, and clipboard operations, including C1 OSC.
    .replace(/(?:\x1B\]|\x9D)(?:[^\x07\x1B]|\x1B(?!\\))*(?:\x07|\x1B\\|$)/g, "")
    // DCS, SOS, PM, and APC strings terminated by ST or end of input.
    .replace(/(?:\x1B[P^_X]|\x90|\x98|\x9E|\x9F)[\s\S]*?(?:\x1B\\|\x9C|$)/g, "")
    // CSI sequences such as colors, cursor movement, and screen erasure.
    .replace(/(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]/g, "")
    // Remaining two-character escape sequences.
    .replace(/\x1B[ -/]*[@-~]/g, "")
    // C0, DEL, and C1 controls. Layout belongs to the trusted caller.
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, "");
  if (sanitized.length <= maximumLength) return sanitized;
  return sanitized.slice(0, Math.max(0, maximumLength - 1)) + "…";
}

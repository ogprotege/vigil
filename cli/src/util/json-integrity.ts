/**
 * Reject duplicate object keys before JSON.parse collapses them. Node keeps
 * the last duplicate while Foundation keeps the first, so accepting either
 * policy would let identical provider bytes map differently across runtimes.
 * Key strings are decoded semantically, catching `"x"` vs `"\u0078"`.
 */
export function jsonHasUniqueObjectKeys(text: string): boolean {
  let index = 0;
  let nodes = 0;

  const skipWhitespace = (): void => {
    while (index < text.length && /[ \t\r\n]/.test(text[index] as string)) index += 1;
  };

  const scanString = (): string | null => {
    if (text[index] !== '"') return null;
    const start = index;
    index += 1;
    while (index < text.length) {
      const char = text[index] as string;
      if (char === '"') {
        index += 1;
        try {
          const decoded: unknown = JSON.parse(text.slice(start, index));
          // Foundation strips a leading U+FEFF from every decoded JSON string,
          // while JSON.parse preserves it. Reject it from both runtimes before
          // a numeric value such as "\uFEFF1" can become 1 only on Apple.
          return typeof decoded === "string" && !decoded.startsWith("\uFEFF")
            ? decoded
            : null;
        } catch {
          return null;
        }
      }
      if (char === "\\") {
        index += 1;
        if (index >= text.length) return null;
      }
      index += 1;
    }
    return null;
  };

  const parseValue = (depth: number): boolean => {
    nodes += 1;
    if (nodes > 10_000 || depth > 64) return false;
    skipWhitespace();
    const char = text[index];
    if (char === "{") return parseObject(depth + 1);
    if (char === "[") return parseArray(depth + 1);
    if (char === '"') return scanString() !== null;
    const start = index;
    while (index < text.length && !/[ \t\r\n,}\]]/.test(text[index] as string)) index += 1;
    return index > start;
  };

  const parseObject = (depth: number): boolean => {
    index += 1;
    skipWhitespace();
    if (text[index] === "}") {
      index += 1;
      return true;
    }
    const keys = new Set<string>();
    while (index < text.length) {
      skipWhitespace();
      const key = scanString();
      if (key === null || keys.has(key)) return false;
      keys.add(key);
      skipWhitespace();
      if (text[index] !== ":") return false;
      index += 1;
      if (!parseValue(depth)) return false;
      skipWhitespace();
      if (text[index] === "}") {
        index += 1;
        return true;
      }
      if (text[index] !== ",") return false;
      index += 1;
    }
    return false;
  };

  const parseArray = (depth: number): boolean => {
    index += 1;
    skipWhitespace();
    if (text[index] === "]") {
      index += 1;
      return true;
    }
    while (index < text.length) {
      if (!parseValue(depth)) return false;
      skipWhitespace();
      if (text[index] === "]") {
        index += 1;
        return true;
      }
      if (text[index] !== ",") return false;
      index += 1;
    }
    return false;
  };

  if (!parseValue(0)) return false;
  skipWhitespace();
  return index === text.length;
}

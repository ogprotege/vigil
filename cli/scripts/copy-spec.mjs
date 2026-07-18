// Copies the canonical provider contract into dist/ so the published package
// is self-contained while the repo keeps a single source of truth.
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, "..", "..", "protocol", "providers.json");
const dest = join(here, "..", "dist", "providers.json");
mkdirSync(dirname(dest), { recursive: true });
copyFileSync(src, dest);
console.log(`copied providers.json -> ${dest}`);

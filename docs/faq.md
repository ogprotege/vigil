# Vigil FAQ

Short answers to the questions people actually ask. For step-by-step setup see [getting-started.md](getting-started.md); for specific failures see [troubleshooting.md](troubleshooting.md).

## Concepts

### What's the difference between a session, weekly, and model limit?

- A **session window** resets frequently — Claude's 5-hour window, Codex's session window. It's the one that stops you mid-flow.
- A **weekly window** is the longer cap that resets over the week.
- A **model limit** is a *separate* quota a platform enforces for one model. Claude tracks Opus and Sonnet weekly caps of their own, plus newer model-scoped weekly limits; Codex exposes per-model lanes; MiniMax has a video-model quota. Vigil shows each of these as its own window with its own reset time: in the provider's stacked bars on Home, and gathered tightest-first on the **Models** tab.

Vigil never blends these into one number — the overall limit and the model-specific one can be very different, and you need to see both.

### What does "percent left" mean, and why not "percent used"?

Vigil leads with **percent left** because that's the number you act on ("I have 15% of my weekly Opus quota"). The card also shows percent used. Vigil uses the provider's percentage when supplied, or computes the exact used-to-limit ratio when the provider supplies counts. It does not estimate from local activity.

### How do the reset countdowns stay live if Vigil only polls every few minutes?

The countdown ticks **client-side** from the reset time the provider last reported. Vigil computes the time remaining locally, so the number moves every second even though the underlying data was fetched minutes ago. When a window actually resets, the next fetch corrects it.

### What are balances, spend, and overage credits?

Some providers (API gateways) don't expose a reset-based percentage — they expose money. Vigil shows those as **metrics**: a balance, month-to-date spend, or a credit limit, in the provider's own currency. Claude's overage ("extra usage") credits show up here too — spend so far and the monthly limit. Vigil never invents a percentage for these or converts between currencies.

## Freshness and honesty

### Why does a card say "Stale", "Cooling down", "Re-link needed", or "Offline"?

Vigil would rather tell you the truth than show a confident wrong number:

- **Cooling down** — the provider is rate-limiting checks (a 429). Normal; it backs off and retries.
- **Stale** — the data is older than expected (a fetch didn't land). The last-known numbers are shown but marked.
- **Re-link needed** — the provider rejected the credentials (expired or revoked). Refresh the underlying sign-in and re-link.
- **Provider changed** — the response no longer matched what Vigil expected to map. Check for a Vigil update.
- **Offline** — a network problem reaching the provider.

### Why is polling capped at ~5 minutes?

Provider usage endpoints rate-limit hard — Claude will 429-jail anything polling faster than about 5 minutes, and often without a `Retry-After`. Vigil enforces a shared poll floor across the app, widgets, and menu bar so they never collectively trip that limit. This is a deliberate invariant, not a limitation to work around.

### I linked an account but it says it'll "verify on the next refresh" — is something wrong?

No. If your computer polled a provider very recently (for example you ran `vigil-link status` moments before linking), the CLI can't check that provider again without tripping the poll floor. Instead of dropping the account, Vigil includes it and lets your **phone** verify it on its next allowed refresh. It'll go live shortly.

## Security and privacy

### Are my credentials safe?

They travel only between your own devices and the providers you turn on, and they live in your device's Keychain. There is **no Vigil server**, no account, and no analytics. See [privacy.md](privacy.md) and [threat-model.md](threat-model.md).

### Is the QR code sensitive?

Yes. The `vigil1` QR (and the `--json` paste code) contains your credentials as compressed plaintext. Show it only somewhere private, don't screenshot or screen-share it, and clear your terminal scrollback afterward. Codes expire 10 minutes after they're generated. If a code was exposed, revoke the underlying credential.

### Does the CLI store anything?

Only poll timestamps and 429 counters, under your cache directory — never credentials or usage values ([ADR-0004](decisions/0004-stateless-cli.md)). Deleting that cache is safe but can cause one unnecessary provider request; it does not bypass a rate limit.

### Why does Vigil "mint" a separate Claude token instead of copying my Claude Code one?

Refresh tokens rotate. If Vigil and Claude Code both refreshed the same token pair, they'd de-sync and one would break. So by default Vigil mints its **own** token pair via a browser sign-in ([ADR-0005](decisions/0005-mint-dont-copy.md)). You can choose to copy instead, but a copied token can't be renewed and will eventually expire.

## Do I need the terminal?

No. Claude and ChatGPT/Codex both sign in right in the app (a browser approval and a short code), and every other provider is added by pasting its requested key or session credential (**Add account → Paste a provider key → <provider>**). The terminal (`npx vigil-link`) is only an optional shortcut if you would rather reuse a Claude Code or Codex sign-in already on a computer.

## Per-provider notes

- **OpenAI** needs a read-only **Admin** key, not a project (`sk-proj-...`) key — the billing endpoint rejects project keys.
- **GitHub Copilot** needs a fine-grained token *and* your username; org-managed seats report empty usage.
- **Moonshot** and **MiniMax** each have separate China providers — use the China variant for China-platform keys.
- **MiniMax**, **MiniMax China**, **Z.ai/GLM**, **Cursor**, and **Kimi K3** are marked **experimental** because their usage endpoints are undocumented or community-researched without a Vigil production capture. Moonshot global/China and xAI use vendor-documented endpoints and are opt-in, but not experimental. Cursor's session cookie expires, so re-paste it when needed.
- **Kimi K3** is the coding-plan usage view — session and weekly limits from a coding-plan key (`KIMI_CODE_API_KEY`), separate from the balance-only **Moonshot (Kimi)** provider.

See the [provider spec](provider-spec.md) for verified endpoint facts and the researched backlog.

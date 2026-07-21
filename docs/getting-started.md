# Getting started with Vigil

Vigil shows your AI usage, limits, spend, and balances on your iPhone (and Mac). This guide takes you from nothing installed to a working dashboard, and covers every provider you can add.

You do **not** need to be a developer, and you do **not** need a computer. Claude, ChatGPT/Codex, and every API-key provider are all set up entirely on the phone. (If you'd rather reuse a sign-in already on a computer, you still can — it's optional.)

---

## 1. Install the app

Vigil is on **TestFlight** (internal testing today; public beta next). Install it like any TestFlight app. Home-screen and lock-screen widgets are included.

## 2. Add your first account

Open Vigil and tap **Add account**. Almost everything can be done right on the phone.

### Sign in with Claude (on phone, no computer)

1. Tap **Add account → Sign in with Claude**.
2. Tap **Open Claude sign-in** — your browser opens Claude's approval page.
3. Approve access. Claude shows you a short **code**; copy it.
4. Come back to Vigil and paste the code, then tap **Finish signing in**.

Vigil exchanges the code for its own token that **renews itself automatically** — you won't have to sign in again. No computer, no terminal.

### Sign in with ChatGPT / Codex (on phone, no computer)

1. Tap **Add account → Sign in with Codex**.
2. Vigil shows you a short **code**. Tap **Open sign-in page** — ChatGPT's approval page opens.
3. Sign in and enter the code when asked.
4. That's it — Vigil detects the approval automatically and finishes signing in with its own renewable token. No computer, no `codex login`.

### Add an API-key provider (on phone, no computer)

Every API-key provider — OpenRouter, DeepSeek, Moonshot, MiniMax, OpenAI, GitHub Copilot, xAI, Z.ai, Cursor, Kimi K3 — is added entirely on the phone:

1. Tap **Add account → Add a provider directly**.
2. Pick the provider. Vigil asks only for the field(s) it needs and shows a hint for where to find them (see the table below).
3. Paste the key and save.

### Already signed in on a computer? (optional)

If you'd rather reuse the **Claude Code** or **Codex** sign-ins already on a computer, you can hand them to your phone with a QR. This is entirely optional — both can be set up on the phone directly (above).

1. On your computer, run `npx vigil-link` (needs [Node.js 20+](https://nodejs.org); `npx` downloads it, nothing to install permanently). It scans your machine, lets you pick accounts, and shows a QR.
2. On your iPhone, tap **Add account → Scan code** and point the camera at it. (On a Mac without a camera, use `npx vigil-link --json --yes` and **Paste code**.)

> The QR code contains your credentials — show it only somewhere private, don't screenshot or screen-share it, and clear your terminal scrollback afterward.

## 3. Read your dashboard

- **Home** opens on a period picker — **Day / Week / Month / Year / Life**. The hero beneath it names the tightest limit left across every account *for that range*, so switching periods changes which limit is in front of you.
- Under the hero, one stacked list gives each provider the windows that match the chosen period, with percent left, a live reset countdown, and how long ago it was updated. Pick **Week** to see weekly limits, **Day** for session limits.
- **Per-model caps** — Claude's Fable/Opus weekly lanes, Codex's per-model lanes, MiniMax's video quota — live on the **Models** tab, tightest first.
- If any account reports a balance or spend, Vigil shows how much it changed across the readings it took in the selected range. It only ever reports what a poll actually returned, never an estimate.
- Countdowns tick locally between fetches. If data is old or a provider changed something, the row says so instead of showing a stale number. Tapping refresh tells you what happened: fetched, deferred by the 5-minute poll floor (with the next safe time), or failed.

## Prefer the terminal?

```sh
npx vigil-link status   # your usage with reset countdowns, printed now
npx vigil-link doctor   # what credentials Vigil can find, and where it looked
```

`status` and `doctor` never display or transmit credentials; they only read local sign-ins and (for `status`) fetch usage.

---

## Where to get each provider's key

Claude and ChatGPT/Codex sign in right on the phone (**Add account → Sign in with Claude** / **Sign in with Codex**); reusing a sign-in already on a computer is optional. Every other provider is an API key you paste on the phone (**Add account → Add a provider directly**) or set as an environment variable before running `vigil-link`.

| Provider | Where to get it |
|---|---|
| **Claude** | **On the phone:** Add account → Sign in with Claude (browser approval + paste the code). Or hand over an existing Claude Code sign-in from a computer. |
| **ChatGPT / Codex** | **On the phone:** Add account → Sign in with Codex (open the page, enter the code Vigil shows). Or hand over an existing Codex CLI sign-in from a computer. |
| **OpenRouter** | An OpenRouter API key. Env var: `OPENROUTER_API_KEY`. |
| **DeepSeek** | A DeepSeek API key. Env var: `DEEPSEEK_API_KEY`. |
| **Moonshot (Kimi)** | `sk-...` key from **platform.kimi.ai → Console → API Keys**. China-platform keys use the Moonshot China provider. Env var: `MOONSHOT_API_KEY`. |
| **Moonshot (Kimi) China** | Key from **platform.moonshot.cn → Console → API Keys**. Env var: `MOONSHOT_CN_API_KEY`. |
| **MiniMax Coding Plan** | `sk-cp-...` key from **platform.minimax.io → User Center → Interface Key**. China keys use the MiniMax China provider. Env var: `MINIMAX_CODING_API_KEY`. |
| **MiniMax Coding Plan China** | Key from **platform.minimaxi.com → User Center → Interface Key**. Env var: `MINIMAX_CN_CODING_API_KEY`. |
| **OpenAI API** | A read-only **Admin** key from **platform.openai.com → Settings → Organization → Admin keys**. Regular `sk-proj-...` project keys are rejected by the billing endpoint. Env var: `OPENAI_ADMIN_KEY`. |
| **GitHub Copilot** | A fine-grained token (**Settings → Developer settings**, with *Account → Plan (read)* permission) plus your GitHub username. Org-managed Copilot seats report empty usage. Env vars: `GITHUB_BILLING_TOKEN` + `GITHUB_BILLING_USER`. |
| **xAI API** *(experimental)* | A **Management Key** from **console.x.ai → Settings → Management Keys**, plus your team ID (from console URLs). Env vars: `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID`. |
| **Z.ai / GLM Coding Plan** *(experimental)* | A GLM Coding Plan API key from **z.ai → Manage API Key**. Env var: `ZAI_API_KEY`. |
| **Cursor** *(experimental)* | While signed in at cursor.com, open **DevTools → Application → Cookies** and copy the `WorkosCursorSessionToken` value. It expires; re-paste when it does. Env var: `CURSOR_SESSION_TOKEN`. |
| **Kimi K3 (coding plan)** *(experimental)* | Your Kimi **coding-plan** API key from **platform.kimi.ai** — separate from the Moonshot balance key above; this one reports session and weekly coding-plan limits. Env var: `KIMI_CODE_API_KEY`. |

To link several providers from the terminal in one QR session, set the env vars and pass `--provider`:

```sh
OPENROUTER_API_KEY='...' DEEPSEEK_API_KEY='...' \
  npx vigil-link --provider claude,codex,openrouter,deepseek
```

(Passing `--provider` uses the classic scripted flow instead of the wizard.)

---

## What's next

- Concepts and edge cases: [FAQ](faq.md).
- Something not working: [Troubleshooting](troubleshooting.md).
- Full per-provider endpoint facts and the researched backlog: [Provider spec](provider-spec.md).
- Why the design is the way it is: [Architecture](architecture.md) and the [decision records](decisions/).

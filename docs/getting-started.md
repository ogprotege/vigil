# Getting started

Vigil runs on iOS 17 or later. Every account is set up on the phone. You do not need a computer or terminal.

## 1. Install Vigil

Install the current TestFlight build. Vigil includes Home Screen and Lock Screen widgets.

## 2. Add an account

Open Vigil and tap **Add account**.

### Sign in with Claude

1. Tap **Sign in with Claude**.
2. Tap **Open Claude sign-in**.
3. Approve access in the browser.
4. Copy the code Claude displays.
5. Return to Vigil, paste the code, and tap **Finish signing in**.

Vigil exchanges the code for its own access and refresh credentials. It can refresh only the credential pair it minted.

### Sign in with ChatGPT / Codex

1. Tap **Sign in with Codex**.
2. Note the short code Vigil displays.
3. Tap **Open sign-in page**.
4. Sign in and enter the code.
5. Return to Vigil. The app detects approval and finishes automatically.

OpenAI may require device-code authorization to be enabled under ChatGPT **Settings → Security**.

### Add another provider

1. Under **Paste a provider key**, choose the provider.
2. Read the field-specific guidance.
3. Paste the requested credential and any required account identifier.
4. Save the account.

Vigil stores the credential in Keychain. It does not upload it to a Vigil service.

## 3. Read the dashboard

- **Home** has the period picker: Day, Week, Month, Year, and Life.
- The hero shows the tightest applicable limit across linked accounts.
- Provider cards lead with plan-wide windows for the selected period and may include a compact subset of model or special lanes. Every bar includes percent left, reset time, and freshness.
- **Models** is the complete model-only list. It shows genuine model-specific or model-associated quota lanes and does not repeat ordinary session or weekly plan limits.
- Balance and spend values appear only when the provider returns them.

Countdowns tick locally. A moving countdown does not mean the app made another provider request.

Refresh outcomes are explicit:

- **Fetched** means the provider returned a response that satisfied its contract.
- **Deferred** means the account is still inside its poll floor.
- **Cooling down** means the provider returned a rate limit.
- **Provider changed** means a successful response no longer mapped completely enough to trust.
- **Re-link needed** means the provider rejected the credential.

## Provider credentials

| Provider | Credential and source |
|---|---|
| **Claude** | Use **Sign in with Claude**. Manual access-token entry exists for recovery, but pasted tokens do not auto-renew. |
| **ChatGPT / Codex** | Use **Sign in with Codex**. Manual entry requires both an access token and account ID, and does not auto-renew. |
| **OpenRouter** | Create an API key at **openrouter.ai → Keys**. |
| **DeepSeek** | Create an API key at **platform.deepseek.com → API Keys**. |
| **Moonshot (Kimi)** | Create a global-platform key at **platform.kimi.ai → Console → API Keys**. |
| **Moonshot (Kimi) China** | Create a China-platform key at **platform.kimi.com → Console → API Keys**. |
| **MiniMax Coding Plan** *(experimental)* | Create a global coding-plan key at **platform.minimax.io → User Center → Interface Key**. |
| **MiniMax Coding Plan China** *(experimental)* | Create a China coding-plan key at **platform.minimaxi.com → User Center → Interface Key**. |
| **OpenAI API** | Create a read-only organization **Admin key** at **platform.openai.com → Settings → Organization → Admin keys**. Project keys are rejected by the costs endpoint. |
| **GitHub Copilot** | Create a fine-grained token with **Account → Plan (read)** and enter your GitHub username. Organization-managed seats can report empty per-user usage. |
| **xAI API** | Create a Management Key with billing-read access at **console.x.ai → Settings → Management Keys** and enter the team ID shown in console URLs. |
| **Z.ai / GLM Coding Plan** *(experimental)* | Copy a GLM Coding Plan key from **z.ai → Manage API Key**. |
| **Cursor** *(experimental)* | While signed in at cursor.com, copy the `WorkosCursorSessionToken` cookie from browser developer tools. Re-paste it when the session expires. |
| **Kimi K3 coding plan** *(experimental)* | Copy a Kimi Code key from **kimi.com/code/console**. This key is separate from the Moonshot balance key. |

Global and China credentials are not interchangeable for Moonshot or MiniMax. Select the provider that matches the credential's platform.

## Add a widget

1. Add a Vigil widget from the iOS widget gallery.
2. Long-press the widget and choose **Edit Widget**.
3. Select a linked account.

An unconfigured widget uses the first linked account. A widget configured for a removed account stays empty rather than silently switching accounts.

WidgetKit controls when refresh work runs. The widget may display a locally ticking countdown while its underlying usage snapshot ages.

## Next steps

- Concepts and provider notes: [FAQ](faq.md).
- Specific failures: [Troubleshooting](troubleshooting.md).
- Provider evidence and endpoint status: [Provider registry and support](provider-spec.md).
- Storage and network boundaries: [Privacy](privacy.md) and [Threat model](threat-model.md).

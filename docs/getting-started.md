# Getting started

Vigil runs on iOS 17 or later. Claude, ChatGPT/Codex, and ordinary provider keys are set up in the app. Experimental credentials copied from a desktop browser, such as Cursor's session cookie, are the exception.

## 1. Install Vigil

Install the current TestFlight build. Vigil includes Home Screen and Lock Screen widgets.

## 2. Add an account

Open Vigil. A new installation presents **Connect Claude**, **Connect ChatGPT / Codex**, and **Other provider**. Guided sign-in appears before manual credentials.

### Sign in with Claude

1. Tap **Connect Claude**.
2. Tap **Open Claude sign-in**.
3. Approve access in the browser.
4. Copy the code Claude displays.
5. Return to Vigil, paste the code, and tap **Finish signing in**.

Vigil exchanges the code for its own access and refresh credentials. It can refresh only the credential pair it minted.

### Sign in with ChatGPT / Codex

1. Tap **Connect ChatGPT / Codex**.
2. Note the short code Vigil displays.
3. Tap **Open sign-in page**.
4. Sign in and enter the code.
5. Return to Vigil. The app detects approval and finishes automatically.

OpenAI may require device-code authorization to be enabled under ChatGPT **Settings → Security**.

### Add another provider

1. Tap **Other provider**, then choose the provider.
2. Read the field-specific guidance.
3. Paste the requested credential and any required account identifier.
4. Tap **Verify and add account**.

Vigil stores the credential in Keychain. It does not upload it to a Vigil service.

## 3. Read Limits

- **Limits** shows the linked account that requires attention first.
- Each account row shows one decisive provider window, percent left, reset time, and freshness.
- Open an account to see every current provider window, balance, spend value, and genuine model-specific cap.
- Current quotas use their provider-defined window names. Calendar filters are not applied to reset windows.
- **Observed by Vigil** contains each successful reading this device retained after linking. Distinct fetch times remain distinct even when usage did not change. The SQLite archive keeps rows for up to 400 days and up to 120,000 observations per account.
- **Imported from provider** contains official historical buckets when a supported administrative API and credential are available. This source has its own 5,000-record cap per account, so an import cannot evict observed readings. The current OpenAI import requests up to 365 days of API organization completion-token usage and organization costs. Costs remain separate from token groups, and these rows are not ChatGPT or Codex subscription history.
- Tap the **View all ... records** action to load the retained archive in cursor-paged batches. Account detail does not load the whole database at once.
- A subscription plan label identifies the provider's allowance tier. Exact used and limit amounts appear only when the provider supplies both. Vigil does not derive a fixed token ceiling from a workload-dependent Claude or Codex plan.

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
| **OpenAI API** | Create a dedicated API-platform organization **Admin API key** at **platform.openai.com → Settings → Organization → Admin keys**. This is a broad organization-owner credential, not a read-only key. Vigil sends only documented Usage and Costs GET requests, but the key itself can authorize more. Revoke it when you stop using the integration. Project keys are rejected by the organization endpoints. |
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

Successful widget checks also enter on-device history. iOS still decides when widget and background work executes, so an observed timeline can contain gaps.

The five-minute provider cooldown is a minimum between requests. It does not guarantee five-minute background samples.

## Protect Vigil

Open **Settings** and enable **Require Face ID or Touch ID** to lock the app when it returns to the foreground. Vigil uses Apple's device-owner authentication, including the system passcode fallback, and stores no biometric data. It also places an opaque cover over account content whenever the app becomes inactive or backgrounded so app-switcher snapshots do not reveal usage. The setting does not hide a configured widget.

## Export diagnostics

Open **Settings** and choose **Export diagnostic report** to create a JSON support file. The report includes current snapshots and a bounded recent history selection for each account and source, not the full SQLite archive. It states both retained and exported sample counts. The export contains generated aliases plus numeric, date, status, source, and trusted provider fields. It omits provider-controlled window, metric, and quantity identifiers, labels, and units. It excludes account and plan labels, access tokens, refresh tokens, cookies, authorization headers, Keychain data, credential fingerprints, provider project or API-key identifiers, and raw provider responses.

If Vigil repaired a damaged account index, review the recovered accounts first. Then use **Settings → Delete account repair backup** to delete only the preserved damaged copy. That standalone action does not delete any linked account, credential, snapshot, or history row.

## Next steps

- Concepts and provider notes: [FAQ](faq.md).
- Specific failures: [Troubleshooting](troubleshooting.md).
- Provider evidence and endpoint status: [Provider registry and support](provider-spec.md).
- Storage and network boundaries: [Privacy](privacy.md) and [Threat model](threat-model.md).

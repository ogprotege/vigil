# Set up Vigil

Vigil requires iOS 17 or later. All account setup happens on the iPhone, except that some experimental credentials may first need to be copied from a provider website.

> Last reviewed: 2026-08-04
>
> Review again: when setup or provider support changes

## Choose a setup route

On first launch, choose one of the guided routes or the catalog:

- **Connect Claude** uses Claude's browser approval flow.
- **Connect ChatGPT / Codex** uses OpenAI's device authorization flow.
- **Connect Grok Build** uses xAI's OIDC device authorization flow (the same family of code-and-URL sign-in as the Grok Build terminal).
- **Other provider** opens the supported provider catalog.

The current setup interface does not expose manual token entry for Claude, ChatGPT/Codex, or Grok Build on the primary route. Use their guided sign-in or the guided re-link action.

## Connect Claude

1. Tap **Connect Claude**.
2. Tap **Open Claude sign-in**.
3. Sign in and approve access in the browser.
4. Copy the full code Claude displays.
5. Return to Vigil and paste the code.
6. Tap **Finish signing in**.

Vigil exchanges that one-time code for the renewable credential pair used by this connection. If Claude rejects an expired code, reopen sign-in and copy a new one.

## Connect ChatGPT / Codex

1. In ChatGPT, open **Settings → Security** and enable **Device code authorization**.
2. In Vigil, tap **Connect ChatGPT / Codex**.
3. Wait for Vigil to display a short code.
4. Tap **Open sign-in page**.
5. Approve Vigil and enter the displayed code when OpenAI asks.
6. Return to Vigil. It completes the connection after OpenAI confirms approval.

ChatGPT/Codex subscription sign-in is separate from the OpenAI API organization integration. It cannot import OpenAI API usage or cost history.

## Connect Grok Build

This is essentially the same authentication pattern as the Grok Build desktop CLI. On a Mac or Linux terminal, `grok` / `/login` (or `grok login`) opens a URL with a short user code; after you approve in the browser, the CLI stores a renewable session in `~/.grok/auth.json`. In Vigil:

1. Tap **Connect Grok Build**.
2. Wait for Vigil to display a short code (the same kind of device code the CLI shows).
3. Tap **Open sign-in page** (or open the xAI device URL on any browser).
4. Sign in if needed, enter the code, and approve access.
5. Return to Vigil. It finishes the connection and mints its **own** renewable credential pair for this iPhone.

Vigil does **not** read `~/.grok/auth.json` or any other desktop client store. The phone completes device authorization itself and keeps the tokens in the iPhone Keychain. Only credentials marked as minted by Vigil auto-renew; a manually pasted session token does not.

Grok Build is separate from the **xAI API** prepaid-balance integration under **Other provider**. Use Grok Build for Grok CLI / Grok Build credit usage; use xAI API only for Management Key prepaid balance. The integration is experimental because the billing endpoint is undocumented, even though it is the same chat-proxy path the CLI uses.

## Connect another provider

Choose **Other provider**, select a provider, and follow the credential instructions shown in the app.

The current catalog contains:

| Provider | Credential required | Status |
|---|---|---|
| OpenRouter | API key | Established |
| DeepSeek | API key | Established |
| Moonshot (Kimi) | Global-platform API key | Established |
| Moonshot (Kimi) China | China-platform API key | Established |
| OpenAI API | Organization Admin API key | Established, broad privilege |
| GitHub Copilot | Fine-grained token with Account Plan read permission, plus username | Established |
| xAI API | Management Key with billing-read access, plus team ID | Established |
| Grok Build | Guided xAI device authorization (or a session token for recovery) | Experimental |
| MiniMax Coding Plan | Global coding-plan key | Experimental |
| MiniMax Coding Plan China | China coding-plan key | Experimental |
| Z.ai Coding Plan | GLM Coding Plan key | Experimental |
| Cursor | `WorkosCursorSessionToken` browser cookie | Experimental |
| Kimi K3 | Kimi Code key | Experimental |

Global and China platform credentials are not interchangeable. Kimi K3 uses a coding-plan key, not the Moonshot open-platform key.

An OpenAI organization Admin API key is not a read-only project key. It carries broad organization-owner authority. Create a dedicated key, store it only where intended, and revoke it at the provider when the integration is no longer needed. Vigil uses it for documented Usage and Costs `GET` requests, but its underlying provider authority is broader.

Perplexity is not supported in this release. There is no Perplexity entry hidden under **Other provider**.

## Verification and “Save anyway”

Vigil normally verifies a credential before saving it.

**Save anyway** appears only when verification could not produce an accepted reading through no fault of the credential: a network problem, Vigil's shared provider cooldown, or a provider response this version of Vigil cannot read ([When a provider changes](provider-changes.md)). Choosing it stores the account and credential without an accepted usage reading. The next allowed successful refresh must establish the first reading.

This option does not turn an unsupported provider into a supported one. It also does not bypass a provider rejection or malformed credential check.

## Add a widget

1. Add Vigil from the iOS widget gallery.
2. Long-press the widget and choose **Edit Widget**.
3. Select a linked account.

Vigil supports a small Home Screen widget and a circular Lock Screen widget. An unconfigured widget uses the first linked account. A widget set to a removed account stays empty rather than switching silently.

Widgets share the app's provider cooldown. WidgetKit controls their schedules, so a countdown can move while the provider reading becomes stale.

## Re-link or remove an account

Open **Accounts** from the Limits toolbar.

- Open an account and choose **Re-link** when Vigil says **Re-link needed**.
- Choose **Remove account** to delete that account's credential and saved Vigil data from the iPhone.

Removal does not close the provider account or revoke provider-side credentials. Revoke a copied API key, management key, or session credential with the provider when appropriate.

If damaged history prevents safe account-only removal, Vigil asks whether it may delete all local Vigil history to finish. Do not approve that broader deletion unless you accept losing observed and imported history for every linked account.

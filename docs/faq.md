# Vigil FAQ

For setup, read [Getting started](getting-started.md). For failures, read [Troubleshooting](troubleshooting.md).

## Concepts

### What is the difference between a session, weekly, and model limit?

- A **session window** resets frequently, such as Claude's 5-hour window.
- A **weekly window** is a longer provider-defined quota. It may cover a plan, model, or feature.
- A **model limit** is a separate quota for a specific model or model family.

Limits shows the decisive, most urgent provider window for each account. That window can be plan-wide, model-specific, or feature-specific. Account detail contains every real current window. Vigil never substitutes an ordinary weekly limit to fill a model section.

### What does percent left mean?

Vigil leads with the amount left because that is the actionable value. It uses the provider's percentage when available, or computes an exact used-to-limit ratio when the provider supplies both counts. It does not estimate utilization from local activity.

### Can Vigil work out a limit from my subscription tier?

Only when the provider defines a fixed entitlement or returns the exact limit. A subscription tier identifies an allowance class, and Vigil keeps that plan label beside the live provider windows. When the provider returns `used` and `limit`, Vigil shows the exact amounts and remaining value.

Claude and Codex allowances can vary with model, prompt size, files, task complexity, and other workload factors. Their plan names and published multipliers do not establish one stable token or message denominator. Vigil therefore shows the real percentage, reset time, credits, and any plan the provider actually reports, without inventing an absolute ceiling.

### How do countdowns move between provider checks?

The provider reports a reset time. Vigil updates the countdown locally from that timestamp. A moving countdown does not mean another provider request occurred.

### What are balances, spend, and overage credits?

Some providers expose money or credits rather than a reset-based percentage. Vigil shows these as metrics in the provider's reported unit. It does not invent a denominator or convert currencies.

### Does Vigil keep history on the iPhone?

Yes. Every accepted successful provider reading can enter a protected SQLite archive in the App Group shared by the app and widget. Distinct fetch times remain distinct even when usage did not change. Rows are retained for up to 400 days. Each account has separate caps of 120,000 **Observed by Vigil** readings and 5,000 **Imported from provider** records. The full retained archive loads in cursor-paged batches rather than all at once.

Observed history begins after an account is linked and can contain gaps because iOS controls background execution. Vigil does not reconstruct token counts from percentages or claim access to another app's private cache. The current official import covers OpenAI API organization completion-token and cost buckets only. It is not ChatGPT or Codex subscription history.

### Can Vigil export its cached data?

Yes. A user-initiated diagnostic export contains generated aliases plus numeric, date, status, source, and trusted provider fields from normalized snapshots and a bounded recent history selection. It reports both total retained and exported sample counts, so the subset is explicit. It omits provider-controlled identifiers, labels, and units. It excludes free-form account and plan labels, credentials, cookies, authorization headers, raw provider bodies, Keychain data, credential-derived account identifiers, and OpenAI project or API-key identifiers.

Vigil's own on-device archive is separate from another app's cache. Current
provider and token-exchange requests do not persist HTTP responses or cookies.
Vigil removes its app-scoped legacy network residue, but iOS does not permit it
to extract another app's private cache or login store.

The diagnostic report is support data, not a complete archive backup. Use the retained and exported counts in `historyScope` to see exactly how much history the report includes.

## Freshness and honesty

### Why does Vigil poll no faster than every five minutes?

Provider usage endpoints rate-limit aggressively. Every current registry entry declares a 300-second minimum. The app and widgets share account-level leases so only one process can pass the gate at a time.

That minimum is a request floor, not a promise of five-minute observations. iOS and WidgetKit decide when background work can run.

### What do the account states mean?

- **Live:** the latest response satisfied the provider's required-output contract.
- **Stale:** the last accepted values are older than expected.
- **Cooling down:** the provider rate-limited Vigil.
- **Re-link needed:** the credential was rejected.
- **Provider changed:** the response shape no longer mapped completely enough to trust.
- **Offline:** a network or transport failure prevented the request.

### Why can a provider show Provider changed when one value still mapped?

Partial output can be misleading. A provider that promises windows cannot be labeled Live merely because an unrelated balance or spend metric survived. Required-output contracts make missing essential values fail closed.

## Accounts

### What is the account repair backup in Settings?

If Vigil repairs a damaged account index, it preserves the unreadable copy for recovery review. After confirming that the recovered accounts are correct, use **Settings → Delete account repair backup** to remove only that damaged copy. This standalone action does not remove linked accounts, Keychain credentials, snapshots, or usage history. It is separate from **Erase Vigil data and start over**, which appears only when identity data cannot be recovered safely.

### Do I need a computer or terminal?

Not for Claude, ChatGPT/Codex, or ordinary provider keys. Vigil itself is iOS-only. An experimental integration that relies on a browser session cookie, such as Cursor, can require a desktop browser to obtain that credential.

### Why does Vigil mint separate Claude and Codex credentials?

Refresh credentials can rotate. Sharing one refresh pair with another client can break one of the clients after rotation. Vigil therefore mints and refreshes its own credentials through phone-native sign-in.

A manually pasted token is treated as externally owned and is not auto-refreshed.

### Why does Codex need a device code?

OpenAI's device authorization allows a public client to obtain its own credential without embedding a client secret or intercepting another app's session. Vigil shows the code and polls only at the interval OpenAI returns.

### Why does Cursor use a cookie?

Cursor does not offer a documented personal usage API credential. The experimental integration uses the signed-in web session cookie. It expires and must be pasted again.

## Security and privacy

### Where are credentials stored?

In Apple Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. They do not sync through iCloud Keychain. The app and widget share access through the configured Keychain group.

### Does Vigil collect data?

No. Vigil has no collection server, analytics SDK, advertising SDK, or cloud synchronization service. Activated providers still receive direct usage requests under their own privacy policies.

### What local data is not in Keychain?

The App Group container stores account labels, usage snapshots, the SQLite history archive, poll leases, and notification metadata. These files contain no bearer credential, but they can reveal usage, balance, spend, and timing information. Earlier money-only rows are migrated once into normalized observed history, then the retired file is removed.

### What does the app lock protect?

The optional setting uses Apple's device-owner authentication, with Face ID, Touch ID, or passcode as iOS permits. Vigil stores no biometric data. Locked content is hidden from interaction and accessibility, and an opaque cover hides app content whenever the scene is inactive or backgrounded so it does not appear in the app switcher. This lock does not add separate encryption to local files or hide a configured widget.

### What is deleted when I remove an account?

Vigil first invalidates the account across the app and widget. It then removes Keychain credentials, current and prior snapshots, observed and imported history rows, legacy observations, pending events, account-derived lock files, queued and delivered notifications, poll state, and damaged account-index backups. Required failures keep the account visible so removal can be retried.

### What if Vigil says its account identity data is damaged?

Vigil blocks linking and removal rather than guessing around an unreadable index, Keychain payload, or lifecycle registry. Open **Settings** and read the **Erase Vigil data and start over** confirmation. That last-resort action permanently deletes every local Vigil credential, account reference, snapshot, history row, notification, and polling record from this iPhone. It does not delete the provider accounts themselves.

## Provider support

### What does experimental mean?

The endpoint lacks both a stable vendor contract and a sanitized Vigil production capture. The mapping may be based on a maintained community client. Experimental providers remain visible but carry the label in account and picker surfaces.

### Does a passing fixture prove a provider works live?

No. A fixture proves that Vigil maps the committed example deterministically. `protocol/fixture-provenance.json` records whether the source was a live sanitized body, vendor example, community research, or synthetic case.

### Why are some providers balance-only?

That is the only meaningful value their supported endpoint returns. Vigil does not turn a balance into a fake utilization percentage.

### Important provider notes

- OpenAI organization Usage and Costs APIs require an API-platform organization Admin API key, not a project key. This credential has broad organization-owner access. Vigil sends only the documented GET requests, so use a dedicated key and revoke it when you stop using the integration.
- GitHub Copilot needs both a fine-grained token and username. Organization-managed seats can report empty personal usage.
- Moonshot and MiniMax use separate global and China key namespaces.
- Kimi K3 coding-plan usage is separate from Moonshot open-platform balances.
- MiniMax, MiniMax China, Z.ai, Cursor, and Kimi K3 are experimental.

See [Provider registry and support](provider-spec.md) for endpoint details and evidence levels.

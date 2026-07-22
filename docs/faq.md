# Vigil FAQ

For setup, read [Getting started](getting-started.md). For failures, read [Troubleshooting](troubleshooting.md).

## Concepts

### What is the difference between a session, weekly, and model limit?

- A **session window** resets frequently, such as Claude's 5-hour window.
- A **weekly window** is the longer plan-wide cap.
- A **model limit** is a separate quota for a specific model or model family.

Home leads with plan-wide windows and can include a compact subset of model or special lanes. Models is the complete model-only list. Vigil never substitutes an ordinary weekly limit just to fill that tab.

### What does percent left mean?

Vigil leads with the amount left because that is the actionable value. It uses the provider's percentage when available, or computes an exact used-to-limit ratio when the provider supplies both counts. It does not estimate utilization from local activity.

### How do countdowns move between provider checks?

The provider reports a reset time. Vigil updates the countdown locally from that timestamp. A moving countdown does not mean another provider request occurred.

### What are balances, spend, and overage credits?

Some providers expose money or credits rather than a reset-based percentage. Vigil shows these as metrics in the provider's reported unit. It does not invent a denominator or convert currencies.

## Freshness and honesty

### Why does Vigil poll no faster than every five minutes?

Provider usage endpoints rate-limit aggressively. Every current registry entry declares a 300-second minimum. The app and widgets share account-level leases so only one process can pass the gate at a time.

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

### Do I need a computer or terminal?

No. Vigil is iOS-only and every account is added on the phone.

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

The App Group container stores account labels, usage snapshots, observation history, poll leases, and notification metadata. These files contain no bearer credential, but they can reveal usage, balance, spend, and timing information.

## Provider support

### What does experimental mean?

The endpoint lacks both a stable vendor contract and a sanitized Vigil production capture. The mapping may be based on a maintained community client. Experimental providers remain visible but carry the label in account and picker surfaces.

### Does a passing fixture prove a provider works live?

No. A fixture proves that Vigil maps the committed example deterministically. `protocol/fixture-provenance.json` records whether the source was a live sanitized body, vendor example, community research, or synthetic case.

### Why are some providers balance-only?

That is the only meaningful value their supported endpoint returns. Vigil does not turn a balance into a fake utilization percentage.

### Important provider notes

- OpenAI organization costs require a read-only Admin key, not a project key.
- GitHub Copilot needs both a fine-grained token and username. Organization-managed seats can report empty personal usage.
- Moonshot and MiniMax use separate global and China key namespaces.
- Kimi K3 coding-plan usage is separate from Moonshot open-platform balances.
- MiniMax, MiniMax China, Z.ai, Cursor, and Kimi K3 are experimental.

See [Provider registry and support](provider-spec.md) for endpoint details and evidence levels.

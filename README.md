# Vigil

Vigil answers one question: **which AI limit needs your attention next?**

It is an iPhone app for viewing provider-reported limits, reset times, balances, spend, and retained observations. The Home screen ranks linked accounts by urgency. Account detail shows every accepted limit and metric returned for that account.

> Current documentation
>
> Last reviewed: 2026-07-26
>
> Review again: before each release

## What Vigil does

- Connects Claude and ChatGPT/Codex through guided sign-in on the iPhone.
- Connects supported API and coding-plan providers with the credential they issue.
- Shows percentages, exact amounts, balances, and spend only when the provider returns them.
- Keeps successful observations in a protected local history archive.
- Imports official OpenAI API organization completion usage and costs when an OpenAI Admin API account is linked.
- Provides Home Screen and Lock Screen widgets.
- Sends local alerts when an observed quota crosses 80% or 95% utilization.
- Exports bounded, credential-free diagnostic JSON when the user asks.

Vigil has no Vigil account, collection server, analytics SDK, advertising SDK, or cloud synchronization service. Provider requests go from the app to providers the user activates.

## What Vigil does not do

Vigil is not a universal token counter. It cannot:

- read the private cache, database, cookies, or login state of another iPhone app;
- recover Claude, ChatGPT, Codex, or other subscription history that a provider does not expose;
- convert a subscription name into a fixed token or message ceiling;
- guarantee a background sample every five minutes, because iOS controls background execution;
- treat OpenAI API organization history as ChatGPT or Codex subscription history; or
- monitor Perplexity usage credits in the current release.

## Set up an account

Vigil requires iOS 17 or later.

1. Open Vigil.
2. Choose **Connect Claude**, **Connect ChatGPT / Codex**, or **Other provider**.
3. Finish the provider's guided sign-in or enter the requested credential.
4. Open an account from **Limits** to inspect all current data and retained history.

Claude and ChatGPT/Codex use their guided routes. The current interface does not offer manual Claude or Codex token entry.

See the [setup guide](docs/user-guide/setup.md) for provider requirements and recovery behavior.

## Read the result honestly

- **Percent left** is derived from a utilization percentage returned by the provider.
- **Used, limit, or remaining** appears only when the provider returns the needed amount fields.
- A **plan label** gives context. It is not proof of a fixed token allowance.
- **Observed by Vigil** means the app retained a successful reading after the account was connected.
- **Imported from provider** means a supported provider returned historical administrative buckets.
- A passed reset is not assumed to mean zero use. Vigil hides the old quota until a provider update confirms the new value.

Read [How to read limits](docs/user-guide/reading-limits.md) and [History and imports](docs/user-guide/history-and-imports.md) for the full rules.

## Privacy boundaries

Credentials are stored in the device-bound Keychain. Normalized snapshots, history, and polling metadata live in Vigil's App Group container for the app and widget. The optional app lock does not hide widgets. Notification previews can show a provider name, quota window, and utilization on the Lock Screen.

**On this iPhone** means Vigil does not run a sync service. It does not mean every local file is excluded from Apple-managed device backups. Read [Privacy, deletion, and notifications](docs/user-guide/privacy-deletion-notifications.md) before linking a broad administrative credential.

## Documentation

- [Documentation index](docs/index.md)
- [Product contract](docs/product-contract.md)
- [Setup](docs/user-guide/setup.md)
- [Reading limits](docs/user-guide/reading-limits.md)
- [History and imports](docs/user-guide/history-and-imports.md)
- [Privacy, deletion, and notifications](docs/user-guide/privacy-deletion-notifications.md)
- [Troubleshooting](docs/user-guide/troubleshooting.md)

## Project status

These docs describe Vigil 0.15.0, build 16. Runtime provider behavior can change outside Vigil's control. Experimental integrations are marked during setup because their vendor contracts or production evidence are incomplete.

Vigil was inspired by [token-monitor](https://github.com/Javis603/token-monitor). Desktop transcript and cache access do not carry over to an iOS-only app, so Vigil reports only data it can obtain and label honestly.

## Funding

<a href="https://www.buymeacoffee.com/thebiscuit"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="60" width="217"></a>

## License

Vigil is licensed under the [MIT License](LICENSE).

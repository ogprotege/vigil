# Privacy

Vigil's privacy model is one sentence: **your credentials and usage data never leave your devices.**

- There is no Vigil server, no Vigil account, no cloud sync, no analytics, no crash reporting that phones home.
- Credentials exist in exactly three places, all yours: the provider's own files on your computer (`~/.claude`, `~/.codex` — put there by tools you already use), transiently in the `vigil-link` process and the QR code on your screen while linking, and your device Keychain (`ThisDeviceOnly`, so not even iCloud Keychain sync).
- The app's only network traffic is direct calls to the providers you linked (Anthropic, OpenAI, …) using your own credentials — the same calls those vendors' own tools make.
- The `vigil-link` CLI is stateless: it writes nothing to disk, ever. Audit it — it's small on purpose.
- Removing an account in the app deletes its Keychain items immediately.

App Store privacy label: **Data Not Collected** — defensible because it is true.

Because Keychain items are `ThisDeviceOnly`, each device is linked with its own scan. That is a feature: no credential ever transits a sync service.

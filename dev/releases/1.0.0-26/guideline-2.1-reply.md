# Guideline 2.1 reply — Vigil 1.0.0 (26)

> Status: draft for App Store Connect Notes after the physical-device
> recording exists. Never commit reviewer credentials, personal contact
> information, or a private recording URL.

Paste the numbered sections below into App Review Information. Keep the
dedicated Grok Build account in the protected demo-account fields.

The recording script is
[`app-review-recording.md`](app-review-recording.md).

## 1. Screen recording

A screen recording captured on a physical iPhone running the latest installed
iOS is attached to this reply. It starts at launch and shows:

- first-run dashboard
- Connect Grok Build device authorization
- dashboard and account detail
- pull-to-refresh
- Settings appearance, widget privacy, generic notifications, automatic-check
  pause, and app lock
- lock/unlock
- account removal and the empty dashboard

Vigil has no Vigil account, in-app purchase, user-generated content, or
prompts for location, contacts, camera, or tracking.

## 2. Devices and operating systems tested

- Physical iPhone: fill in model and iOS version after the recording.
- Automated suite: Vigil Test iPhone simulator, iOS 26.5.
- Supported platforms: iPhone and iPad, iOS 17 and later.

## 3. Functions and audience

Vigil is a native iPhone and iPad utility for people who already have AI
provider accounts and need current quotas, reset times, balances, credits,
spend, and provider-returned budget controls in one dashboard and optional
widgets.

It does not generate AI content, accept prompts, proxy chat, sell provider
access, or unlock subscriptions. There is no Vigil server, analytics,
advertising, or in-app purchase. Credentials stay in Apple Keychain. The
native value is the cross-provider ranking, bounded on-device history,
shared cooldown, widgets, local notifications, and a device-owner app lock.

## 4. Setup and access

1. Launch Vigil and choose Add account.
2. Select Connect Grok Build.
3. Wait for the device code and choose Open sign-in page.
4. Sign in on xAI's page with the protected App Store Connect demo account,
   approve access, and enter the one-time code.
5. Return to Vigil. The dashboard shows only data Grok Build returned.
6. Open the account card for windows, credits, reset times, freshness, and
   bounded observed history.
7. Pull down to refresh. Open Settings for appearance, privacy, alerts,
   automatic checks, and app lock.
8. Open Accounts and remove the connection to delete the local credential
   and Vigil data.

Provider values can be percentage-only, empty, rate-limited, or temporarily
unavailable. Vigil does not invent missing denominators.

## 5. External services

Vigil has no developer-operated service. The device talks only to a provider
the user chooses to connect:

- Anthropic Claude — OAuth and consumer usage windows
- OpenAI ChatGPT / Codex — device authorization and subscription usage
- OpenRouter — guided key mint or pasted API key; usage and optional limits
- DeepSeek, Moonshot global/China — API balances
- MiniMax global/China — coding-plan windows (Experimental)
- OpenAI API — organization cost and optional official history import
- GitHub Copilot — account-plan AI credits
- xAI API — prepaid Management Key balance
- Grok Build — device authorization and coding-plan credits (Experimental)
- Z.ai Coding Plan, Cursor, Kimi K3 — experimental coding-plan or session
  credentials

Local Apple services: Keychain, App Groups, BackgroundTasks, WidgetKit,
UserNotifications, LocalAuthentication, and user-initiated document export.
No analytics, ads, crash reporters, payments, or generative-AI SDKs.

## 6. Regional differences

The app feature set is the same in every included storefront. China mainland
is excluded. Provider eligibility, endpoints, and plan values can still
differ by the user's own provider account. Global and China provider rows
are separate and need the matching credential.

## 7. Regulated industry or protected material

Not applicable. Vigil is a usage-monitoring utility. It does not provide
banking, payments, lending, investing, insurance, gambling, or medical
services. Currency values are provider-returned usage, balances, and budget
controls, not financial products.

Vigil reads only account metadata the user authorizes. It does not
redistribute provider models, chat content, or copyrighted third-party
material.

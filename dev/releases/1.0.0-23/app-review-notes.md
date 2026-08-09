# Vigil 1.0.0 App Review notes

> Status: prepared text with submission blockers; do not paste into App Store
> Connect until every `BLOCKED` item is resolved
>
> Never commit reviewer credentials, personal contact information, or a private
> recording URL to this repository. Put those values directly into App Store
> Connect's protected review fields.

## 1. Physical-device screen recording

**BLOCKED:** Attach or link a recording captured on a physical iPhone. It must
begin at launch and show:

1. the empty first-run dashboard;
2. linking the dedicated reviewer provider account;
3. the resulting current dashboard and account detail;
4. pull-to-refresh;
5. System, Light, and Dark appearance;
6. alert, notification-detail, and widget-privacy settings;
7. pausing automatic checks while manual refresh remains available; and
8. removing the connection and confirming local deletion.

If the reviewer account is Grok Build, also show device authorization, the
Experimental label, returned credit usage, and re-linking. Blur the one-time
code, account identity, and any values that are not part of the dedicated
review account.

## 2. App purpose

Vigil is a native iPhone and iPad utility that lets people see current AI
provider quotas, reset times, balances, credits, spend, and provider-returned
budget controls in one focused dashboard and in optional widgets. It ranks the
tightest returned limit first, keeps bounded local observations, supports local
80% and 95% threshold notifications, and provides privacy controls for widgets,
notification text, automatic checks, and app-surface authentication.

Vigil does not generate AI content, accept prompts for an AI model, proxy chat
messages, sell provider access, or unlock provider subscriptions. It reads only
usage and billing metadata for provider accounts the user independently owns.
There is no Vigil account, developer backend, analytics, advertising, or in-app
purchase.

The native value beyond a provider website is the cross-provider dashboard,
urgency ranking, bounded on-device history, shared cooldown/backoff behavior,
Home and Lock Screen widgets, local notifications, biometric app lock, and
privacy controls.

## 3. Access instructions and test credentials

**BLOCKED:** Create a dedicated provider account or revocable provider
credential that will remain active for at least two weeks after submission.
Enter its username/key and password only in App Store Connect's demo-account
fields and set **Sign-in required** accurately. Do not use a personal account.

Recommended review flow after credentials are present:

1. Launch Vigil and choose **Add account**.
2. Select the provider named in the secure review credential fields.
3. Follow that provider's setup screen. For a device-code flow, approve the
   code in the provider-controlled browser page. For an API key, paste the
   dedicated review key and any required account identifier.
4. Choose **Verify and Save**. The dashboard will show only data returned by
   that provider.
5. Open the account card to inspect windows, reset times, metrics, freshness,
   and bounded observed history.
6. Pull down on the dashboard to request a manual refresh.
7. Open **Settings** to inspect appearance, privacy, alerts, automatic-check,
   app-lock, policy, support, and version controls.
8. Open **Accounts**, choose the linked account, and remove it to delete its
   local credential and Vigil data.

Provider values vary by account and can legitimately be percentage-only,
empty, rate-limited, or temporarily unavailable. Vigil does not invent missing
denominators or historical readings.

## 4. External services

Vigil has no developer-operated service. It communicates directly with only a
provider the user chooses to connect:

| Service | Purpose |
|---|---|
| Anthropic Claude | Provider authorization and returned consumer usage windows |
| OpenAI ChatGPT / Codex | Device authorization and returned subscription usage windows and credits |
| OpenRouter | Key usage, balances, and optional key limits |
| DeepSeek | API account balances |
| Moonshot global and China | Open-platform balances |
| MiniMax global and China | Coding-plan quota windows; marked Experimental |
| OpenAI API | Organization cost and user-requested official usage/cost history import |
| GitHub Copilot | Account-plan AI credit usage and billable spend |
| xAI API | API-platform prepaid balance |
| Grok Build | Device authorization and returned coding-plan billing usage; marked Experimental |
| Z.ai Coding Plan | Coding-plan quotas; marked Experimental |
| Cursor | User-supplied session credential and returned plan usage; marked Experimental |
| Kimi K3 | Coding-plan quotas; marked Experimental |

Vigil also uses Apple Keychain, App Groups, BackgroundTasks, WidgetKit,
UserNotifications, LocalAuthentication, and user-initiated document export.
These are local Apple platform services. There are no analytics, advertising,
crash-reporting, payment, cloud-storage, or generative-AI SDKs.

## 5. Regional differences

**BLOCKED:** Confirm the final territory list in App Store Connect. The current
recommendation is to exclude China mainland because the app and all en-US
listing assets name AI providers whose consumer services may not have the
required local permissions.

For every included storefront, Vigil's feature set is the same. A provider's
own account eligibility, endpoint availability, plan values, and regional
terms can differ. Global and China-specific provider connections are separate
and require the matching credential.

## 6. Regulated-industry documentation

Not applicable. Vigil is a usage-monitoring utility. It does not provide
banking, payments, lending, investing, insurance, gambling, medical advice, or
another regulated service. Currency values are provider-returned account usage,
balances, and budget controls, not financial products.

## App Review contact fields

**BLOCKED:** The owner must enter a monitored first name, last name, email
address, and phone number directly in App Store Connect. The contact must be
available during review. No placeholder values are acceptable.

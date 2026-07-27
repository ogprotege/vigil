# Provider support matrix

- Status: Current
- Last reviewed: 2026-07-26
- Review again: whenever `protocol/providers.json`, `ProviderRegistry`, or fixture provenance changes

This is the canonical list of providers that Vigil can connect. It describes the current code, not a planned integration list.

All listed providers use the same 300-second minimum polling interval. The app, background task, and widget share that account-level cooldown. iOS still decides when background work runs, so the poll floor is not a five-minute sampling promise.

## Status terms

- **Established** means Vigil presents the integration without an Experimental badge. It does not promise that the provider will keep the endpoint stable.
- **Experimental** means the integration depends on an undocumented or community-documented endpoint. Vigil shows that status in setup and account surfaces.
- **Live-sanitized** means a production response body was captured and sanitized before commit.
- **Vendor example** means the fixture came from vendor documentation.
- **Synthetic** means the fixture was hand-authored from a documented or researched contract.
- **Community research** means the response contract came from an independent maintained client or public implementation.

Fixture coverage proves deterministic behavior for the committed body. It does not prove that an upstream endpoint still returns that body today.

## Current integrations

| Provider | Setup and credential | Data Vigil accepts | Contract evidence | Status |
|---|---|---|---|---|
| Claude (`claude`) | Guided browser approval and pasted authorization code for setup and re-linking. | Five-hour and weekly utilization windows, active provider-scoped weekly limits, and optional extra-usage spend and limit values. Exact token ceilings appear only if the provider supplies them. | Live-sanitized scoped-limit and 429 bodies, plus synthetic success and money cases. The consumer usage endpoint is undocumented. | Established |
| ChatGPT / Codex (`codex`) | Guided OpenAI device authorization for setup and re-linking. | Primary and secondary subscription rate windows, additional provider-declared metered-feature windows, Flex credit balance, and reset credits. | Synthetic fixtures derived from the upstream Codex response model. The consumer usage endpoint is undocumented. | Established |
| OpenRouter (`openrouter`) | OpenRouter API key. | USD usage for all-time, day, week, and month periods; the same four BYOK usage periods; optional key spending limit and remaining amount. | Vendor-documented contract with synthetic fixtures. | Established |
| DeepSeek (`deepseek`) | DeepSeek API key. | One balance metric for each currency returned by the provider. | Vendor-documented contract with synthetic fixtures. | Established |
| Moonshot (Kimi) (`moonshot`) | Global Moonshot open-platform API key. | Available, cash, and voucher balances in USD. | Vendor example fixture. | Established |
| Moonshot (Kimi) China (`moonshot_cn`) | China Moonshot open-platform API key. | Available, cash, and voucher balances in CNY. | Vendor-documented contract with a synthetic boundary fixture. | Established |
| MiniMax Coding Plan (`minimax`) | Global MiniMax Coding Plan key. | Finite general session and weekly windows, plus finite video session and weekly windows when present. Unlimited status does not become a fake quota bar. | Community research and MiniMax CLI type evidence. | Experimental |
| MiniMax Coding Plan China (`minimax_cn`) | China MiniMax Coding Plan key. | The same finite general and video quota shapes as the global integration. | Community research and MiniMax CLI type evidence. | Experimental |
| OpenAI API (`openai`) | Dedicated organization Admin API key. Regular project keys cannot access the required organization endpoints. | Current month-to-date organization cost. An explicit import also stores daily completion quantities by model and daily costs by line item. | Vendor-documented organization Usage and Costs contracts with synthetic fixtures and client tests. | Established |
| GitHub Copilot (`github`) | Fine-grained personal access token with Account Plan read access, plus GitHub username. | Monthly AI credits consumed, included credits, billable credits, and billable spend in USD. | Vendor-documented billing contract with synthetic fixtures. | Established |
| xAI API (`xai`) | Management Key with billing read access, plus team ID. | Prepaid balance in USD. | Vendor-documented signed-cent contract with a synthetic fixture. | Established |
| Z.ai Coding Plan (`zai`) | GLM Coding Plan API key. | A provider-declared four-hour or five-hour token session window, a weekly token window, and web-search used, limit, and remaining counters. | Community research plus synthetic duration and hostile-input cases. The endpoint is undocumented. | Experimental |
| Cursor (`cursor`) | `WorkosCursorSessionToken` cookie value. | Plan quota, optional auto-selected and API-model percentages, billing reset, and compatible on-demand spend and limit pairs. | Community research plus synthetic fallback coverage. The web endpoint is undocumented. | Experimental |
| Kimi K3 (`kimi_code`) | Kimi Code API key. | Five-hour and weekly coding-plan windows with exact used, limit, and remaining values when returned. | Community research. The coding-plan endpoint is undocumented. | Experimental |

## Interpretation corrections

### Codex additional limits are metered features

Codex identifies each additional limit with `metered_feature` and may supply a `limit_name`. A returned label can look like a model name, but the contract identifies a metered feature. Vigil must not describe every additional Codex window as a model cap without a separate provider field that proves model scope.

The normal primary and secondary windows also expose percentages and reset times. A ChatGPT subscription name gives allowance context, but it does not supply an exact token or message denominator.

### Z.ai supports two session durations

The current mapper accepts both 14,400-second and 18,000-second token session windows. Those are four-hour and five-hour provider variants. It also requires the weekly 604,800-second token window for a complete two-window response.

### OpenAI completion imports contain six quantities

The OpenAI API history import stores these daily completion quantities, grouped by model:

- Input tokens
- Output tokens
- Cached input tokens
- Input audio tokens
- Output audio tokens
- Model requests

Input and output audio tokens use the generic `other` quantity kind while retaining their specific labels. Costs remain separate samples grouped by line item. Vigil does not join costs onto model token groups because those reports have different grouping dimensions.

This import covers the OpenAI API organization account. It does not cover ChatGPT or Codex subscription activity.

### OpenRouter values are USD amounts

The OpenRouter mapper treats `usage`, period usage, BYOK usage, `limit`, and `limit_remaining` as dollar values. It stores them directly with unit `USD`. It does not divide those response values by 100.

## Sources of truth

- [`protocol/providers.json`](../../protocol/providers.json) is the reviewable provider contract.
- [`ProviderSpec.swift`](../../packages/VigilKit/Sources/VigilKit/Providers/ProviderSpec.swift) contains the compiled runtime mirror.
- [`protocol/fixture-provenance.json`](../../protocol/fixture-provenance.json) records the evidence class and source for every fixture.
- [`SpecParityTests.swift`](../../packages/VigilKit/Tests/VigilKitTests/SpecParityTests.swift) prevents registry drift.
- [`FixtureParityTests.swift`](../../packages/VigilKit/Tests/VigilKitTests/FixtureParityTests.swift) verifies normalized output for committed fixtures.

See [Provider details](provider-details.md) for setup and interpretation notes. See [Unsupported candidates](unsupported-candidates.md) before assuming an unlisted provider works.

# Visual design and onboarding diagnosis

## The product is solving the wrong interface problem

Vigil should answer one iPhone question: which AI limit needs attention next? The current interface instead imitates the shape of a desktop token dashboard. That distinction matters because Token Monitor reads local session logs and can summarize real token history. Vigil reads provider APIs and mostly receives rolling quotas, balances, and spend.

The mismatch is explicit in the implementation. `UsagePeriod` says it copies Token Monitor's Day, Month, and Total idea, then expands it to Day, Week, Month, Year, and Life (`apps/apple/Vigil/Support/UsagePeriod.swift:4-13`). Those labels do not filter a uniform historical dataset. They classify provider window identifiers and approximate durations (`apps/apple/Vigil/Support/UsagePeriod.swift:37-58`). When no matching window exists, the selected filter silently falls back to another primary window (`apps/apple/Vigil/Support/UsagePeriod.swift:60-69`). The test suite preserves the contradiction by asserting that Day shows a weekly-only window (`apps/apple/VigilTests/UsagePeriodTests.swift:34-37`).

Git history confirms intent rather than accidental drift. Commit `6d918dd` is titled “Redesign Home like token-monitor” and says absolute token totals require local logs unavailable on a phone. Commit `0464b4a` says the persistent refresh button was copied from a circled control in an attached desktop screenshot. The current Token Monitor Limits screenshot places Day, Month, and Total above a real token total and cost. Vigil places five calendar labels above a provider quota hero. This is the central design failure. The interface copies an affordance after its underlying meaning has disappeared.

The README also sets an expectation that the product cannot fully meet. It calls Vigil an iOS usage monitor (`README.md:16-20`), but later admits that desktop transcript-derived token counts are unavailable and only provider values remain (`README.md:156-158`). Runtime copy repeats that token totals require local session logs (`apps/apple/Vigil/Support/UsagePeriod.swift:187-196`). Vigil can still be a useful product, but its honest category is AI limit monitor. The current Token Monitor comparison makes the smaller product feel incomplete rather than focused.

## First run teaches the shell before delivering value

A fresh installation enters the finished-app navigation with no onboarding state. `VigilApp` opens `RootView` directly (`apps/apple/Vigil/VigilApp.swift:18-27`), and `RootView` always presents Home, Models, Connections, and Settings as equal tabs (`apps/apple/Vigil/RootView.swift:38-77`). Home then renders the five-part picker and empty hero before checking whether an account exists (`apps/apple/Vigil/Dashboard/DashboardView.swift:26-47`).

The runtime empty-state screenshot confirms the result. `runtime-empty-home.png` shows five controls that cannot yet answer anything, an empty Limits value, four mostly empty destinations, a toolbar plus, and a second full-width Add account button. The first required task is visually subordinate to the product shell. A new user is asked to understand navigation and data concepts before connecting one source.

The setup sheet then reverses the recommended task order. Its body places `directProviderSection` before `renewingSignInSection` (`apps/apple/Vigil/Onboarding/AddAccountView.swift:29-35`). The first section calls manual credential entry “The simplest path” and renders all fourteen registry providers (`apps/apple/Vigil/Onboarding/AddAccountView.swift:181-207`). Claude and ChatGPT/Codex therefore first appear as “Access token” rows. Their durable browser sign-in choices appear only after the complete catalog and carry the title “Mint a renewing token,” the eyebrow “Optional,” and the technical label “OAuth” (`apps/apple/Vigil/Onboarding/AddAccountView.swift:100-112`).

The two runtime setup captures are decisive. `runtime-add-account-top.png` shows the first six manual rows and no sign-in button. `runtime-add-account-middle.png` reaches “Mint a renewing token” only after the remaining provider rows. The flow requires more than two screens of scrolling before exposing the recommended path. Yet the setup guide recommends Sign in with Claude and Sign in with Codex, and calls manual access-token entry recovery or non-renewing (`docs/getting-started.md:60-66`). The UI and documentation disagree at the exact decision where clarity matters most.

History explains how this happened. Commit `912c467` made paste and local import lead for the former multiplatform product, with sign-in optional. Commit `35fadf1` removed the Mac and desktop handoff but preserved that order. Phone-native sign-in was added as another feature rather than becoming the first-run spine. This is feature accretion, not an onboarding design.

The corrected flow should be short. An accountless app should open a focused choice with “Connect Claude,” “Connect ChatGPT,” and a quieter “Other provider” row. The first two routes should say what the person controls, not how credentials work. “Vigil keeps this connection signed in” is enough. Search and provider-region detail belong inside Other provider. Once verification succeeds, the app should land on the first real quota and explain its window, reset, and freshness in place.

## The dashboard computes urgency, then displays inventory

The core logic already knows the right product thesis. `PeriodHero` selects the lowest remaining percentage across connected accounts (`apps/apple/Vigil/Support/UsagePeriod.swift:98-148`). The list below ignores that ranking. It iterates `model.accounts` in stored order (`apps/apple/Vigil/Dashboard/DashboardView.swift:177-203`), then expands each account into as many as five windows (`apps/apple/Vigil/Dashboard/DashboardView.swift:233-240`) and six metrics (`apps/apple/Vigil/Dashboard/DashboardView.swift:389-414`).

The official dashboard screenshot confirms the broken handoff. The hero says 23% remains for ChatGPT/Codex, but the first account row is Claude at 58%. ChatGPT/Codex appears second, and later providers continue beneath a persistent refresh control and tab bar. The screenshot seed deliberately loads five heterogeneous accounts (`apps/apple/Vigil/Support/DemoData.swift:53-137`), so the official image demonstrates implementation coverage rather than a representative glance task.

The connected screen also carries too much permanent chrome. Home supports pull-to-refresh and a floating refresh button at the same time, while keeping a separate Add action in the toolbar (`apps/apple/Vigil/Dashboard/DashboardView.swift:55-88,105-133`). Connections repeats Add account in its toolbar and in a large card (`apps/apple/Vigil/Connections/ConnectionsView.swift:30-40,86-115`). Models receives a permanent tab even though valid providers can have no model caps (`apps/apple/Vigil/Dashboard/ModelsView.swift:31-49`). Home already includes a subset of those same special lanes, which the README acknowledges (`README.md:84-87`).

The iPhone hierarchy should follow action, not source order. Expired authentication and provider changes come first. Then show the account with the least remaining quota, then stale accounts, then healthy balance-only accounts. Each account row should expose one decisive value and reset. Additional windows, model caps, and financial metrics can expand beneath it. Models belongs as a filter or section inside Limits. Accounts and Settings can remain secondary destinations. One refresh interaction and one Add location are sufficient.

## The visual system repeats decoration instead of meaning

The purple and mint palette is not the main failure. The defined colors generally maintain readable contrast against the canvas and surface. The problem is that every utility surface receives the same eyebrow, large rounded slogan, explanatory sentence, card, border, and shadow. Structure no longer signals priority because the same composition is used for setup, model data, account management, settings, and privacy.

Models opens with “The special model limits” before showing a model (`apps/apple/Vigil/Dashboard/ModelsView.swift:114-127`). Connections opens with “Choose what Vigil watches” before another Add account card (`apps/apple/Vigil/Connections/ConnectionsView.swift:74-83`). Settings opens with “Quiet controls. Clear promises” before any control (`apps/apple/Vigil/Settings/SettingsView.swift:131-140`). Add account spends its top viewport on “Bring an account under watch” (`apps/apple/Vigil/Onboarding/AddAccountView.swift:84-98`). The Models screenshot shows the slogan consuming roughly the first quarter of usable height. The setup screenshot shows the same pattern pushing actual choices farther below the fold.

These phrases create tone but do not help a person decide. The navigation title already names each screen. Large type should therefore be reserved for the urgent quota or a true empty-state action. Section labels should describe real content. The app's watch metaphor can remain in the name and icon without occupying every hierarchy level.

The app icon provides a better signature than repeated cards. Its reserve gauge directly represents remaining capacity. A small version can anchor the single urgent-limit summary, while ordinary account rows use quiet separators and native list spacing. Existing dark colors can stay, but the interface should spend visual emphasis once. SF Dynamic Type roles should carry prose and labels. Monospaced digits should appear only in short values, such as 23% and 2h 17m.

## Divergent components explain the visible inconsistency

Home and Models do not render the same quota fact through one component. Home uses `StackedLimitBar`, which shows percent left and a human relative reset (`apps/apple/Vigil/Dashboard/DashboardView.swift:418-499`). Models uses `LimitMeterRow`, which shows percent left, percent used, and a native second-level timer (`apps/apple/Vigil/Dashboard/WindowRows.swift:73-175,249-273`). A third complete `AccountCardView` implementation remains in source (`apps/apple/Vigil/Dashboard/AccountCardView.swift:7-60`), but a repository-wide initializer search finds no `AccountCardView(...)` call site.

The screenshot pair confirms the consequence. Home says “Reset 2 hr, 17 min.” Models says “Resets in 119:59:57” and repeats “45% left” with “55% used.” The person must relearn the same data. The code must also fix freshness, spacing, copy, and accessibility in several places. That fragmentation explains why repeated polish passes did not converge.

One semantic quota row should own title, remaining value, reset formatting, freshness, status, and accessibility output. Compact, standard, and expanded layouts can change density without changing language. Models can filter the same rows instead of presenting another visual grammar. Widgets can share the same formatter even when their layout remains separate.

## Accessibility work exists, but layout resilience is unguarded

VoiceOver labels and 44-point controls appear throughout the code. The current failure is reflow. Provider headers place name, Experimental badge, plan, label, and freshness inside narrow horizontal stacks, with one-line limits on key text (`apps/apple/Vigil/Dashboard/DashboardView.swift:282-314`). Model rows repeat that pattern for title, account, badge, percentage, reset, and used percentage (`apps/apple/Vigil/Dashboard/WindowRows.swift:97-153`). Provider setup rows also cap the name at one line beside the badge (`apps/apple/Vigil/Onboarding/AddAccountView.swift:321-354`).

The defect occurs at the default text size. `runtime-add-account-middle.png` truncates MiniMax Coding Plan China. The official dashboard screenshot truncates MiniMax Coding Plan. Larger Dynamic Type categories will intensify both collisions. Current demo tests verify that sample data fills each surface, but they do not test text fit, control reachability, or reflow (`apps/apple/VigilTests/DemoDataTests.swift:23-77`).

Rows should switch to vertical metadata when width or text size demands it. Provider name may wrap to two lines. Plan and Experimental status belong on a second line. Redundant percent-used copy should disappear. Rendering tests should cover default, XXXL, and at least one accessibility category, plus VoiceOver order and Reduce Motion.

## The observed first-launch alert destroys the opening moment

The current simulator run surfaced another first-run problem. When shared App Group storage is unavailable outside tests, previews, and demo mode, `AppModel` creates a long message about private storage, widget ledgers, signing, and entitlements (`apps/apple/Vigil/AppModel.swift:96-110`). Dashboard presents every such message under the title “Vigil couldn't save data” (`apps/apple/Vigil/Dashboard/DashboardView.swift:92-102`).

`runtime-first-launch.png` shows that modal covering the accountless CTA. This evidence is environment-specific. A signed TestFlight build needs separate entitlement verification before anyone calls it universal. In the observed build, however, the title is also inaccurate because the body says app-private storage remains available. A first-run user should never have to interpret App Groups or polling ledgers.

The build should make the shared container valid. If a fallback remains possible, the app should defer a concise, nonblocking message until after setup. “Widgets unavailable in this build” states the effect. Technical detail can live in diagnostics.

## Compact redesign direction

The product thesis should read: “Vigil shows which AI limit needs your attention next.” The first-run route should expose mainstream sign-in before the provider catalog. The normal shell should contain Limits, Accounts, and Settings. Models should become a Limits filter, and historical date filters should appear only where Vigil has observations that truly belong to dates.

The connected Limits screen can use this hierarchy:

```text
Limits                                      Updated 2m

┌ Reserve dial ── ChatGPT / Codex ───────────────┐
│ 23% left        5-hour limit                    │
│ Resets in 3h 5m                    Live         │
└─────────────────────────────────────────────────┘

Needs attention
ChatGPT / Codex     23% left · 3h 5m              >

Other accounts
Claude              58% left · 2h 17m             >
MiniMax             82% left · Experimental       >
```

The layout uses one memorable gauge derived from the icon, one accent for remaining capacity, and status colors only when action is required. It removes the period picker, slogans, nested cards, persistent floating refresh button, duplicate percentages, and inventory-first expansion. This preserves Vigil's strongest work, including honest provider states and on-device privacy, while making the product behave like an iPhone instrument rather than a reduced desktop dashboard.

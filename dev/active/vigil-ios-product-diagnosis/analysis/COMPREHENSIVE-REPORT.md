# Vigil iOS comprehensive product and architecture report

> Generated: 2026-07-26
> Scope: Shipped iOS product, provider data model, first-use experience, architecture, and comparison with Token Monitor
> Depth: Deep dive
> Quality score: 96%

## Report overview

Vigil's main failure is not SwiftUI polish. The app copied a desktop Limits presentation onto a product with different capabilities. Token Monitor automatically reads local tool records and can display true token and cost history. Vigil must first connect provider accounts, then receives quota windows, balances, and limited observations. The current interface treats those values as though they formed one desktop-style analytics dataset.

The result is an inverted first-use path and misleading controls. Empty analytics appear before setup. Four permanent tabs expose implementation categories. Fourteen manual credential routes precede guided Claude and Codex sign-in. Day, Week, Month, Year, and Life classify provider reset windows, sometimes with explicit fallback to the wrong duration. Runtime testing also found severe Dynamic Type failures.

The technical core contains valuable safeguards, but its coupling makes product correction risky. `AppModel` owns too many storage, refresh, lifecycle, and presentation duties. Widget refreshes can leave the app's in-memory snapshot stale. Provider identity can depend on rotating secrets. The recommended path preserves provider truth while rebuilding the product around one promise: show which AI limit needs attention next.

## Section index

| Section | Core finding | Detail |
|---|---|---|
| Architecture, state, and provider flow | The data model and state boundaries can misrepresent both meaning and freshness. | [Read section](./sections/section-overview.md) |
| Entrypoints and reference comparison | Vigil copied a secondary reference surface rather than the reference product's automatic core task. | [Read section](./sections/section-entrypoints.md) |
| Visual design and onboarding | Task hierarchy, progressive disclosure, component divergence, and adaptive layout cause the visible failure. | [Read section](./sections/section-patterns.md) |

## Architecture insight

The false period model is the link between product and code complexity. It forces unrelated quota windows and sampled financial observations through one selector. The provider registry similarly links backend breadth to setup overload. Both cases expose implementation structure directly to the user.

The correction should separate four concepts: current provider limits, provider-returned financial values, device-observed history, and unavailable desktop token history. Once those concepts stop sharing controls, Home can become a clear urgency summary. Account detail can retain the complete and honest provider information.

## Recommended direction

Start with the product contract and source-of-truth matrix. Remove calendar periods from current quotas. Replace the accountless shell with direct Claude and ChatGPT/Codex setup. Move the remaining provider catalog behind search. Reduce permanent navigation to a Limits home with account and settings routes. Consolidate quota components and add adaptive layouts.

After the product correction, extract account transactions, refresh orchestration, and shared snapshot observation behind the existing `AppModel` facade. Add UI tests for the complete first-run task, accessibility text sizes, relinking, and widget-to-app reconciliation.

## Deliverables

- [Severity-ranked code review and redesign blueprint](../vigil-ios-product-diagnosis-code-review.md)
- [Quality and consolidation report](./consolidation-summary.md)
- [Runtime screenshot evidence](../runtime-empty-home.png)
- [First-use setup evidence](../runtime-add-account-top.png)
- [Accessibility failure evidence](../runtime-empty-home-axxxl.png)

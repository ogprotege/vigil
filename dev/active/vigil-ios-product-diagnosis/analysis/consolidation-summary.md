# Vigil iOS product diagnosis consolidation

## Synthesis

Vigil is technically careful but confused at the product level. Its provider client, polling safeguards, persistence rules, and failure taxonomy are stronger than the visible experience suggests. The central defect appears one level above those systems. Vigil copied the presentation of Token Monitor's Limits screen even though an iPhone cannot perform Token Monitor's core task. Token Monitor reads local session records and produces useful token and cost history without setup. Vigil receives provider quotas, balances, and sparse observations only after account setup.

That mismatch reaches every surface. Calendar period controls label provider reset windows as Day, Week, Month, Year, and Life. First run presents empty analytics and four permanent tabs before setup. The setup sheet leads with fourteen manual credential routes and hides the guided Claude and Codex flows below them. Once data exists, Home renders inventory rather than an urgency summary. Several independent quota components then format the same facts differently.

The architecture magnifies the design error. A 922-line `AppModel` owns persistence transactions, refresh orchestration, lifecycle behavior, widget reloads, and presentation state. The app and widget can retain different snapshot versions. Credential-derived identity can duplicate a re-linked Claude account. Fourteen-provider breadth also reaches first run before the two primary subscription paths feel simple. The correction must begin with an honest product contract, then simplify navigation and setup, then extract architecture seams behind a stable UI facade.

## Section summaries

| Section | File | Core finding |
|---|---|---|
| Architecture, state, and provider flow | [section-overview.md](./sections/section-overview.md) | The desktop-style data model creates false semantics, while split snapshot state and a broad `AppModel` make visible truth harder to maintain. |
| Entrypoints and reference comparison | [section-entrypoints.md](./sections/section-entrypoints.md) | Vigil copied Token Monitor's secondary Limits view without its automatic local token-history task, then exposed setup and implementation categories as primary navigation. |
| Visual design and onboarding | [section-patterns.md](./sections/section-patterns.md) | Setup hierarchy, summary-detail boundaries, duplicate components, and adaptive layout are the design failures. The purple palette is not the root cause. |

## Cross-section analysis

All three reviews identify the same causal chain. The missing product boundary creates misleading controls. Those controls require special fallback logic. The fallback logic then spreads through the hero, account rows, observation history, tests, and documentation. Visual polishing cannot resolve this because the underlying labels join unrelated data classes.

The first-use failure follows the same pattern. Provider registry breadth became the setup information architecture. That makes fourteen integrations visible before the two guided routes. The permanent Models and Connections tabs likewise expose code and data categories rather than frequent user tasks. Duplicate quota components preserve earlier design attempts, so wording, timers, and responsive behavior diverge.

The architecture findings explain why each redesign became expensive. `AppModel` combines transaction integrity with screen state. Shared persistence does not provide a shared observable model. The widget can advance the snapshot and poll ledger without updating the running app. Product corrections should therefore preserve provider truth and storage safeguards while replacing the presentation model and adding a disk-reconciliation seam.

## Recommendations

First, define Vigil as an iPhone limits and balance companion. Its recurring promise should be: “See which AI limit needs attention next.” Do not promise desktop token-history parity until a separate paired collector supplies that data. Remove the period selector from quota presentation. Label each real provider window by its actual duration and reset.

Second, make accountless Home the setup flow. Put “Connect Claude” and “Connect ChatGPT / Codex” first. Put manual and experimental providers behind a searchable “Other provider” route. After setup, show no more than three accounts, sorted by action and urgency. Open full windows, balances, model lanes, and diagnostics from account detail.

Third, reduce permanent navigation. Keep one Limits home. Put account management and Settings behind toolbar routes. Show Models only when linked data contains genuine model-specific caps. Consolidate account summary, quota meter, reset wording, freshness, and accessibility output into one component family.

Fourth, extract `AccountStore`, `RefreshDriver`, and an observable shared snapshot repository behind `AppModel`. Preserve persisted account keys and widget-shared source locations during the UI correction. Then add first-run, navigation, widget reconciliation, and Dynamic Type tests.

## Quality assessment

| Dimension | Score | Basis |
|---|---:|---|
| Completeness | 96% | Product positioning, onboarding, navigation, data semantics, runtime, architecture, refactor boundaries, and validation are covered. |
| Consistency | 97% | The three independent analyses agree on the primary cause and use consistent source references. |
| Depth | 96% | Findings trace visible behavior through source, tests, history, runtime evidence, and the reference implementation. |
| Readability | 95% | Findings are severity-ranked and recommendations preserve a clear implementation order. |
| Overall | 96% | Evidence supports a decisive diagnosis and an implementable correction. |

### Blocking errors

None.

### Warnings

| ID | Location | Description |
|---|---|---|
| W001 | Runtime evidence | The first-launch App Group alert came from the repository's unsigned simulator configuration. It is proven for that build path, not for signed TestFlight build 15. |
| W002 | Provider behavior | The review used fixtures and existing tests. It did not connect private production accounts to all fourteen providers. |

### Informational notes

| ID | Location | Description |
|---|---|---|
| I001 | Python performance | The repository contains no Python source or Python runtime path. Python profiling is therefore not relevant to this iOS defect. |
| I002 | Reference checkout | Comparative source references use Token Monitor commit `2d63b7a6445f474531d49c56a0648478cb84cb48`, captured on 2026-07-26. |

### Statistics

- Sections: 3
- Mermaid diagrams: 3
- Runtime screenshots: 12
- Section words: 6,657
- Local source references: 188 validated file and line citations across the report set

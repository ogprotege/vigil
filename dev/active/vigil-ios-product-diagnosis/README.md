# Vigil iOS product diagnosis evidence

> **Completed historical evidence.** The diagnosis and reconstruction review
> finished on 2026-07-26. This directory remains in `dev/active` temporarily to
> preserve existing links. Its reports and screenshots do not control current
> behavior, release readiness, or upload approval.

Current documentation controls:

- [Documentation index](../../../docs/index.md)
- [Product contract](../../../docs/product-contract.md)
- [Architecture](../../../docs/development/architecture.md)
- [Testing guide](../../../docs/development/testing.md)
- [Release runbook](../../../docs/development/release.md)
- [0.15.0 (16) release record](../../../docs/releases/0.15.0-16.md)

## Reports

| File | Historical scope |
|---|---|
| [Product diagnosis and code review](vigil-ios-product-diagnosis-code-review.md) | Diagnoses the pre-reconstruction product at commit `35fadf1` and proposes the narrower product contract |
| [Implementation code review](vigil-ios-implementation-code-review.md) | Reviews an intermediate reconstruction state and is superseded by the later release-candidate review |
| [0.15 release-candidate code review](vigil-ios-release-0.15-code-review.md) | Reviews reconstruction commit `8e15543`; later commits and release gates are tracked elsewhere |
| [Implementation product contract](implementation-product-contract.md) | Working contract used during reconstruction; the current product contract now controls |
| [Implementation dependency map](implementation-dependency-map.md) | Working dependency map used to sequence the reconstruction |
| [Comprehensive analysis](analysis/COMPREHENSIVE-REPORT.md) | Consolidated analysis generated during the diagnosis |

## Runtime captures

The `runtime-*-reconstructed.png` files show representative reconstructed UI
from the reviewed simulator build. Other `runtime-*.png` files show earlier UI
or diagnosis states. The `legacy-readme-*.png` files are the retired public
README images that showed the calendar selector and Models tab removed during
reconstruction. A screenshot proves only the recorded simulator state. It does
not prove signed entitlements, live provider behavior, App Store Connect
processing, TestFlight distribution, or physical-device behavior.

## Archival rule

Do not add new release status here. Add current evidence to the canonical
release record or `dev/releases/<version>-<build>/`. When incoming links are
ready, move this directory according to the
[development archive policy](../../archive/README.md).

# Diagnostic export schema

- Status: Current
- Schema version: 1
- Last reviewed: 2026-07-26
- Review again: whenever `DiagnosticExportBuilder` or its tests change

Vigil exports a support document from Settings or from one account's detail screen. The document contains normalized numeric state and bounded recent history. It is not a credential backup, raw provider response, billing export, or complete history archive.

The implementation is `apps/apple/Vigil/Support/DiagnosticExport.swift`. `DiagnosticExportTests` enforce the privacy boundary.

## Privacy boundary

The builder uses an allow list. It does not accept these values as input fields for the exported document:

- Access or refresh tokens
- API keys
- Authorization headers
- Cookies
- Keychain values
- Raw provider response bodies
- Account labels
- Plan labels
- Internal account keys
- Provider-controlled window IDs or labels
- Provider-controlled metric IDs, labels, or units
- Provider-controlled quantity IDs, labels, or units

Recognized provider IDs remain because support needs to identify the mapper involved. Unknown provider IDs become `unknown-provider`.

Numeric utilization, exact amounts, metric values, quantity values, reset times, record times, status, and secondary flags remain. A user should still inspect the file before sharing it.

Once the user exports the JSON through the system file exporter, that copy is outside Vigil's local storage controls.

## File behavior

The user-facing exporters suggest these names:

```text
Vigil-Diagnostics-YYYY-MM-DD.json
Vigil-Account-Diagnostics-YYYY-MM-DD.json
```

Settings uses the first name. Account detail uses the second. Both pass an in-memory `FileDocument` to the system file exporter, so the chosen destination and its final storage attributes belong to that system workflow.

`DiagnosticExportBuilder.write` is a separate protected temporary-file helper. It uses a UUID filename, atomic writing, complete-file-protection-unless-open, file mode `0600`, and directory mode `0700`. The current Settings and account-detail export paths build data directly instead of calling that helper.

Dates use JSON ISO 8601 encoding. Keys are sorted and the document is pretty-printed. Optional properties are omitted when their source value is absent.

## Top-level document

```json
{
  "schemaVersion": 1,
  "app": {
    "name": "Vigil",
    "version": "0.15.0",
    "build": "16"
  },
  "exportedAt": "2026-07-26T21:00:00Z",
  "privacy": {
    "credentialsIncluded": false,
    "rawProviderDataIncluded": false
  },
  "historyScope": {
    "retainedSampleCount": 412,
    "exportedSampleCount": 18,
    "selection": "bounded-recent-per-account-and-source"
  },
  "accounts": [],
  "currentSnapshots": [],
  "history": []
}
```

| Property | Type | Meaning |
|---|---|---|
| `schemaVersion` | integer | Consumer-facing schema version. Current value is `1`. |
| `app` | object | Sanitized app identity. |
| `exportedAt` | ISO 8601 string | Time the document was built. |
| `privacy` | object | Explicit absence declarations. Both values are `false` in version 1. |
| `historyScope` | object | Retained and exported sample counts plus the selection rule. |
| `accounts` | array | Linked accounts with local aliases and trusted provider IDs. |
| `currentSnapshots` | array | Current normalized snapshots included in the export scope. |
| `history` | array | Bounded recent normalized history included in the export scope. |

### App object

| Property | Type | Rules |
|---|---|---|
| `name` | string | Always `Vigil`. Bundle-provided names are not exported. |
| `version` | string | Numeric version with up to four dot-separated parts, otherwise `unknown`. |
| `build` | string | Decimal digits only, otherwise `unknown`. |

### History scope

| Property | Type | Rules |
|---|---|---|
| `retainedSampleCount` | integer | Total retained records known to the app for the export scope. Never lower than `exportedSampleCount`. |
| `exportedSampleCount` | integer | Number of objects in `history`. |
| `selection` | string | Always `bounded-recent-per-account-and-source` in version 1. |

The app model currently loads at most nine recent `observed` records and nine recent `providerBackfill` records per account into the export preview. The retained SQLite archive can be much larger.

## Account object

```json
{
  "accountId": "account-001",
  "providerId": "claude"
}
```

| Property | Type | Meaning |
|---|---|---|
| `accountId` | string | Export-local alias in the form `account-NNN`. |
| `providerId` | string | Registry provider ID or `unknown-provider`. |

Account aliases are assigned from the sorted set of internal account keys. The same account uses the same alias throughout one document. Consumers must not assume that an alias remains stable across separate exports or account-set changes.

## Current snapshot object

```json
{
  "accountId": "account-001",
  "providerId": "claude",
  "fetchedAt": "2026-07-26T20:55:00Z",
  "status": "ok",
  "windows": [
    {
      "id": "window-001",
      "utilization": 42.5,
      "resetsAt": "2026-07-27T01:00:00Z",
      "windowSeconds": 18000,
      "secondary": false
    }
  ],
  "metrics": [
    {
      "id": "metric-001",
      "kind": "spend",
      "value": 4.25,
      "secondary": false
    }
  ]
}
```

| Property | Type | Meaning |
|---|---|---|
| `accountId` | string | Export-local account alias. |
| `providerId` | string | Trusted provider ID or `unknown-provider`. |
| `fetchedAt` | ISO 8601 string | Provider observation time. |
| `status` | string enum | Current normalized status. |
| `windows` | array | Aliased normalized quota windows. |
| `metrics` | array | Aliased normalized non-window values. |

Current snapshots are sorted by account alias, then fetch time.

## History sample object

```json
{
  "id": "history-000001",
  "source": "providerBackfill",
  "accountId": "account-001",
  "providerId": "openai",
  "recordedAt": "2026-07-25T00:00:00Z",
  "periodEnd": "2026-07-26T00:00:00Z",
  "retrievedAt": "2026-07-26T20:58:00Z",
  "status": "ok",
  "windows": [],
  "metrics": [],
  "quantities": [
    {
      "id": "quantity-001",
      "kind": "inputTokens",
      "value": 1200
    }
  ]
}
```

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Export-local alias in the form `history-NNNNNN`. |
| `source` | string enum | `observed` or `providerBackfill`. |
| `accountId` | string | Export-local account alias. |
| `providerId` | string | Trusted provider ID or `unknown-provider`. |
| `recordedAt` | ISO 8601 string | Device observation time or provider bucket start. |
| `periodEnd` | ISO 8601 string, optional | Provider bucket end when present. |
| `retrievedAt` | ISO 8601 string | Time Vigil received or imported the record. |
| `status` | string enum | Status stored with the normalized sample. |
| `windows` | array | Aliased normalized windows. |
| `metrics` | array | Aliased normalized metrics. |
| `quantities` | array | Aliased counted quantities. |

History is sorted by account alias, recorded time, and provider ID before sequential history aliases are assigned.

## Window object

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Position alias `window-NNN`, local to its parent snapshot or sample. |
| `utilization` | number | Percentage used. |
| `resetsAt` | ISO 8601 string, optional | Provider reset timestamp. |
| `windowSeconds` | integer, optional | Provider window duration. |
| `secondary` | boolean | Whether the normalized window is secondary. |
| `used` | number, optional | Exact provider-supplied usage. |
| `limit` | number, optional | Exact provider-supplied quota. |
| `remaining` | number, optional | Exact provider-supplied or losslessly derived remainder. |

Labels, original IDs, and history segment IDs are not exported.

## Metric object

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Position alias `metric-NNN`, local to its parent. |
| `kind` | string enum | `balance`, `spend`, `limit`, or `remaining`. |
| `value` | number | Normalized numeric value. |
| `secondary` | boolean | Whether the normalized metric is secondary. |

Metric labels and units are not exported. The document is therefore suitable for mapper diagnostics, not financial reconciliation.

## Quantity object

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Position alias `quantity-NNN`, local to its history sample. |
| `kind` | string enum | Counted-usage category. |
| `value` | number | Normalized count. |

Quantity kinds in version 1 are:

- `inputTokens`
- `outputTokens`
- `cachedInputTokens`
- `cacheReadTokens`
- `cacheWriteTokens`
- `requests`
- `other`

Quantity labels and units are not exported.

## Status values

Version 1 supports these exact values:

- `ok`
- `authExpired`
- `rateLimited`
- `schemaChanged`
- `network`

## Consumer rules

- Reject a `schemaVersion` the consumer does not understand.
- Treat aliases as document-local identifiers.
- Do not infer a missing optional field as zero.
- Use `historyScope` before claiming the export contains complete history.
- Keep `observed` and `providerBackfill` records distinct.
- Do not infer currency or provider unit from a metric or quantity because the export omits units.
- Do not treat the diagnostic file as proof of provider billing totals.

## Change policy

Increment `schemaVersion` when a change breaks a version 1 consumer, changes field meaning, removes a field, or changes an enum incompatibly.

An additive optional field can remain version 1 only when old consumers can ignore it safely. Every added field requires a hostile-value privacy test proving that credentials or provider-controlled text cannot cross the allow-list boundary.

## Related documentation

- [Architecture](architecture.md)
- [Testing](testing.md)
- [Provider support matrix](../providers/support-matrix.md)

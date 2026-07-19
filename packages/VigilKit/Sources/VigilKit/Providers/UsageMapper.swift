import Foundation

/// Data-driven response mapper — the Swift twin of cli/src/providers/map.ts.
/// FixtureParityTests pins both to the same protocol/fixtures files.
public enum UsageMapper {
    public struct Mapped: Equatable, Sendable {
        public let planLabel: String?
        public let windows: [UsageWindow]
        public let metrics: [UsageMetric]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func value(at dotPath: String, in object: Any?) -> Any? {
        var current: Any? = object
        for key in dotPath.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    private static func number(_ raw: Any?) -> Double? {
        // Every JSON number (and boolean) arrives as an NSNumber, and an
        // `as? Double` cast would happily bridge JSON true to 1.0 — the
        // boolean check must run before any numeric bridging.
        guard let value = raw as? NSNumber else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }

    /// Balance APIs commonly encode exact decimal amounts as JSON strings.
    /// Accept those for scalar metrics while keeping window percentages strict.
    /// Surrounding whitespace is tolerated to match JavaScript Number().
    private static func metricNumber(_ raw: Any?) -> Double? {
        if let number = number(raw) { return number }
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite
        else { return nil }
        return value
    }

    /// Returns nil for a malformed reset; .some(nil) for an explicit null/absent one.
    private static func reset(from raw: Any?, format: ResetFormat) -> Date?? {
        if raw == nil || raw is NSNull { return .some(nil) }
        switch format {
        case .iso8601:
            guard let string = raw as? String, let date = isoFormatter.date(from: string) else { return nil }
            return .some(date)
        case .unixSeconds:
            guard let seconds = number(raw) else { return nil }
            let milliseconds = seconds * 1_000
            // Keep parity with JavaScript Date's representable range and
            // reject hostile finite values that would fail later formatting.
            guard milliseconds.isFinite,
                  abs(milliseconds) <= 8_640_000_000_000_000
            else { return nil }
            return .some(Date(timeIntervalSince1970: seconds))
        }
    }

    private static func readBucket(
        spec: ProviderSpec,
        bucket: [String: Any],
        id: String,
        resetFormat: ResetFormat,
        specWindowSeconds: Int?,
        secondary: Bool
    ) -> UsageWindow? {
        guard let fields = spec.responseFields else { return nil }
        // Some providers nest the numbers one level down (Codex
        // additional_rate_limits entries appear both flat and nested).
        var source = bucket
        if value(at: fields.utilization, in: bucket) == nil,
           let nested = bucket["rate_limit"] as? [String: Any] {
            source = nested
        }

        guard let utilization = number(value(at: fields.utilization, in: source)) else { return nil }
        guard let resetsAt = reset(from: value(at: fields.resetsAt, in: source), format: resetFormat) else { return nil }

        var windowSeconds = specWindowSeconds
        if let key = fields.windowSeconds,
           let fromResponse = number(value(at: key, in: source)),
           // Int(exactly:) rejects non-integral values and anything outside
           // Int64 — a plain Int(_:) would trap on 2^63, which slips past a
           // `<= Double(Int.max)` comparison because Int.max rounds UP to
           // 2^63 as a Double. The explicit cap matches JavaScript's
           // Number.isSafeInteger so both mappers accept the same range.
           let intValue = Int(exactly: fromResponse),
           intValue > 0,
           intValue <= 9_007_199_254_740_991 {
            windowSeconds = intValue
        }

        return UsageWindow(
            id: id,
            utilization: min(100, max(0, utilization)),
            resetsAt: resetsAt,
            windowSeconds: windowSeconds,
            secondary: secondary
        )
    }

    private static func normalizedMetricID(_ raw: String, prefix: String) -> String {
        // Mirrors the TS regex `[^a-z0-9]` applied per UTF-16 code unit:
        // non-ASCII letters (e.g. currency names like 元) normalize to "_"
        // on both sides instead of surviving only in Swift.
        let safe = raw.lowercased().utf16.map { unit -> Character in
            if (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) {
                return Character(UnicodeScalar(unit)!)
            }
            return "_"
        }
        return "\(prefix)_\(String(safe))"
    }

    private static func boundedProviderText(_ raw: String, maximumLength: Int) -> String? {
        // UTF-16 code units, matching JavaScript String.length so both
        // mappers accept or reject the same provider-supplied identifiers.
        guard !raw.isEmpty,
              raw.utf16.count <= maximumLength,
              raw.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return raw
    }

    /// Returns nil when nothing maps at all — the schemaChanged signal.
    public static func map(spec: ProviderSpec, body: Data) -> Mapped? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }

        var windows: [UsageWindow] = []
        var windowIDs = Set<String>()
        for mapping in spec.windows {
            guard let bucket = value(at: mapping.sourceKey, in: root) as? [String: Any] else { continue }
            if let window = readBucket(
                spec: spec,
                bucket: bucket,
                id: mapping.id,
                resetFormat: mapping.resetFormat,
                specWindowSeconds: mapping.windowSeconds,
                secondary: mapping.secondary
            ), windowIDs.insert(window.id).inserted {
                windows.append(window)
            }
        }

        if let additional = spec.additionalWindows,
           let entries = value(at: additional.sourceKey, in: root) as? [Any] {
            for entry in entries.prefix(128) {
                guard let record = entry as? [String: Any],
                      let rawID = record[additional.idKey] as? String,
                      let id = boundedProviderText(rawID, maximumLength: 128)
                else { continue }
                if let window = readBucket(
                    spec: spec,
                    bucket: record,
                    id: id,
                    resetFormat: .unixSeconds,
                    specWindowSeconds: nil,
                    secondary: additional.secondary
                ), windowIDs.insert(window.id).inserted {
                    windows.append(window)
                }
            }
        }

        var metrics: [UsageMetric] = []
        var metricIDs = Set<String>()
        for mapping in spec.metricMappings {
            guard let amount = metricNumber(value(at: mapping.sourceKey, in: root)) else { continue }
            let metric = UsageMetric(
                id: mapping.id,
                label: mapping.label,
                kind: mapping.kind,
                value: amount,
                unit: mapping.unit,
                secondary: mapping.secondary
            )
            if metricIDs.insert(metric.id).inserted {
                metrics.append(metric)
            }
        }

        for collection in spec.metricCollectionMappings {
            guard let entries = value(at: collection.sourceKey, in: root) as? [Any] else { continue }
            for entry in entries.prefix(128) {
                guard let record = entry as? [String: Any],
                      let rawID = value(at: collection.idKey, in: record) as? String,
                      let safeID = boundedProviderText(rawID, maximumLength: 128),
                      let amount = metricNumber(value(at: collection.valueKey, in: record))
                else { continue }
                let unit = collection.unitKey
                    .flatMap { value(at: $0, in: record) as? String }
                    .flatMap { boundedProviderText($0, maximumLength: 32) }
                let suffix = unit ?? safeID
                let metric = UsageMetric(
                    id: normalizedMetricID(safeID, prefix: collection.kind.rawValue),
                    label: "\(collection.label) (\(suffix))",
                    kind: collection.kind,
                    value: amount,
                    unit: unit,
                    secondary: collection.secondary
                )
                if metricIDs.insert(metric.id).inserted {
                    metrics.append(metric)
                }
            }
        }

        guard !windows.isEmpty || !metrics.isEmpty else { return nil }

        var planLabel: String?
        if let planKey = spec.planKey,
           let plan = value(at: planKey, in: root) as? String {
            planLabel = boundedProviderText(plan, maximumLength: 128)
        }
        return Mapped(planLabel: planLabel, windows: windows, metrics: metrics)
    }
}

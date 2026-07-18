import Foundation

/// Data-driven response mapper — the Swift twin of cli/src/providers/map.ts.
/// FixtureParityTests pins both to the same protocol/fixtures files.
public enum UsageMapper {
    public struct Mapped: Equatable, Sendable {
        public let planLabel: String?
        public let windows: [UsageWindow]
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
        if let value = raw as? Double { return value.isFinite ? value : nil }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber {
            // Reject booleans masquerading as numbers.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        return nil
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
        // Some providers nest the numbers one level down (Codex
        // additional_rate_limits entries appear both flat and nested).
        var source = bucket
        if value(at: spec.responseFields.utilization, in: bucket) == nil,
           let nested = bucket["rate_limit"] as? [String: Any] {
            source = nested
        }

        guard let utilization = number(value(at: spec.responseFields.utilization, in: source)) else { return nil }
        guard let resetsAt = reset(from: value(at: spec.responseFields.resetsAt, in: source), format: resetFormat) else { return nil }

        var windowSeconds = specWindowSeconds
        if let key = spec.responseFields.windowSeconds,
           let fromResponse = number(value(at: key, in: source)) {
            windowSeconds = Int(fromResponse)
        }

        return UsageWindow(
            id: id,
            utilization: min(100, max(0, utilization)),
            resetsAt: resetsAt,
            windowSeconds: windowSeconds,
            secondary: secondary
        )
    }

    /// Returns nil when nothing maps at all — the schemaChanged signal.
    public static func map(spec: ProviderSpec, body: Data) -> Mapped? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }

        var windows: [UsageWindow] = []
        for mapping in spec.windows {
            guard let bucket = value(at: mapping.sourceKey, in: root) as? [String: Any] else { continue }
            if let window = readBucket(
                spec: spec,
                bucket: bucket,
                id: mapping.id,
                resetFormat: mapping.resetFormat,
                specWindowSeconds: mapping.windowSeconds,
                secondary: mapping.secondary
            ) {
                windows.append(window)
            }
        }

        if let additional = spec.additionalWindows,
           let entries = value(at: additional.sourceKey, in: root) as? [Any] {
            for entry in entries {
                guard let record = entry as? [String: Any],
                      let id = record[additional.idKey] as? String,
                      !id.isEmpty
                else { continue }
                if let window = readBucket(
                    spec: spec,
                    bucket: record,
                    id: id,
                    resetFormat: .unixSeconds,
                    specWindowSeconds: nil,
                    secondary: additional.secondary
                ) {
                    windows.append(window)
                }
            }
        }

        guard !windows.isEmpty else { return nil }

        var planLabel: String?
        if let planKey = spec.planKey, let plan = value(at: planKey, in: root) as? String, !plan.isEmpty {
            planLabel = plan
        }
        return Mapped(planLabel: planLabel, windows: windows)
    }
}

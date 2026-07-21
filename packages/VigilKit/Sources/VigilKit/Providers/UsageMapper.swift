import Foundation

/// Data-driven response mapper — the Swift twin of cli/src/providers/map.ts.
/// FixtureParityTests pins both to the same protocol/fixtures files.
public enum UsageMapper {
    public struct Mapped: Equatable, Sendable {
        public let planLabel: String?
        public let windows: [UsageWindow]
        public let metrics: [UsageMetric]
    }

    /// ISO-8601 parsing, mirroring the TS side's `new Date(value)`, which
    /// accepts both whole and fractional seconds.
    ///
    /// One `ISO8601DateFormatter` cannot parse both forms — `.withFractionalSeconds`
    /// makes the fraction mandatory, not optional — so both are tried. They are
    /// created per call rather than shared in a `static let`: a mutable
    /// reference type in global state is a data race under concurrent mapping
    /// (`refreshAll` maps every account in a task group) and a hard error in the
    /// Swift 6 language mode.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: string)
    }

    /// Dot-path lookup with one extension mirrored from the TS mapper: a
    /// segment may end in a selector, `items[kind=general]`, which resolves
    /// `items` to an array and picks the first element whose `kind` property
    /// string-equals "general".
    private static func value(at dotPath: String, in object: Any?) -> Any? {
        var current: Any? = object
        for segment in dotPath.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            if segment.hasSuffix("]"),
               let open = segment.firstIndex(of: "["),
               let equals = segment.firstIndex(of: "="),
               open < equals {
                let key = String(segment[..<open])
                let matchKey = String(segment[segment.index(after: open)..<equals])
                let matchValue = String(segment[segment.index(after: equals)..<segment.index(before: segment.endIndex)])
                guard let array = dict[key] as? [Any] else { return nil }
                current = array.prefix(128).first { entry in
                    guard let record = entry as? [String: Any] else { return false }
                    return (record[matchKey] as? String) == matchValue
                }
            } else {
                current = dict[String(segment)]
            }
        }
        return current
    }

    /// Aggregate-path lookup mirrored from the TS mapper: segments ending in
    /// `[]` flat-map arrays, so `data[].results[].amount.value` collects
    /// every matching leaf. Bounded at 128 elements per array level.
    private static func collect(at dotPath: String, in object: Any?) -> [Any] {
        var frontier: [Any] = object.map { [$0] } ?? []
        for segment in dotPath.split(separator: ".") {
            var next: [Any] = []
            let isFlatMap = segment.hasSuffix("[]")
            let key = isFlatMap ? String(segment.dropLast(2)) : String(segment)
            for node in frontier {
                guard let dict = node as? [String: Any] else { continue }
                let value = dict[key]
                if isFlatMap {
                    if let array = value as? [Any] {
                        next.append(contentsOf: array.prefix(128))
                    }
                } else {
                    // TS pushes the raw value even when the key is ABSENT
                    // (`next.push(undefined)`), so an absent leaf still counts
                    // as a leaf. Dropping it here instead collapsed the
                    // frontier to empty, which made the caller's "leaves exist
                    // but none parsed -> shape changed" branch unreachable and
                    // turned a renamed billing field into a confident $0.00.
                    // NSNull stands in for undefined: metricNumber rejects it
                    // and the next iteration skips it, exactly as TS does.
                    next.append(value ?? NSNull())
                }
            }
            frontier = next
            if frontier.isEmpty { return [] }
        }
        return frontier
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

    /// Window numbers are strict by default; allowStringNumbers opts a
    /// provider into string-encoded numerics ("46.5") without loosening
    /// everyone else. Mirrors the TS windowNumber helper.
    private static func windowNumber(_ raw: Any?, lenient: Bool) -> Double? {
        if let value = number(raw) { return value }
        guard lenient, let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Returns nil for a malformed reset; .some(nil) for an explicit null/absent one.
    private static func reset(from raw: Any?, format: ResetFormat, lenient: Bool) -> Date?? {
        if raw == nil || raw is NSNull { return .some(nil) }
        switch format {
        case .iso8601:
            guard let string = raw as? String, let date = parseISO8601(string) else { return nil }
            return .some(date)
        case .unixSeconds, .unixMillis:
            guard let numeric = windowNumber(raw, lenient: lenient) else { return nil }
            let milliseconds = format == .unixMillis ? numeric : numeric * 1_000
            // Keep parity with JavaScript Date's representable range and
            // reject hostile finite values that would fail later formatting.
            guard milliseconds.isFinite,
                  abs(milliseconds) <= 8_640_000_000_000_000
            else { return nil }
            return .some(Date(timeIntervalSince1970: milliseconds / 1_000))
        }
    }

    private static func readBucket(
        spec: ProviderSpec,
        bucket: [String: Any],
        id: String,
        resetFormat: ResetFormat,
        specWindowSeconds: Int?,
        secondary: Bool,
        fieldOverride: WindowFieldOverride? = nil,
        label: String? = nil
    ) -> UsageWindow? {
        guard let fields = spec.responseFields else { return nil }
        let utilizationKey = fieldOverride?.utilization ?? fields.utilization
        let resetsAtKey = fieldOverride?.resetsAt ?? fields.resetsAt
        let lenient = fields.allowStringNumbers

        // Some providers nest the numbers one level down (Codex
        // additional_rate_limits entries appear both flat and nested).
        var source = bucket
        if value(at: utilizationKey, in: bucket) == nil,
           let nested = bucket["rate_limit"] as? [String: Any] {
            source = nested
        }

        guard let rawUtilization = windowNumber(value(at: utilizationKey, in: source), lenient: lenient) else { return nil }
        let utilization = fields.utilizationKind == .remaining ? 100 - rawUtilization : rawUtilization
        guard let resetsAt = reset(from: value(at: resetsAtKey, in: source), format: resetFormat, lenient: lenient) else { return nil }

        var windowSeconds = specWindowSeconds
        if let key = fields.windowSeconds,
           let fromResponse = windowNumber(value(at: key, in: source), lenient: lenient),
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
            secondary: secondary,
            label: label
        )
    }

    private static func normalizedID(_ raw: String, prefix: String) -> String {
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
                secondary: mapping.secondary,
                fieldOverride: mapping.fields
            ), windowIDs.insert(window.id).inserted {
                windows.append(window)
            }
        }

        if let additional = spec.additionalWindows,
           let entries = value(at: additional.sourceKey, in: root) as? [Any] {
            for entry in entries.prefix(128) {
                guard let record = entry as? [String: Any] else { continue }
                // Optional per-entry filter (e.g. keep only kind == "weekly_scoped").
                if let filter = additional.filter,
                   (value(at: filter.key, in: record) as? String) != filter.equals {
                    continue
                }
                guard let rawID = value(at: additional.idKey, in: record) as? String,
                      let boundedID = boundedProviderText(rawID, maximumLength: 128)
                else { continue }
                // A prefix means synthesize a stable normalized id
                // (weekly_scoped_fable); without one, the raw id stands.
                let id = additional.idPrefix.map { normalizedID(boundedID, prefix: $0) } ?? boundedID
                let label = additional.labelKey
                    .flatMap { value(at: $0, in: record) as? String }
                    .flatMap { boundedProviderText($0, maximumLength: 64) }
                if let window = readBucket(
                    spec: spec,
                    bucket: record,
                    id: id,
                    resetFormat: additional.resetFormat,
                    specWindowSeconds: additional.windowSeconds,
                    secondary: additional.secondary,
                    fieldOverride: additional.fields,
                    label: label
                ), windowIDs.insert(window.id).inserted {
                    windows.append(window)
                }
            }
        }

        var metrics: [UsageMetric] = []
        var metricIDs = Set<String>()
        for mapping in spec.metricMappings {
            var amount: Double?
            if mapping.aggregate == .sum {
                // A zero-spend month legitimately sums to 0 (root array
                // present but empty); a missing root key, or leaves that all
                // fail to parse, means the shape changed. Mirrors map.ts.
                let firstSegment = mapping.sourceKey.split(separator: ".").first.map(String.init) ?? ""
                let firstKey = firstSegment.hasSuffix("[]") ? String(firstSegment.dropLast(2)) : firstSegment
                // "Root present but empty" means an empty ARRAY. A non-array
                // root — an error envelope, or a wrapper a provider added —
                // collects no leaves either, and calling that a zero-spend
                // month reports a confident $0.00 for a schema change.
                let rootIsUsable: Bool
                if let rootValue = root[firstKey], !(rootValue is NSNull) {
                    rootIsUsable = firstSegment.hasSuffix("[]") ? rootValue is [Any] : true
                } else {
                    rootIsUsable = false
                }
                if rootIsUsable {
                    let leaves = collect(at: mapping.sourceKey, in: root)
                    let numbers = leaves.compactMap { metricNumber($0) }
                    amount = (!leaves.isEmpty && numbers.isEmpty)
                        ? nil
                        : numbers.reduce(0, +)
                } else {
                    amount = nil
                }
            } else {
                amount = metricNumber(value(at: mapping.sourceKey, in: root))
            }
            guard var resolved = amount else { continue }
            if let scale = mapping.scale, scale.isFinite {
                resolved *= scale
            }
            guard resolved.isFinite else { continue }
            // A unitKey (e.g. extra_usage.currency) overrides the static unit
            // when it resolves to a usable string; otherwise the static unit stands.
            let unit = mapping.unitKey
                .flatMap { value(at: $0, in: root) as? String }
                .flatMap { boundedProviderText($0, maximumLength: 32) } ?? mapping.unit
            let metric = UsageMetric(
                id: mapping.id,
                label: mapping.label,
                kind: mapping.kind,
                value: resolved,
                unit: unit,
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
                    id: normalizedID(safeID, prefix: collection.kind.rawValue),
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

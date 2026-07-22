import Foundation

/// Data-driven response mapper — the Swift twin of cli/src/providers/map.ts.
/// FixtureParityTests pins both to the same protocol/fixtures files.
public enum UsageMapper {
    private struct InvalidPathValue {}

    private static func strictUTF8Data(_ body: Data) -> Data? {
        // Raw NUL is illegal JSON and is the structural tell in BOM-less
        // UTF-16/32. TextDecoder strips an optional UTF-8 BOM, so mirror it.
        let doubleBOM = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])
        guard !body.starts(with: doubleBOM),
              !body.contains(0),
              let decoded = String(data: body, encoding: .utf8)
        else { return nil }
        let text = decoded.first == "\u{FEFF}" ? String(decoded.dropFirst()) : decoded
        return Data(text.utf8)
    }

    private struct JSONIntegrityScanner {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0

        mutating func validate() -> Bool {
            guard parseValue(depth: 0) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        mutating private func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating private func scanString() -> Data? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index
            index += 1
            // JSONSerialization strips a leading U+FEFF from every string.
            // Detect both its literal UTF-8 bytes and a case-insensitive
            // `\uFEFF` escape before Foundation can change the value.
            if index + 2 < bytes.count,
               bytes[index] == 0xEF,
               bytes[index + 1] == 0xBB,
               bytes[index + 2] == 0xBF {
                return nil
            }
            if index + 5 < bytes.count,
               bytes[index] == 0x5C,
               bytes[index + 1] | 0x20 == 0x75,
               bytes[index + 2] | 0x20 == 0x66,
               bytes[index + 3] | 0x20 == 0x65,
               bytes[index + 4] | 0x20 == 0x66,
               bytes[index + 5] | 0x20 == 0x66 {
                return nil
            }
            while index < bytes.count {
                if bytes[index] == 0x22 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard let decoded = try? JSONSerialization.jsonObject(
                        with: token,
                        options: .fragmentsAllowed
                    ) as? String else { return nil }
                    return Data(decoded.utf8)
                }
                if bytes[index] == 0x5C {
                    index += 1
                    guard index < bytes.count else { return nil }
                }
                index += 1
            }
            return nil
        }

        mutating private func parseValue(depth: Int) -> Bool {
            nodes += 1
            guard nodes <= 10_000, depth <= 64 else { return false }
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 0x7B:
                return parseObject(depth: depth + 1)
            case 0x5B:
                return parseArray(depth: depth + 1)
            case 0x22:
                return scanString() != nil
            default:
                let start = index
                while index < bytes.count,
                      ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D, 0x5D].contains(bytes[index]) {
                    index += 1
                }
                return index > start
            }
        }

        mutating private func parseObject(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D {
                index += 1
                return true
            }
            var keys = Set<Data>()
            while index < bytes.count {
                skipWhitespace()
                guard let key = scanString(), keys.insert(key).inserted else { return false }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else { return false }
                index += 1
                guard parseValue(depth: depth) else { return false }
                skipWhitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 0x7D {
                    index += 1
                    return true
                }
                guard bytes[index] == 0x2C else { return false }
                index += 1
            }
            return false
        }

        mutating private func parseArray(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D {
                index += 1
                return true
            }
            while index < bytes.count {
                guard parseValue(depth: depth) else { return false }
                skipWhitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 0x5D {
                    index += 1
                    return true
                }
                guard bytes[index] == 0x2C else { return false }
                index += 1
            }
            return false
        }
    }

    private static func jsonHasUniqueObjectKeys(_ body: Data) -> Bool {
        var scanner = JSONIntegrityScanner(bytes: Array(body))
        return scanner.validate()
    }
    public struct Mapped: Equatable, Sendable {
        public let planLabel: String?
        public let windows: [UsageWindow]
        public let metrics: [UsageMetric]
        public let incomplete: Bool
        public let recognizedEmpty: Bool
    }

    /// ISO-8601 Internet-date-time parsing. The TS side first enforces the same
    /// grammar, then uses `new Date(value)` only for conversion. Both accept
    /// whole and fractional seconds.
    ///
    /// One `ISO8601DateFormatter` cannot parse both forms — `.withFractionalSeconds`
    /// makes the fraction mandatory, not optional — so both are tried. They are
    /// created per call rather than shared in a `static let`: a mutable
    /// reference type in global state is a data race under concurrent mapping
    /// (`refreshAll` maps every account in a task group) and a hard error in the
    /// Swift 6 language mode.
    private static func parseISO8601(_ string: String) -> Date? {
        guard string.range(
            of: #"^[0-9]{4}-(?:0[1-9]|1[0-2])-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):?[0-5][0-9]|14:?00))$"#,
            options: .regularExpression
        ) != nil,
        let year = Int(string.prefix(4)), (1970...2099).contains(year),
        let month = Int(string.dropFirst(5).prefix(2)),
        let day = Int(string.dropFirst(8).prefix(2))
        else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= days[month - 1] else { return nil }
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
        if dotPath == "$" { return object }
        let path = dotPath.hasPrefix("$.") ? String(dotPath.dropFirst(2)) : dotPath
        var current: Any? = object
        for segment in path.split(separator: ".") {
            if current is InvalidPathValue { return current }
            guard let dict = current as? [String: Any] else { return nil }
            if segment.hasSuffix("]"),
               let open = segment.firstIndex(of: "["),
               let equals = segment.firstIndex(of: "="),
               open < equals {
                let key = String(segment[..<open])
                let matchKey = String(segment[segment.index(after: open)..<equals])
                let matchValue = String(segment[segment.index(after: equals)..<segment.index(before: segment.endIndex)])
                guard let array = dict[key] as? [Any] else { return nil }
                guard array.count <= 128,
                      array.allSatisfy({ $0 is [String: Any] })
                else { return InvalidPathValue() }
                let matches = array.compactMap { $0 as? [String: Any] }
                    .filter { ($0[matchKey] as? String) == matchValue }
                guard matches.count <= 1 else { return InvalidPathValue() }
                current = matches.first
            } else {
                current = dict[String(segment)]
            }
        }
        return current
    }

    private static func scalarString(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        guard let value = raw as? NSNumber else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue ? "true" : "false"
        }
        let number = value.doubleValue
        guard number.isFinite else { return nil }
        if number.rounded() == number { return String(format: "%.0f", number) }
        return String(number)
    }

    private static func scalarEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func conditionScalar(_ raw: Any?, condition: FieldCondition) -> String? {
        switch condition.valueType {
        case "boolean":
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        case "number":
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue,
                  abs(value.doubleValue) <= 9_007_199_254_740_991
            else { return nil }
            return value.doubleValue == 0 ? "0" : String(format: "%.0f", value.doubleValue)
        case "string":
            guard raw is String else { return nil }
        default:
            break
        }
        return scalarString(raw)
    }

    private static func matches(_ record: [String: Any], conditions: [FieldCondition]) -> Bool {
        conditions.allSatisfy {
            guard let actual = conditionScalar(value(at: $0.key, in: record), condition: $0) else {
                return false
            }
            return scalarEquals(actual, $0.equals)
        }
    }

    private static func conditionContractInvalid(
        _ record: [String: Any],
        conditions: [FieldCondition]
    ) -> Bool {
        conditions.contains { condition in
            guard !condition.allowedNonMatches.isEmpty else { return false }
            guard let actual = conditionScalar(
                value(at: condition.key, in: record),
                condition: condition
            ) else { return true }
            return !scalarEquals(actual, condition.equals)
                && !condition.allowedNonMatches.contains(where: { scalarEquals(actual, $0) })
        }
    }

    private static func isPresent(_ value: Any?) -> Bool {
        value != nil && !(value is NSNull)
    }

    private static func isValidDecodedJSON(_ root: Any) -> Bool {
        var nodes = 0
        func visit(_ value: Any, depth: Int) -> Bool {
            nodes += 1
            guard nodes <= 10_000, depth <= 64 else { return false }
            if value is NSNull || value is String { return true }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
                return number.doubleValue.isFinite
            }
            if let array = value as? [Any] {
                return array.allSatisfy { visit($0, depth: depth + 1) }
            }
            if let object = value as? [String: Any] {
                return object.values.allSatisfy { visit($0, depth: depth + 1) }
            }
            return false
        }
        return visit(root, depth: 0)
    }

    private static func responseIsRecognizedEmpty(spec: ProviderSpec, root: Any) -> Bool {
        guard let rule = spec.recognizedEmpty, !rule.allEntriesMatch.isEmpty else { return false }
        for path in rule.sourceKeys {
            guard let entries = value(at: path, in: root) as? [Any], !entries.isEmpty else {
                continue
            }
            // The mapper inspects at most 128 provider-controlled entries.
            // A longer collection cannot be certified empty from a prefix.
            guard entries.count <= 128 else { return false }
            return entries.allSatisfy { entry in
                guard let record = entry as? [String: Any] else { return false }
                return matches(record, conditions: rule.allEntriesMatch)
            }
        }
        return false
    }

    private static func windowDurationSeconds(
        in record: [String: Any],
        duration: WindowDuration
    ) -> Int? {
        // Keep arithmetic inside JavaScript's exact-integer range so the
        // Swift and TypeScript mappers make the same decision for hostile
        // provider values. Check before Int conversion: 64-bit Int accepts
        // values that Number.isSafeInteger correctly rejects.
        let javaScriptMaxSafeInteger = 9_007_199_254_740_991
        guard let unit = scalarString(value(at: duration.unitKey, in: record)),
              let secondsPerUnit = duration.unitSeconds[unit],
              secondsPerUnit > 0,
              secondsPerUnit <= javaScriptMaxSafeInteger,
              let count = windowNumber(value(at: duration.numberKey, in: record), lenient: true),
              count > 0,
              count.rounded() == count,
              count <= Double(javaScriptMaxSafeInteger)
        else { return nil }
        let seconds = count * Double(secondsPerUnit)
        guard seconds.isFinite,
              seconds <= Double(javaScriptMaxSafeInteger),
              let exact = Int(exactly: seconds),
              exact > 0
        else { return nil }
        return exact
    }

    private static func matchesDuration(
        _ record: [String: Any],
        duration: WindowDuration?
    ) -> Bool {
        guard let duration else { return true }
        guard let seconds = windowDurationSeconds(in: record, duration: duration) else { return false }
        if !duration.allowedSeconds.isEmpty, !duration.allowedSeconds.contains(seconds) { return false }
        if let minimum = duration.minimumSeconds, seconds < minimum { return false }
        if let maximum = duration.maximumSecondsExclusive, seconds >= maximum { return false }
        return true
    }

    private static func exhaustiveCollectionsAreValid(
        spec: ProviderSpec,
        root: Any
    ) -> Bool {
        for contract in spec.exhaustiveCollections {
            let present = contract.sourceKeys.compactMap { path -> Any? in
                let raw = value(at: path, in: root)
                return isPresent(raw) ? raw : nil
            }
            guard !present.isEmpty else { continue }
            guard present.count == 1, let entries = present[0] as? [Any], entries.count <= 128 else {
                return false
            }
            var counts: [Data: Int] = [:]
            for entry in entries {
                guard let record = entry as? [String: Any] else { return false }
                var identities: [String] = []
                var invalidIdentity = false
                for key in contract.identityKeys {
                    let raw = value(at: key, in: record)
                    guard isPresent(raw) else { continue }
                    guard let identity = raw as? String else {
                        invalidIdentity = true
                        continue
                    }
                    identities.append(identity)
                }
                guard !invalidIdentity,
                      !identities.isEmpty,
                      Set(identities.map { Data($0.utf8) }).count == 1,
                      let identity = identities.first,
                      contract.allowedIdentities.contains(where: { scalarEquals(identity, $0) })
                else { return false }
                let identityData = Data(identity.utf8)
                counts[identityData, default: 0] += 1
                if let duration = contract.duration,
                   contract.durationIdentities.contains(where: { scalarEquals(identity, $0) }),
                   !matchesDuration(record, duration: duration) {
                    return false
                }
            }
            if contract.uniqueIdentities.contains(where: {
                (counts[Data($0.utf8)] ?? 0) > 1
            }) { return false }
        }
        return true
    }

    private struct WindowBucketResolution {
        let bucket: [String: Any]?
        let invalid: Bool
    }

    private static func resolveWindowBucket(
        in root: Any,
        sourceKey: String,
        sourceKeys: [String],
        sourceContainer: WindowSourceContainer,
        conditions: [FieldCondition],
        omitWhen: [FieldCondition] = [],
        anyConditions: [FieldCondition] = [],
        duration: WindowDuration? = nil,
        identityAliases: [String] = []
    ) -> WindowBucketResolution {
        var invalid = false
        var bucket: [String: Any]?
        var matchCount = 0
        func consider(_ record: [String: Any]) {
            if !identityAliases.isEmpty {
                var aliases: [String] = []
                for key in identityAliases {
                    let raw = value(at: key, in: record)
                    guard isPresent(raw) else { continue }
                    guard let alias = scalarString(raw) else {
                        invalid = true
                        continue
                    }
                    aliases.append(alias)
                }
                if Set(aliases.map { Data($0.utf8) }).count > 1 {
                    invalid = true
                }
            }
            if conditionContractInvalid(record, conditions: conditions) { invalid = true }
            for condition in omitWhen
            where isPresent(value(at: condition.key, in: record))
                && conditionContractInvalid(record, conditions: [condition]) {
                invalid = true
            }
            let eligible = (conditions.isEmpty || matches(record, conditions: conditions))
                && (anyConditions.isEmpty || anyConditions.contains(where: { matches(record, conditions: [$0]) }))
                && (omitWhen.isEmpty || !matches(record, conditions: omitWhen))
                && matchesDuration(record, duration: duration)
            guard eligible else { return }
            matchCount += 1
            if bucket == nil { bucket = record }
        }
        for path in [sourceKey] + sourceKeys {
            let resolved = value(at: path, in: root)
            if resolved == nil || resolved is NSNull { continue }
            if sourceContainer == .array {
                guard let entries = resolved as? [Any] else {
                    invalid = true
                    continue
                }
                if entries.count > 128 { invalid = true }
                if entries.prefix(128).contains(where: { !($0 is [String: Any]) }) {
                    invalid = true
                }
                for entry in entries.prefix(128) {
                    guard let record = entry as? [String: Any] else { continue }
                    consider(record)
                }
                continue
            }
            guard !(resolved is [Any]), let record = resolved as? [String: Any] else {
                invalid = true
                continue
            }
            consider(record)
        }
        if matchCount > 1 { invalid = true }
        return WindowBucketResolution(bucket: bucket, invalid: invalid)
    }

    private static func fieldValue(at path: String, bucket: [String: Any], root: Any) -> Any? {
        path == "$" || path.hasPrefix("$.")
            ? value(at: path, in: root)
            : value(at: path, in: bucket)
    }

    /// Aggregate-path lookup mirrored from the TS mapper: segments ending in
    /// `[]` flat-map arrays, so `data[].results[].amount.value` collects
    /// every matching leaf. Bounded at 128 elements per array level.
    private struct CollectedPath {
        let values: [Any]
        let truncated: Bool
        let invalidStructure: Bool
    }

    private static func collect(at dotPath: String, in object: Any?) -> CollectedPath {
        var frontier: [Any] = object.map { [$0] } ?? []
        var truncated = false
        var invalidStructure = false
        for segment in dotPath.split(separator: ".") {
            var next: [Any] = []
            let isFlatMap = segment.hasSuffix("[]")
            let key = isFlatMap ? String(segment.dropLast(2)) : String(segment)
            for node in frontier {
                guard let dict = node as? [String: Any] else {
                    invalidStructure = true
                    continue
                }
                let value = dict[key]
                if isFlatMap {
                    if let array = value as? [Any] {
                        if array.count > 128 { truncated = true }
                        next.append(contentsOf: array.prefix(128))
                    } else {
                        invalidStructure = true
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
            if frontier.isEmpty {
                return CollectedPath(
                    values: [],
                    truncated: truncated,
                    invalidStructure: invalidStructure
                )
            }
        }
        return CollectedPath(
            values: frontier,
            truncated: truncated,
            invalidStructure: invalidStructure
        )
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
    /// Surrounding whitespace is tolerated. The grammar is explicitly decimal
    /// so language-specific forms such as 0x10 or 0b10 cannot create parity
    /// drift between JavaScript Number() and Swift Double().
    private static func metricNumber(_ raw: Any?) -> Double? {
        if let number = number(raw) { return number }
        guard let string = raw as? String,
              isASCIIDecimalInput(string)
        else { return nil }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard !trimmed.isEmpty,
              isASCIIDecimalText(trimmed),
              trimmed.range(
                  of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                  options: .regularExpression
              ) != nil,
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
        guard lenient,
              let string = raw as? String,
              isASCIIDecimalInput(string)
        else { return nil }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard !trimmed.isEmpty,
              isASCIIDecimalText(trimmed),
              trimmed.range(
                  of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                  options: .regularExpression
              ) != nil,
              let value = Double(trimmed),
              value.isFinite
        else { return nil }
        return value
    }

    /// Foundation's regular-expression bridge can treat U+FEFF as an
    /// ignorable boundary character. JavaScript's ASCII decimal grammar does
    /// not. Reject every non-ASCII scalar before applying the shared grammar.
    private static func isASCIIDecimalText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x2B, 0x2D, 0x2E, 0x45, 0x65:
                return true
            default:
                return false
            }
        }
    }

    private static func isASCIIDecimalInput(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x20,
                 0x30...0x39, 0x2B, 0x2D, 0x2E, 0x45, 0x65:
                return true
            default:
                return false
            }
        }
    }

    /// Returns nil for a missing or malformed reset; .some(nil) only for an
    /// explicit JSON null. Missing configured fields are schema drift.
    private static func reset(from raw: Any?, format: ResetFormat, lenient: Bool) -> Date?? {
        if raw == nil { return nil }
        if raw is NSNull { return .some(nil) }
        switch format {
        case .iso8601:
            guard let string = raw as? String, let date = parseISO8601(string) else { return nil }
            return .some(wholeSeconds(date))
        case .unixSeconds, .unixMillis:
            guard let numeric = windowNumber(raw, lenient: lenient),
                  numeric >= 0,
                  numeric.rounded() == numeric,
                  numeric <= 9_007_199_254_740_991,
                  numeric < (format == .unixMillis ? 4_102_444_800_000 : 4_102_444_800)
            else { return nil }
            let milliseconds = format == .unixMillis ? numeric : numeric * 1_000
            // Keep parity with JavaScript Date's representable range and
            // reject hostile finite values that would fail later formatting.
            guard milliseconds.isFinite,
                  abs(milliseconds) <= 8_640_000_000_000_000
            else { return nil }
            return .some(wholeSeconds(Date(timeIntervalSince1970: milliseconds / 1_000)))
        }
    }

    /// Truncates to whole seconds, matching the TS mapper's `toIso`, which
    /// formats with `toISOString()` and strips the `.mmm` before returning.
    ///
    /// Claude's `limits[]` entries carry microsecond precision
    /// (`...T07:00:00.392792+00:00`), so without this the two mappers produce
    /// timestamps that differ by a fraction of a second — identical when
    /// printed, unequal when compared, and impossible to express in a fixture.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private static func readBucket(
        spec: ProviderSpec,
        bucket: [String: Any],
        root: Any,
        id: String,
        resetFormat: ResetFormat,
        specWindowSeconds: Int?,
        secondary: Bool,
        fieldOverride: WindowFieldOverride? = nil,
        label: String? = nil,
        idByWindowSeconds: [Int: String] = [:],
        duration: WindowDuration? = nil
    ) -> UsageWindow? {
        guard let fields = spec.responseFields else { return nil }
        let utilizationKey = fieldOverride?.utilization ?? fields.utilization
        let resetsAtKey = fieldOverride?.resetsAt ?? fields.resetsAt
        let lenient = fields.allowStringNumbers

        let utilization: Double
        if let usedKey = fieldOverride?.used,
           let limitKey = fieldOverride?.limit {
            guard let used = windowNumber(fieldValue(at: usedKey, bucket: bucket, root: root), lenient: lenient),
                  let limit = windowNumber(fieldValue(at: limitKey, bucket: bucket, root: root), lenient: lenient),
                  used >= 0,
                  limit > 0
            else { return nil }
            utilization = used / limit * 100
        } else {
            guard let rawUtilization = windowNumber(
                fieldValue(at: utilizationKey, bucket: bucket, root: root),
                lenient: lenient
            ), (0...100).contains(rawUtilization)
            else { return nil }
            utilization = fields.utilizationKind == .remaining ? 100 - rawUtilization : rawUtilization
        }
        guard utilization.isFinite, utilization >= 0 else { return nil }
        guard let resetsAt = reset(
            from: fieldValue(at: resetsAtKey, bucket: bucket, root: root),
            format: resetFormat,
            lenient: lenient
        ) else { return nil }

        var windowSeconds = specWindowSeconds
        if let duration {
            guard let derived = windowDurationSeconds(in: bucket, duration: duration) else { return nil }
            windowSeconds = derived
        }
        if let key = fields.windowSeconds,
           let fromResponse = windowNumber(
               fieldValue(at: key, bucket: bucket, root: root),
               lenient: lenient
           ),
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

        let resolvedID: String
        if idByWindowSeconds.isEmpty {
            resolvedID = id
        } else {
            guard let seconds = windowSeconds,
                  let durationID = idByWindowSeconds[seconds]
            else { return nil }
            resolvedID = durationID
        }

        return UsageWindow(
            id: resolvedID,
            utilization: min(100, max(0, utilization)),
            resetsAt: resetsAt,
            windowSeconds: windowSeconds,
            secondary: secondary,
            label: label
        )
    }

    /// Returns nil for a healthy or unconfigured envelope. A configured field
    /// that disappears is schema drift; known auth codes are authExpired; all
    /// other explicit provider failures use the existing network state.
    public static func envelopeStatus(spec: ProviderSpec, body: Data) -> SnapshotStatus? {
        guard let envelope = spec.responseEnvelope else { return nil }
        guard let normalizedBody = strictUTF8Data(body),
              jsonHasUniqueObjectKeys(normalizedBody),
              let root = (try? JSONSerialization.jsonObject(with: normalizedBody)) as? [String: Any],
              isValidDecodedJSON(root),
              let code = conditionScalar(
                  value(at: envelope.codeKey, in: root),
                  condition: FieldCondition(
                      key: envelope.codeKey,
                      equals: envelope.okCode,
                      valueType: envelope.codeValueType
                  )
              )
        else { return .schemaChanged }
        var successMatches = true
        if let successKey = envelope.successKey {
            guard let success = conditionScalar(
                value(at: successKey, in: root),
                condition: FieldCondition(
                    key: successKey,
                    equals: envelope.successValue,
                    valueType: envelope.successValueType
                )
            ) else {
                return .schemaChanged
            }
            successMatches = scalarEquals(success, envelope.successValue)
        }
        if scalarEquals(code, envelope.okCode), successMatches { return nil }
        return envelope.authCodes.contains(where: { scalarEquals(code, $0) }) ? .authExpired : .network
    }

    private static func normalizedIDSuffix(_ raw: String) -> String {
        // Mirrors the TS Unicode regex `[^a-z0-9]`: each non-ASCII Unicode
        // scalar becomes one underscore on both sides. Iterating UTF-16 here
        // would turn one supplementary-plane scalar into two underscores.
        let safe = raw.lowercased().unicodeScalars.map { scalar -> Character in
            if (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
                return Character(scalar)
            }
            return "_"
        }
        return String(safe)
    }

    private static func normalizedID(_ raw: String, prefix: String) -> String {
        "\(prefix)_\(normalizedIDSuffix(raw))"
    }

    private static func boundedProviderText(_ raw: String, maximumLength: Int) -> String? {
        // UTF-16 code units, matching JavaScript String.length so both
        // mappers accept or reject the same provider-supplied identifiers.
        guard !raw.isEmpty,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.utf16.count <= maximumLength,
              !raw.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .surrogate:
                      return true
                  default:
                      return false
                  }
              })
        else { return nil }
        return raw
    }

    private static func windowCandidateUnavailable(
        spec: ProviderSpec,
        bucket: [String: Any],
        root: Any,
        fieldOverride: WindowFieldOverride?
    ) -> Bool {
        guard let fields = spec.responseFields else { return false }
        if let usedKey = fieldOverride?.used,
           let limitKey = fieldOverride?.limit {
            let used = fieldValue(at: usedKey, bucket: bucket, root: root)
            let limit = fieldValue(at: limitKey, bucket: bucket, root: root)
            if !isPresent(used) || !isPresent(limit) { return true }
            return windowNumber(limit, lenient: fields.allowStringNumbers) == 0
        }
        let utilizationKey = fieldOverride?.utilization ?? fields.utilization
        return !isPresent(fieldValue(at: utilizationKey, bucket: bucket, root: root))
    }

    /// Returns nil when nothing maps at all. Missing/null buckets are optional;
    /// present malformed buckets retain partial output and set `incomplete`.
    public static func map(spec: ProviderSpec, body: Data) -> Mapped? {
        guard let normalizedBody = strictUTF8Data(body),
              jsonHasUniqueObjectKeys(normalizedBody),
              let root = (try? JSONSerialization.jsonObject(with: normalizedBody)) as? [String: Any],
              isValidDecodedJSON(root)
        else { return nil }

        var windows: [UsageWindow] = []
        var windowIDs = Set<String>()
        var resolvedFallbackGroups = Set<String>()
        var incomplete = spec.incompleteWhen.contains { matches(root, conditions: [$0]) }
            || spec.requiredConditions.contains { !matches(root, conditions: [$0]) }
            || spec.requiredPaths.contains { value(at: $0, in: root) == nil }
            || spec.absentOrNullPaths.contains { isPresent(value(at: $0, in: root)) }
            || !exhaustiveCollectionsAreValid(spec: spec, root: root)
        for mapping in spec.windows {
            if let group = mapping.fallbackGroup, resolvedFallbackGroups.contains(group) {
                continue
            }
            let resolution = resolveWindowBucket(
                in: root,
                sourceKey: mapping.sourceKey,
                sourceKeys: mapping.sourceKeys,
                sourceContainer: mapping.sourceContainer,
                conditions: mapping.conditions,
                omitWhen: mapping.omitWhen,
                anyConditions: mapping.anyConditions,
                duration: mapping.duration,
                identityAliases: mapping.identityAliases
            )
            if resolution.invalid { incomplete = true }
            guard let bucket = resolution.bucket else { continue }
            guard let window = readBucket(
                spec: spec,
                bucket: bucket,
                root: root,
                id: mapping.id,
                resetFormat: mapping.resetFormat,
                specWindowSeconds: mapping.windowSeconds,
                secondary: mapping.secondary,
                fieldOverride: mapping.fields,
                label: mapping.label,
                idByWindowSeconds: mapping.idByWindowSeconds,
                duration: mapping.duration
            ) else {
                let unavailable = windowCandidateUnavailable(
                    spec: spec,
                    bucket: bucket,
                    root: root,
                    fieldOverride: mapping.fields
                )
                if !unavailable || mapping.requiredWhenPresent { incomplete = true }
                continue
            }
            if windowIDs.insert(window.id).inserted {
                windows.append(window)
            } else {
                // A duration-derived collision can otherwise hide one static
                // session/weekly lane while minimumWindows still passes.
                incomplete = true
            }
            if let group = mapping.fallbackGroup { resolvedFallbackGroups.insert(group) }
        }

        if let additional = spec.additionalWindows {
            let rawEntries = value(at: additional.sourceKey, in: root)
            if let entries = rawEntries as? [Any] {
                if entries.count > 128 { incomplete = true }
                var mappedEntries = 0
                for entry in entries.prefix(128) {
                guard let record = entry as? [String: Any] else {
                    if additional.requiredWhenPresent { incomplete = true }
                    continue
                }
                // Optional per-entry filter (e.g. keep only kind == "weekly_scoped").
                if let filter = additional.filter {
                    guard let filterValue = scalarString(value(at: filter.key, in: record)) else {
                        if additional.requiredWhenPresent { incomplete = true }
                        continue
                    }
                    if !scalarEquals(filterValue, filter.equals) { continue }
                }
                if !additional.conditions.isEmpty,
                   !matches(record, conditions: additional.conditions) {
                    // An explicit scalar mismatch is an ineligible lane. A
                    // missing/non-scalar condition after the kind filter
                    // matched is a changed schema.
                    if additional.requiredWhenPresent,
                       conditionContractInvalid(record, conditions: additional.conditions) {
                        incomplete = true
                    }
                    continue
                }
                guard let rawID = value(at: additional.idKey, in: record) as? String,
                      let boundedID = boundedProviderText(rawID, maximumLength: 128)
                else {
                    if additional.requiredWhenPresent { incomplete = true }
                    continue
                }
                // A prefixed id must retain at least one ASCII identity
                // character after normalization. Otherwise distinct
                // punctuation/non-ASCII model names collapse to underscore
                // aliases such as `weekly_scoped____`.
                let normalizedSuffix = normalizedIDSuffix(boundedID)
                if additional.idPrefix != nil,
                   normalizedSuffix.range(of: "[a-z0-9]", options: .regularExpression) == nil {
                    incomplete = true
                    continue
                }
                if additional.idFormat == "asciiSlug",
                   boundedID.range(
                       of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                       options: .regularExpression
                   ) == nil {
                    incomplete = true
                    continue
                }
                // A prefix means synthesize a stable normalized id
                // (weekly_scoped_fable); without one, the raw id stands.
                let id = additional.idPrefix.map { "\($0)_\(normalizedSuffix)" } ?? boundedID
                let label = additional.labelKey
                    .flatMap { value(at: $0, in: record) as? String }
                    .flatMap { boundedProviderText($0, maximumLength: 64) }
                // A declared provider label is required. Codex model lanes use
                // limit_name for display and Models-tab identity, so accepting
                // a missing or blank value would report Live while hiding the
                // lane from the user.
                if additional.labelKey != nil, label == nil {
                    incomplete = true
                    continue
                }
                let entryWindows: [AdditionalEntryWindow?] = additional.entryWindows.isEmpty
                    ? [nil]
                    : additional.entryWindows.map(Optional.some)
                var mappedForEntry = 0
                for entryWindow in entryWindows {
                    let bucket: [String: Any]
                    if let entryWindow {
                        let resolution = resolveWindowBucket(
                            in: record,
                            sourceKey: entryWindow.sourceKey,
                            sourceKeys: [],
                            sourceContainer: entryWindow.sourceContainer,
                            conditions: []
                        )
                        if resolution.invalid { incomplete = true }
                        guard let resolved = resolution.bucket else { continue }
                        bucket = resolved
                    } else {
                        bucket = record
                    }
                    let suffix = entryWindow?.idSuffix
                    let baseID = suffix.map { "\(id)_\($0)" } ?? id
                    let resolvedLabel: String?
                    if let label, let labelSuffix = entryWindow?.labelSuffix {
                        resolvedLabel = "\(label) · \(labelSuffix)"
                    } else {
                        resolvedLabel = label
                    }
                    guard var window = readBucket(
                        spec: spec,
                        bucket: bucket,
                        root: record,
                        id: baseID,
                        resetFormat: entryWindow?.resetFormat ?? additional.resetFormat,
                        specWindowSeconds: entryWindow?.windowSeconds ?? additional.windowSeconds,
                        secondary: entryWindow?.secondary ?? additional.secondary,
                        fieldOverride: entryWindow?.fields ?? additional.fields,
                        label: resolvedLabel
                    ) else {
                        incomplete = true
                        continue
                    }
                    if let entryWindow {
                        let durationSuffix: String?
                        if entryWindow.idSuffixByWindowSeconds.isEmpty {
                            durationSuffix = nil
                        } else {
                            guard let seconds = window.windowSeconds,
                                  let suffix = entryWindow.idSuffixByWindowSeconds[seconds],
                                  !suffix.isEmpty
                            else {
                                incomplete = true
                                continue
                            }
                            durationSuffix = suffix
                        }
                        let durationLabel: String?
                        if entryWindow.labelSuffixByWindowSeconds.isEmpty {
                            durationLabel = nil
                        } else {
                            guard let seconds = window.windowSeconds,
                                  let labelSuffix = entryWindow.labelSuffixByWindowSeconds[seconds],
                                  !labelSuffix.isEmpty
                            else {
                                incomplete = true
                                continue
                            }
                            durationLabel = labelSuffix
                        }
                        window = UsageWindow(
                            id: durationSuffix.map { "\(id)_\($0)" } ?? window.id,
                            utilization: window.utilization,
                            resetsAt: window.resetsAt,
                            windowSeconds: window.windowSeconds,
                            secondary: window.secondary,
                            label: label.flatMap { base in
                                durationLabel.map { "\(base) · \($0)" }
                            } ?? window.label
                        )
                    }
                    if windowIDs.insert(window.id).inserted {
                        windows.append(window)
                    } else {
                        incomplete = true
                        continue
                    }
                    mappedForEntry += 1
                }
                if additional.requiredWhenPresent, mappedForEntry == 0 {
                    incomplete = true
                }
                if mappedForEntry > 0 { mappedEntries += 1 }
                }
                // Unfiltered Codex lanes must contain at least one real,
                // mappable object when the array is non-empty. Filtered
                // Claude limits[] may legitimately contain no weekly_scoped
                // entries at all.
                if additional.requiredWhenPresent,
                   additional.filter == nil,
                   !entries.isEmpty,
                   mappedEntries == 0 {
                    incomplete = true
                }
            } else if rawEntries != nil, additional.requiredWhenPresent {
                // Present but non-array is a changed container shape, not an
                // absent optional collection.
                incomplete = true
            }
        }

        var metrics: [UsageMetric] = []
        var metricIDs = Set<String>()
        for mapping in spec.metricMappings {
            // Duplicate ids are ordered fallbacks. A successful canonical
            // mapping makes later legacy candidates irrelevant.
            if metricIDs.contains(mapping.id) { continue }
            if mapping.fallbackBlockedBy.contains(where: { isPresent(value(at: $0, in: root)) }) {
                continue
            }
            if !mapping.conditions.isEmpty {
                let familyPresent = mapping.presencePaths.contains {
                    isPresent(value(at: $0, in: root))
                }
                if conditionContractInvalid(root, conditions: mapping.conditions) {
                    if familyPresent { incomplete = true }
                    continue
                }
                if !matches(root, conditions: mapping.conditions) { continue }
            }
            let rawSource = value(at: mapping.sourceKey, in: root)
            if mapping.presencePaths.contains(where: { isPresent(value(at: $0, in: root)) }),
               !isPresent(rawSource) {
                incomplete = true
                continue
            }
            if mapping.aggregate != .sum,
               isPresent(rawSource),
               metricNumber(rawSource) == nil {
                incomplete = true
                continue
            }
            let missingNumericRequirement = mapping.requires.contains {
                metricNumber(value(at: $0, in: root)) == nil
            }
            let missingPresenceRequirement = mapping.requiresPresent.contains {
                !isPresent(value(at: $0, in: root))
            }
            if missingNumericRequirement || missingPresenceRequirement {
                if mapping.incompleteWhenAnyRequiredPresent,
                   (mapping.requires + mapping.requiresPresent).contains(where: {
                       isPresent(value(at: $0, in: root))
                   }) {
                    incomplete = true
                }
                continue
            }
            if mapping.equalFields.contains(where: { paths in
                let values = paths.map { scalarString(value(at: $0, in: root)) }
                return values.contains(where: { $0 == nil })
                    || Set(values.compactMap { $0 }.map { Data($0.utf8) }).count > 1
            }) {
                incomplete = true
                continue
            }
            if mapping.requiresPositive.contains(where: {
                guard let value = metricNumber(value(at: $0, in: root)) else { return true }
                return value <= 0
            }) {
                continue
            }
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
                    let collected = collect(at: mapping.sourceKey, in: root)
                    let numbers = collected.values.compactMap { metricNumber($0) }
                    if collected.truncated
                        || collected.invalidStructure
                        || numbers.count != collected.values.count {
                        // Summing a valid subset would produce a plausible but
                        // false billing total. Surface the provider change and
                        // omit the metric instead.
                        incomplete = true
                        amount = nil
                    } else {
                        if let unitKey = mapping.aggregateUnitKey {
                            let units = collect(at: unitKey, in: root)
                            if units.truncated
                                || units.invalidStructure
                                || units.values.count != collected.values.count
                                || mapping.aggregateExpectedUnit == nil
                                || units.values.contains(where: {
                                    scalarString($0) != mapping.aggregateExpectedUnit
                                }) {
                                incomplete = true
                                amount = nil
                            } else {
                                amount = numbers.reduce(0, +)
                            }
                        } else {
                            amount = numbers.reduce(0, +)
                        }
                    }
                } else {
                    amount = nil
                }
            } else {
                amount = metricNumber(value(at: mapping.sourceKey, in: root))
            }
            guard var resolved = amount else { continue }
            var usedExponent = false
            if let exponentKey = mapping.exponentKey {
                let rawExponent = value(at: exponentKey, in: root)
                if rawExponent != nil, !(rawExponent is NSNull) {
                    guard let exponent = metricNumber(rawExponent),
                          exponent.isFinite,
                          exponent.rounded() == exponent,
                          (0...18).contains(exponent)
                    else {
                        // Present but malformed denomination metadata cannot
                        // safely fall back to a guessed scale. Keep any legacy
                        // value visible only under schemaChanged.
                        incomplete = true
                        continue
                    }
                    resolved /= pow(10, exponent)
                    usedExponent = true
                }
            }
            if !usedExponent, let scale = mapping.scale, scale.isFinite {
                resolved *= scale
            }
            guard resolved.isFinite else { continue }
            var unit = mapping.unit
            if let unitKey = mapping.unitKey {
                let rawUnit = value(at: unitKey, in: root)
                if isPresent(rawUnit) {
                    guard let rawString = rawUnit as? String,
                          let safeUnit = boundedProviderText(rawString, maximumLength: 32)
                    else {
                        incomplete = true
                        continue
                    }
                    unit = safeUnit
                }
            }
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
            if entries.count > 128 { incomplete = true }
            for entry in entries.prefix(128) {
                guard let record = entry as? [String: Any] else {
                    incomplete = true
                    continue
                }
                guard let rawID = value(at: collection.idKey, in: record) as? String,
                      let safeID = boundedProviderText(rawID, maximumLength: 128),
                      let amount = metricNumber(value(at: collection.valueKey, in: record))
                else {
                    incomplete = true
                    continue
                }
                var unit: String?
                if let unitKey = collection.unitKey {
                    let rawUnit = value(at: unitKey, in: record)
                    if isPresent(rawUnit) {
                        guard let rawString = rawUnit as? String,
                              let safeUnit = boundedProviderText(rawString, maximumLength: 32)
                        else {
                            incomplete = true
                            continue
                        }
                        unit = safeUnit
                    }
                }
                let suffix = unit ?? safeID
                let metric = UsageMetric(
                    id: normalizedID(safeID, prefix: collection.kind.rawValue),
                    label: "\(collection.label) (\(suffix))",
                    kind: collection.kind,
                    value: amount,
                    unit: unit,
                    secondary: collection.secondary
                )
                guard metricIDs.insert(metric.id).inserted else {
                    incomplete = true
                    continue
                }
                metrics.append(metric)
            }
        }

        let recognizedEmpty = responseIsRecognizedEmpty(spec: spec, root: root)
        guard !windows.isEmpty || !metrics.isEmpty || recognizedEmpty else { return nil }

        var planLabel: String?
        if let planKey = spec.planKey {
            let rawPlan = value(at: planKey, in: root)
            if let plan = rawPlan as? String {
                planLabel = boundedProviderText(plan, maximumLength: 128)
            }
            // requiredPaths upgrades an otherwise optional plan label to a
            // required, non-null provider string. Codex uses this for its
            // upstream-required plan_type field.
            if (spec.requiredPaths.contains(planKey) || isPresent(rawPlan)),
               planLabel == nil {
                incomplete = true
            }
        }
        return Mapped(
            planLabel: planLabel,
            windows: windows,
            metrics: metrics,
            incomplete: incomplete,
            recognizedEmpty: recognizedEmpty
        )
    }
}

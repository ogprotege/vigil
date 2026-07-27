import Foundation

public enum RequestBuilder {
    public static let timeoutInterval: TimeInterval = 15

    /// Applies {account_id} substitution and the registry's computed query
    /// params to the spec URL. Returns nil when the URL needs an account id
    /// the credential does not carry — callers surface that as authExpired
    /// (the credential cannot authenticate this request). Mirrors the TS
    /// buildRequestUrl helper; billing periods are UTC.
    public static func requestURL(spec: ProviderSpec, credentials: Credentials, now: Date = Date()) -> URL? {
        var urlString = spec.usageURLTemplate
        if urlString.contains("{account_id}") {
            let accountId = credentials.accountId?.trimmingCharacters(in: .whitespaces) ?? ""
            var pathSegmentAllowed = CharacterSet.urlPathAllowed
            pathSegmentAllowed.remove(charactersIn: "/?#%")
            guard !accountId.isEmpty,
                  let encoded = accountId.addingPercentEncoding(
                    withAllowedCharacters: pathSegmentAllowed
                  )
            else { return nil }
            urlString = urlString.replacingOccurrences(of: "{account_id}", with: encoded)
        }
        guard var components = URLComponents(string: urlString) else { return nil }
        if !spec.query.isEmpty {
            var items = components.queryItems ?? []
            for entry in spec.query {
                items.append(URLQueryItem(name: entry.name, value: resolveQueryParam(entry.param, now: now)))
            }
            components.queryItems = items
        }
        return components.url
    }

    static func resolveQueryParam(_ param: QueryParam, now: Date) -> String {
        switch param {
        case .value(let literal):
            return literal
        case .monthStartUnixSeconds:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: parts) ?? now
            return String(Int(start.timeIntervalSince1970))
        case .currentYear:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return String(calendar.component(.year, from: now))
        case .currentMonth:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return String(calendar.component(.month, from: now))
        }
    }

    /// Builds the usage request exactly per the provider contract; headers
    /// whose placeholder has no value are omitted (e.g. missing account id).
    /// Returns nil when the URL template cannot be satisfied.
    public static func usageRequest(spec: ProviderSpec, credentials: Credentials, now: Date = Date()) -> URLRequest? {
        guard let url = requestURL(spec: spec, credentials: credentials, now: now) else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = spec.usageMethod
        // A cached usage body is not a fresh provider observation. It must not
        // receive a new fetchedAt timestamp, enter history, or trigger alerts.
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        for (name, template) in spec.headers {
            var value = template
            value = value.replacingOccurrences(of: "{access_token}", with: credentials.accessToken)
            value = value.replacingOccurrences(of: "{account_id}", with: credentials.accountId ?? "")
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "Bearer" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

public enum UsageClient {
    public struct Outcome: Equatable, Sendable {
        public let status: SnapshotStatus
        public let planLabel: String?
        public let windows: [UsageWindow]
        public let metrics: [UsageMetric]

        public init(
            status: SnapshotStatus,
            planLabel: String?,
            windows: [UsageWindow],
            metrics: [UsageMetric] = []
        ) {
            self.status = status
            self.planLabel = planLabel
            self.windows = windows
            self.metrics = metrics
        }
    }

    static func mappingIsComplete(_ mapped: UsageMapper.Mapped, spec: ProviderSpec) -> Bool {
        if mapped.incomplete { return false }
        let declaresWindows = !spec.windows.isEmpty || spec.additionalWindows != nil
        let minimumWindows = mapped.recognizedEmpty
            ? 0
            : spec.requiredOutputs?.minimumWindows ?? (declaresWindows ? 1 : 0)
        if mapped.windows.count < minimumWindows { return false }
        if !mapped.recognizedEmpty,
           mapped.windows.filter({ !$0.secondary }).count
            < (spec.requiredOutputs?.minimumPrimaryWindows ?? 0) { return false }
        if mapped.metrics.count < (spec.requiredOutputs?.minimumMetrics ?? 0) { return false }
        let windowIDs = Set(mapped.windows.map(\.id))
        if !mapped.recognizedEmpty,
           spec.requiredOutputs?.windowIDs.contains(where: { !windowIDs.contains($0) }) == true {
            return false
        }
        let metricIDs = Set(mapped.metrics.map(\.id))
        if spec.requiredOutputs?.metricIDs.contains(where: { !metricIDs.contains($0) }) == true {
            return false
        }
        return true
    }

    /// Classifies an HTTP result per the shared error taxonomy:
    /// 401/403 -> authExpired, 429 -> rateLimited, other non-2xx -> network,
    /// unparseable 2xx -> schemaChanged.
    public static func classify(data: Data, statusCode: Int, spec: ProviderSpec) -> Outcome {
        switch statusCode {
        case 401, 403:
            return Outcome(status: .authExpired, planLabel: nil, windows: [])
        case 429:
            return Outcome(status: .rateLimited, planLabel: nil, windows: [])
        case 200...299:
            if let envelopeStatus = UsageMapper.envelopeStatus(spec: spec, body: data) {
                return Outcome(status: envelopeStatus, planLabel: nil, windows: [])
            }
            guard let mapped = UsageMapper.map(spec: spec, body: data) else {
                return Outcome(status: .schemaChanged, planLabel: nil, windows: [])
            }
            // Drift detection: a provider that DECLARES quota windows but maps
            // none of them has changed shape, even though something else
            // (a balance metric) still mapped.
            //
            // This is the hole that let Claude ship broken for weeks. Its
            // `resets_at` gained microsecond precision, the ISO parser returned
            // nil, and every window was discarded — but `extra_usage` has no
            // timestamp, so one metric survived, `map` returned non-nil, and
            // the app reported a confident "Live" next to a single dollar
            // figure. Partial mapping masked total quota failure.
            //
            // Metric-only providers (OpenRouter, DeepSeek, …) declare no
            // windows, so the check does not apply to them.
            if !mappingIsComplete(mapped, spec: spec) {
                // Keep whatever did map — honest degradation, same as any other
                // non-ok status — but never call this "Live".
                return Outcome(
                    status: .schemaChanged,
                    planLabel: mapped.planLabel,
                    windows: mapped.windows,
                    metrics: mapped.metrics
                )
            }
            return Outcome(
                status: .ok,
                planLabel: mapped.planLabel,
                windows: mapped.windows,
                metrics: mapped.metrics
            )
        default:
            return Outcome(status: .network, planLabel: nil, windows: [])
        }
    }
}

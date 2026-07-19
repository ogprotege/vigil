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
            guard !accountId.isEmpty,
                  let encoded = accountId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
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
        var request = URLRequest(url: url)
        request.httpMethod = spec.usageMethod
        request.timeoutInterval = timeoutInterval
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
            guard let mapped = UsageMapper.map(spec: spec, body: data) else {
                return Outcome(status: .schemaChanged, planLabel: nil, windows: [])
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

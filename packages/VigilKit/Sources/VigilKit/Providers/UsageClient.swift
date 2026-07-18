import Foundation

public enum RequestBuilder {
    /// Builds the usage request exactly per the provider contract; headers
    /// whose placeholder has no value are omitted (e.g. missing account id).
    public static func usageRequest(spec: ProviderSpec, credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: spec.usageURL)
        request.httpMethod = spec.usageMethod
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
            return Outcome(status: .ok, planLabel: mapped.planLabel, windows: mapped.windows)
        default:
            return Outcome(status: .network, planLabel: nil, windows: [])
        }
    }
}

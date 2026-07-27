import Foundation
import VigilKit

protocol OpenAIAdminHistoryTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct OpenAIAdminURLSessionTransport: OpenAIAdminHistoryTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIAdminHistoryError.invalidResponse
        }
        return (data, http)
    }
}

/// GET-only access to official completion-token usage and organization costs.
/// This requires a broad API-platform organization Admin API key; regular
/// project keys cannot access these endpoints. It does not read ChatGPT or
/// Codex subscription activity.
struct OpenAIAdminHistoryClient {
    static let maximumRangeDays = 366
    private static let maximumPages = 64

    private let transport: any OpenAIAdminHistoryTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date

    init(
        transport: any OpenAIAdminHistoryTransport = OpenAIAdminURLSessionTransport(),
        baseURL: URL = URL(string: "https://api.openai.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.now = now
    }

    func fetch(
        providerId: String,
        adminAPIKey: String,
        startDate: Date,
        endDate: Date
    ) async throws -> OpenAIAdminHistoryResult {
        guard providerId == "openai" else {
            throw OpenAIAdminHistoryError.unsupportedProvider(providerId)
        }
        guard !adminAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIAdminHistoryError.missingAdminAPIKey
        }
        guard startDate < endDate else {
            throw OpenAIAdminHistoryError.invalidDateRange
        }
        let retrievedAt = now()
        guard endDate <= retrievedAt else {
            throw OpenAIAdminHistoryError.futureEndDate
        }
        let maximumInterval = Double(Self.maximumRangeDays) * 86_400
        guard endDate.timeIntervalSince(startDate) <= maximumInterval else {
            throw OpenAIAdminHistoryError.dateRangeTooLarge(
                maximumDays: Self.maximumRangeDays
            )
        }

        let tokenPoints = try await fetchTokenPages(
            adminAPIKey: adminAPIKey,
            startDate: startDate,
            endDate: endDate,
            retrievedAt: retrievedAt
        )
        let costPoints = try await fetchCostPages(
            adminAPIKey: adminAPIKey,
            startDate: startDate,
            endDate: endDate,
            retrievedAt: retrievedAt
        )
        return OpenAIAdminHistoryResult(
            tokenPoints: tokenPoints,
            costPoints: costPoints,
            retrievedAt: retrievedAt
        )
    }

    private func fetchTokenPages(
        adminAPIKey: String,
        startDate: Date,
        endDate: Date,
        retrievedAt: Date
    ) async throws -> [OpenAIAdminTokenPoint] {
        var cursor: String?
        var seenCursors = Set<String>()
        var points: [OpenAIAdminTokenPoint] = []
        for _ in 0..<Self.maximumPages {
            let page: OpenAIAPIPage<OpenAICompletionResult> = try await loadPage(
                path: "/v1/organization/usage/completions",
                adminAPIKey: adminAPIKey,
                startDate: startDate,
                endDate: endDate,
                limit: 31,
                groupBy: ["model"],
                cursor: cursor
            )
            for bucket in page.data where bucket.overlaps(startDate..<endDate) {
                points.append(contentsOf: bucket.results.map { result in
                    OpenAIAdminTokenPoint(
                        source: .providerBackfill,
                        bucketStart: bucket.startDate,
                        bucketEnd: bucket.endDate,
                        inputTokens: result.inputTokens,
                        outputTokens: result.outputTokens,
                        cachedInputTokens: result.cachedInputTokens,
                        inputAudioTokens: result.inputAudioTokens,
                        outputAudioTokens: result.outputAudioTokens,
                        requestCount: result.requestCount,
                        model: result.model,
                        retrievedAt: retrievedAt
                    )
                })
            }
            guard page.hasMore else { return points }
            cursor = try nextCursor(page.nextPage, seen: &seenCursors)
        }
        throw OpenAIAdminHistoryError.invalidPagination
    }

    private func fetchCostPages(
        adminAPIKey: String,
        startDate: Date,
        endDate: Date,
        retrievedAt: Date
    ) async throws -> [OpenAIAdminCostPoint] {
        var cursor: String?
        var seenCursors = Set<String>()
        var points: [OpenAIAdminCostPoint] = []
        for _ in 0..<Self.maximumPages {
            let page: OpenAIAPIPage<OpenAICostResult> = try await loadPage(
                path: "/v1/organization/costs",
                adminAPIKey: adminAPIKey,
                startDate: startDate,
                endDate: endDate,
                limit: 180,
                groupBy: ["line_item"],
                cursor: cursor
            )
            for bucket in page.data where bucket.overlaps(startDate..<endDate) {
                points.append(contentsOf: bucket.results.compactMap { result in
                    guard let amount = result.amount?.value, amount.isFinite else {
                        return nil
                    }
                    let currency = result.amount?.currency?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedCurrency = currency.flatMap { value in
                        value.isEmpty ? nil : value.uppercased()
                    }
                    return OpenAIAdminCostPoint(
                        source: .providerBackfill,
                        bucketStart: bucket.startDate,
                        bucketEnd: bucket.endDate,
                        amount: amount,
                        currency: normalizedCurrency,
                        lineItem: result.lineItem,
                        retrievedAt: retrievedAt
                    )
                })
            }
            guard page.hasMore else { return points }
            cursor = try nextCursor(page.nextPage, seen: &seenCursors)
        }
        throw OpenAIAdminHistoryError.invalidPagination
    }

    private func loadPage<Result: Decodable>(
        path: String,
        adminAPIKey: String,
        startDate: Date,
        endDate: Date,
        limit: Int,
        groupBy: [String],
        cursor: String?
    ) async throws -> OpenAIAPIPage<Result> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw OpenAIAdminHistoryError.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(startDate.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endDate.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(limit)),
        ] + groupBy.map { URLQueryItem(name: "group_by", value: $0) }
        if let cursor {
            components.queryItems?.append(URLQueryItem(name: "page", value: cursor))
        }
        guard let url = components.url else {
            throw OpenAIAdminHistoryError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(adminAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(OpenAIAPIPage<Result>.self, from: data)
            } catch is DecodingError {
                throw OpenAIAdminHistoryError.invalidResponse
            }
        case 401, 403:
            throw OpenAIAdminHistoryError.administratorAuthenticationRequired(
                statusCode: response.statusCode
            )
        default:
            throw OpenAIAdminHistoryError.httpStatus(response.statusCode)
        }
    }

    private func nextCursor(_ cursor: String?, seen: inout Set<String>) throws -> String {
        guard let cursor, !cursor.isEmpty, seen.insert(cursor).inserted else {
            throw OpenAIAdminHistoryError.invalidPagination
        }
        return cursor
    }
}

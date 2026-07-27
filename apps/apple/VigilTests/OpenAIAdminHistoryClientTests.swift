import Foundation
import XCTest
@testable import Vigil

final class OpenAIAdminHistoryClientTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_730_419_200)
    private let retrievedAt = Date(timeIntervalSince1970: 1_730_678_400)

    func testDefaultTransportCannotReuseCacheOrCookies() {
        let transport = OpenAIAdminURLSessionTransport()
        let configuration = transport.session.configuration

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testPaginatesDailyUsageAndCostsWithTypedProvenance() async throws {
        let transport = OpenAIHistoryStubTransport(responses: [
            .json(Self.usagePageOne),
            .json(Self.usagePageTwo),
            .json(Self.costPage),
        ])
        let client = OpenAIAdminHistoryClient(
            transport: transport,
            now: { self.retrievedAt }
        )

        let result = try await client.fetch(
            providerId: "openai",
            adminAPIKey: "sk-admin-test-secret",
            startDate: start,
            endDate: start.addingTimeInterval(172_800)
        )

        XCTAssertEqual(result.retrievedAt, retrievedAt)
        XCTAssertEqual(result.tokenPoints.count, 2)
        let first = try XCTUnwrap(result.tokenPoints.first)
        XCTAssertEqual(first.source, .providerBackfill)
        XCTAssertEqual(first.bucketStart, start)
        XCTAssertEqual(first.bucketEnd, start.addingTimeInterval(86_400))
        XCTAssertEqual(first.inputTokens, 1_000)
        XCTAssertEqual(first.outputTokens, 500)
        XCTAssertEqual(first.cachedInputTokens, 800)
        XCTAssertEqual(first.inputAudioTokens, 4)
        XCTAssertEqual(first.outputAudioTokens, 2)
        XCTAssertEqual(first.requestCount, 5)
        XCTAssertEqual(first.model, "gpt-5")
        XCTAssertEqual(first.retrievedAt, retrievedAt)
        let cost = try XCTUnwrap(result.costPoints.first)
        XCTAssertEqual(cost.source, .providerBackfill)
        XCTAssertEqual(cost.amount, 0.06, accuracy: 0.000_001)
        XCTAssertEqual(cost.currency, "USD")
        XCTAssertEqual(cost.lineItem, "Responses API")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-test-secret")
        XCTAssertEqual(requests[0].url?.path, "/v1/organization/usage/completions")
        XCTAssertEqual(queryValues("bucket_width", in: requests[0]), ["1d"])
        XCTAssertEqual(queryValues("group_by", in: requests[0]), ["model"])
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(queryValues("page", in: requests[1]), ["usage-page-2"])
        XCTAssertEqual(requests[2].url?.path, "/v1/organization/costs")
        XCTAssertEqual(queryValues("group_by", in: requests[2]), ["line_item"])
    }

    func testDefaultsEachOmittedOptionalCompletionCounterToZero() throws {
        let cases: [(fixture: String, cached: Int64, inputAudio: Int64, outputAudio: Int64)] = [
            (Self.completionWithoutCachedInput, 0, 4, 2),
            (Self.completionWithoutInputAudio, 800, 0, 2),
            (Self.completionWithoutOutputAudio, 800, 4, 0),
        ]

        for value in cases {
            let result = try JSONDecoder().decode(
                OpenAICompletionResult.self,
                from: Data(value.fixture.utf8)
            )
            XCTAssertEqual(result.inputTokens, 1_000)
            XCTAssertEqual(result.outputTokens, 500)
            XCTAssertEqual(result.requestCount, 5)
            XCTAssertEqual(result.cachedInputTokens, value.cached)
            XCTAssertEqual(result.inputAudioTokens, value.inputAudio)
            XCTAssertEqual(result.outputAudioTokens, value.outputAudio)
        }
    }

    func testAcceptsNewTokenBreakdownsWithoutLegacyOptionalAggregates() throws {
        let result = try JSONDecoder().decode(
            OpenAICompletionResult.self,
            from: Data(Self.completionWithNewBreakdownsOnly.utf8)
        )

        XCTAssertEqual(result.inputTokens, 1_000)
        XCTAssertEqual(result.outputTokens, 500)
        XCTAssertEqual(result.requestCount, 5)
        XCTAssertEqual(result.cachedInputTokens, 0)
        XCTAssertEqual(result.inputAudioTokens, 0)
        XCTAssertEqual(result.outputAudioTokens, 0)
        XCTAssertEqual(result.model, "gpt-5")
    }

    func testSkipsCostsWithoutNumericAmountsAndPreservesAmountWithoutCurrency() async throws {
        let transport = OpenAIHistoryStubTransport(responses: [
            .json(Self.emptyUsagePage),
            .json(Self.costPageWithOmittedAmountFields),
        ])
        let client = OpenAIAdminHistoryClient(
            transport: transport,
            now: { self.retrievedAt }
        )

        let result = try await client.fetch(
            providerId: "openai",
            adminAPIKey: "secret",
            startDate: start,
            endDate: start.addingTimeInterval(86_400)
        )

        XCTAssertEqual(result.costPoints.count, 1)
        let cost = try XCTUnwrap(result.costPoints.first)
        XCTAssertEqual(cost.amount, 0.75, accuracy: 0.000_001)
        XCTAssertNil(cost.currency)
        XCTAssertEqual(cost.lineItem, "Amount without currency")
    }

    func testMapsMalformedJSONAndSchemaDecodingFailuresToInvalidResponse() async {
        let malformedCostResponses = [
            "{not-json",
            #"{"data":"not-an-array","has_more":false,"next_page":null}"#,
        ]

        for malformedCostResponse in malformedCostResponses {
            let transport = OpenAIHistoryStubTransport(responses: [
                .json(Self.emptyUsagePage),
                .json(malformedCostResponse),
            ])
            let client = OpenAIAdminHistoryClient(
                transport: transport,
                now: { self.retrievedAt }
            )

            await assertError(.invalidResponse) {
                try await client.fetch(
                    providerId: "openai",
                    adminAPIKey: "secret",
                    startDate: self.start,
                    endDate: self.start.addingTimeInterval(86_400)
                )
            }
        }
    }

    func testRejectsUnsupportedProviderAndInvalidRangesBeforeTransport() async {
        let transport = OpenAIHistoryStubTransport(responses: [])
        let client = OpenAIAdminHistoryClient(
            transport: transport,
            now: { self.retrievedAt }
        )
        await assertError(.unsupportedProvider("codex")) {
            try await client.fetch(
                providerId: "codex",
                adminAPIKey: "secret",
                startDate: self.start,
                endDate: self.start.addingTimeInterval(86_400)
            )
        }
        await assertError(.missingAdminAPIKey) {
            try await client.fetch(
                providerId: "openai",
                adminAPIKey: "  ",
                startDate: self.start,
                endDate: self.start.addingTimeInterval(86_400)
            )
        }
        await assertError(.futureEndDate) {
            try await client.fetch(
                providerId: "openai",
                adminAPIKey: "secret",
                startDate: self.start,
                endDate: self.retrievedAt.addingTimeInterval(1)
            )
        }
        await assertError(.dateRangeTooLarge(maximumDays: 366)) {
            try await client.fetch(
                providerId: "openai",
                adminAPIKey: "secret",
                startDate: self.retrievedAt.addingTimeInterval(-367 * 86_400),
                endDate: self.retrievedAt
            )
        }
        let recordedRequests = await transport.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testMapsNonAdminAuthenticationResponsesWithoutLeakingBody() async {
        for status in [401, 403] {
            let marker = "credential-must-not-escape-\(status)"
            let transport = OpenAIHistoryStubTransport(responses: [
                .init(statusCode: status, data: Data(marker.utf8)),
            ])
            let client = OpenAIAdminHistoryClient(
                transport: transport,
                now: { self.retrievedAt }
            )
            do {
                _ = try await client.fetch(
                    providerId: "openai",
                    adminAPIKey: marker,
                    startDate: start,
                    endDate: start.addingTimeInterval(86_400)
                )
                XCTFail("Expected admin authentication failure")
            } catch let error as OpenAIAdminHistoryError {
                XCTAssertEqual(
                    error,
                    .administratorAuthenticationRequired(statusCode: status)
                )
                XCTAssertFalse(String(describing: error).contains(marker))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsRepeatedPaginationCursor() async {
        let repeated = Self.page(hasMore: true, nextPage: "same", results: [])
        let transport = OpenAIHistoryStubTransport(responses: [
            .json(repeated), .json(repeated),
        ])
        let client = OpenAIAdminHistoryClient(
            transport: transport,
            now: { self.retrievedAt }
        )

        await assertError(.invalidPagination) {
            try await client.fetch(
                providerId: "openai",
                adminAPIKey: "secret",
                startDate: self.start,
                endDate: self.start.addingTimeInterval(86_400)
            )
        }
        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 2)
    }

    private func queryValues(_ name: String, in request: URLRequest) -> [String] {
        guard let url = request.url else { return [] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == name }
            .compactMap(\.value) ?? []
    }

    private func assertError(
        _ expected: OpenAIAdminHistoryError,
        operation: () async throws -> OpenAIAdminHistoryResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as OpenAIAdminHistoryError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static let usagePageOne = """
    {"data":[{"start_time":1730419200,"end_time":1730505600,"results":[{
      "input_tokens":1000,"output_tokens":500,"input_cached_tokens":800,
      "input_audio_tokens":4,"output_audio_tokens":2,"num_model_requests":5,
      "project_id":"proj_abc","user_id":"user_abc","api_key_id":"key_abc",
      "model":"gpt-5","batch":false,"service_tier":"default"
    }]}],"has_more":true,"next_page":"usage-page-2"}
    """

    private static let completionWithoutCachedInput = """
    {
      "input_tokens":1000,"output_tokens":500,
      "input_audio_tokens":4,"output_audio_tokens":2,
      "num_model_requests":5,"model":"gpt-5"
    }
    """

    private static let completionWithoutInputAudio = """
    {
      "input_tokens":1000,"output_tokens":500,"input_cached_tokens":800,
      "output_audio_tokens":2,"num_model_requests":5,"model":"gpt-5"
    }
    """

    private static let completionWithoutOutputAudio = """
    {
      "input_tokens":1000,"output_tokens":500,"input_cached_tokens":800,
      "input_audio_tokens":4,"num_model_requests":5,"model":"gpt-5"
    }
    """

    private static let completionWithNewBreakdownsOnly = """
    {
      "input_tokens":1000,"output_tokens":500,"num_model_requests":5,
      "input_cache_write_tokens":100,"input_cached_audio_tokens":20,
      "input_cached_image_tokens":30,"input_cached_text_tokens":50,
      "input_image_tokens":70,"input_text_tokens":730,
      "input_uncached_tokens":800,"output_image_tokens":40,
      "output_text_tokens":460,"model":"gpt-5"
    }
    """

    private static let usagePageTwo = """
    {"data":[{"start_time":1730505600,"end_time":1730592000,"results":[{
      "input_tokens":200,"output_tokens":100,"input_cached_tokens":50,
      "input_audio_tokens":0,"output_audio_tokens":0,"num_model_requests":2,
      "project_id":null,"user_id":null,"api_key_id":null,
      "model":"gpt-4.1","batch":null,"service_tier":null
    }]}],"has_more":false,"next_page":null}
    """

    private static let emptyUsagePage = """
    {"data":[],"has_more":false,"next_page":null}
    """

    private static let costPage = """
    {"data":[{"start_time":1730419200,"end_time":1730505600,"results":[{
      "amount":{"value":0.06,"currency":"usd"},"line_item":"Responses API",
      "project_id":"proj_abc"
    }]}],"has_more":false,"next_page":null}
    """

    private static let costPageWithOmittedAmountFields = """
    {"data":[{"start_time":1730419200,"end_time":1730505600,"results":[
      {"line_item":"No amount"},
      {"amount":{},"line_item":"No value or currency"},
      {"amount":{"currency":"usd"},"line_item":"Currency without value"},
      {"amount":{"value":0.75},"line_item":"Amount without currency"}
    ]}],"has_more":false,"next_page":null}
    """

    private static func page(
        hasMore: Bool,
        nextPage: String,
        results: [[String: Any]]
    ) -> String {
        let value: [String: Any] = [
            "data": [[
                "start_time": 1_730_419_200,
                "end_time": 1_730_505_600,
                "results": results,
            ]],
            "has_more": hasMore,
            "next_page": nextPage,
        ]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private actor OpenAIHistoryStubTransport: OpenAIAdminHistoryTransport {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data

        static func json(_ value: String, statusCode: Int = 200) -> Response {
            Response(statusCode: statusCode, data: Data(value.utf8))
        }
    }

    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response.data, http)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

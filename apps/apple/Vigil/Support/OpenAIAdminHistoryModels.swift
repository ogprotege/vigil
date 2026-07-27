import Foundation
import VigilKit

enum OpenAIAdminHistoryError: Error, Equatable {
    case unsupportedProvider(String)
    case missingAdminAPIKey
    case invalidDateRange
    case futureEndDate
    case dateRangeTooLarge(maximumDays: Int)
    case administratorAuthenticationRequired(statusCode: Int)
    case httpStatus(Int)
    case invalidResponse
    case invalidPagination
}

struct OpenAIAdminHistoryResult: Equatable, Sendable {
    let tokenPoints: [OpenAIAdminTokenPoint]
    let costPoints: [OpenAIAdminCostPoint]
    let retrievedAt: Date
}

struct OpenAIAdminTokenPoint: Codable, Equatable, Sendable {
    let source: UsageHistorySource
    let bucketStart: Date
    let bucketEnd: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64
    let inputAudioTokens: Int64
    let outputAudioTokens: Int64
    let requestCount: Int64
    let model: String?
    let retrievedAt: Date
}

struct OpenAIAdminCostPoint: Codable, Equatable, Sendable {
    let source: UsageHistorySource
    let bucketStart: Date
    let bucketEnd: Date
    let amount: Double
    let currency: String?
    let lineItem: String?
    let retrievedAt: Date
}

struct OpenAIAPIPage<Result: Decodable>: Decodable {
    let data: [OpenAIAPIBucket<Result>]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAIAPIBucket<Result: Decodable>: Decodable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let results: [Result]
    var startDate: Date { Date(timeIntervalSince1970: startTime) }
    var endDate: Date { Date(timeIntervalSince1970: endTime) }

    func overlaps(_ range: Range<Date>) -> Bool {
        endDate > startDate && endDate > range.lowerBound && startDate < range.upperBound
    }

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICompletionResult: Decodable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64
    let inputAudioTokens: Int64
    let outputAudioTokens: Int64
    let requestCount: Int64
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case requestCount = "num_model_requests"
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int64.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int64.self, forKey: .outputTokens)
        requestCount = try container.decode(Int64.self, forKey: .requestCount)

        // OpenAI documents these additive breakdown counters as optional.
        // An omitted or null breakdown means that the bucket contributes zero
        // to that breakdown, not that the entire usage page is malformed.
        cachedInputTokens = try container.decodeIfPresent(
            Int64.self,
            forKey: .cachedInputTokens
        ) ?? 0
        inputAudioTokens = try container.decodeIfPresent(
            Int64.self,
            forKey: .inputAudioTokens
        ) ?? 0
        outputAudioTokens = try container.decodeIfPresent(
            Int64.self,
            forKey: .outputAudioTokens
        ) ?? 0
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }
}

struct OpenAICostResult: Decodable {
    struct Amount: Decodable {
        let value: Double?
        let currency: String?
    }

    let amount: Amount?
    let lineItem: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case lineItem = "line_item"
    }
}

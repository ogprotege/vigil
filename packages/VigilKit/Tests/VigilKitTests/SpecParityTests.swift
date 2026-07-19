import Foundation
import XCTest
@testable import VigilKit

/// ProviderRegistry hand-mirrors protocol/providers.json for runtime
/// independence; this test keeps the mirror honest. If providers.json changes
/// and the Swift constants don't (or vice versa), CI fails here.
final class SpecParityTests: XCTestCase {
    private struct SpecFile: Decodable {
        let version: Int
        let providers: [String: SpecProvider]
    }

    private struct SpecProvider: Decodable {
        let displayName: String
        let auth: String
        let usage: SpecUsage
        let oauth: SpecOAuth?
        let poll: SpecPoll
        let responseFields: SpecResponseFields?
        let planKey: String?
        let additionalWindows: SpecAdditional?
        let windows: [SpecWindow]
        let metricMappings: [SpecMetric]?
        let metricCollectionMappings: [SpecMetricCollection]?
        let manualEntryHint: String?
    }

    private struct SpecOAuth: Decodable {
        let tokenUrl: String
        let clientId: String
    }

    private struct SpecUsage: Decodable {
        let method: String
        let url: String
        let headers: [String: String]
    }

    private struct SpecPoll: Decodable {
        let minSeconds: Double
        let jitterSeconds: Double
        let backoff429BaseSeconds: Double
        let backoffMaxSeconds: Double
    }

    private struct SpecResponseFields: Decodable {
        let utilization: String
        let resetsAt: String
        let windowSeconds: String?
    }

    private struct SpecAdditional: Decodable {
        let sourceKey: String
        let idKey: String
        let secondary: Bool
    }

    private struct SpecWindow: Decodable {
        let id: String
        let sourceKey: String
        let resetFormat: String
        let windowSeconds: Int?
        let secondary: Bool
    }

    private struct SpecMetric: Decodable {
        let id: String
        let label: String
        let sourceKey: String
        let kind: String
        let unit: String?
        let secondary: Bool
    }

    private struct SpecMetricCollection: Decodable {
        let sourceKey: String
        let idKey: String
        let valueKey: String
        let label: String
        let kind: String
        let unitKey: String?
        let secondary: Bool
    }

    private func assertMatches(_ swift: ProviderSpec, _ json: SpecProvider, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(swift.displayName, json.displayName, file: file, line: line)
        XCTAssertEqual(swift.auth, json.auth, file: file, line: line)
        XCTAssertEqual(swift.usageMethod, json.usage.method, file: file, line: line)
        XCTAssertEqual(swift.usageURL.absoluteString, json.usage.url, file: file, line: line)
        XCTAssertEqual(swift.headers, json.usage.headers, file: file, line: line)
        XCTAssertEqual(swift.poll.minSeconds, json.poll.minSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.jitterSeconds, json.poll.jitterSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.backoff429BaseSeconds, json.poll.backoff429BaseSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.backoffMaxSeconds, json.poll.backoffMaxSeconds, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.utilization, json.responseFields?.utilization, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.resetsAt, json.responseFields?.resetsAt, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.windowSeconds, json.responseFields?.windowSeconds, file: file, line: line)
        XCTAssertEqual(swift.planKey, json.planKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.sourceKey, json.additionalWindows?.sourceKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.idKey, json.additionalWindows?.idKey, file: file, line: line)
        // The Swift mirror carries oauth only for providers whose refresh
        // grant is verified; when present it must match the JSON.
        if let oauth = swift.oauth {
            XCTAssertEqual(oauth.tokenUrl.absoluteString, json.oauth?.tokenUrl, file: file, line: line)
            XCTAssertEqual(oauth.clientId, json.oauth?.clientId, file: file, line: line)
        }
        XCTAssertEqual(swift.windows.count, json.windows.count, file: file, line: line)
        for (got, want) in zip(swift.windows, json.windows) {
            XCTAssertEqual(got.id, want.id, file: file, line: line)
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.resetFormat.rawValue, want.resetFormat, file: file, line: line)
            XCTAssertEqual(got.windowSeconds, want.windowSeconds, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
        }
        let jsonMetrics = json.metricMappings ?? []
        XCTAssertEqual(swift.metricMappings.count, jsonMetrics.count, file: file, line: line)
        for (got, want) in zip(swift.metricMappings, jsonMetrics) {
            XCTAssertEqual(got.id, want.id, file: file, line: line)
            XCTAssertEqual(got.label, want.label, file: file, line: line)
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.kind.rawValue, want.kind, file: file, line: line)
            XCTAssertEqual(got.unit, want.unit, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
        }
        let jsonCollections = json.metricCollectionMappings ?? []
        XCTAssertEqual(swift.metricCollectionMappings.count, jsonCollections.count, file: file, line: line)
        for (got, want) in zip(swift.metricCollectionMappings, jsonCollections) {
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.idKey, want.idKey, file: file, line: line)
            XCTAssertEqual(got.valueKey, want.valueKey, file: file, line: line)
            XCTAssertEqual(got.label, want.label, file: file, line: line)
            XCTAssertEqual(got.kind.rawValue, want.kind, file: file, line: line)
            XCTAssertEqual(got.unitKey, want.unitKey, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
        }
        XCTAssertEqual(swift.manualEntryHint, json.manualEntryHint, file: file, line: line)
    }

    func testRegistryMirrorsProvidersJson() throws {
        let data = try TestSupport.protocolFile("providers.json")
        let file = try JSONDecoder().decode(SpecFile.self, from: data)
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(Set(file.providers.keys), Set(ProviderRegistry.all.map(\.id)))

        for swift in ProviderRegistry.all {
            assertMatches(swift, try XCTUnwrap(file.providers[swift.id]))
        }
    }
}

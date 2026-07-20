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
        let experimental: Bool?
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

    private struct SpecQueryParam: Decodable, Equatable {
        let value: String?
        let compute: String?
    }

    private struct SpecOAuth: Decodable {
        let authorizeUrl: String
        let tokenUrl: String
        let clientId: String
        let scopes: [String]
        let manualRedirectUri: String
        let deviceCodeUrl: String?
        let deviceTokenUrl: String?
    }

    private struct SpecUsage: Decodable {
        let method: String
        let url: String
        let headers: [String: String]
        let query: [String: SpecQueryParam]?
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
        let utilizationKind: String?
        let allowStringNumbers: Bool?
    }

    private struct SpecAdditionalFilter: Decodable {
        let key: String
        let equals: String
    }

    private struct SpecAdditional: Decodable {
        let sourceKey: String
        let idKey: String
        let secondary: Bool
        let filter: SpecAdditionalFilter?
        let resetFormat: String?
        let idPrefix: String?
        let labelKey: String?
        let windowSeconds: Int?
        let fields: SpecWindowFields?
    }

    private struct SpecWindowFields: Decodable {
        let utilization: String
        let resetsAt: String
    }

    private struct SpecWindow: Decodable {
        let id: String
        let sourceKey: String
        let resetFormat: String
        let windowSeconds: Int?
        let secondary: Bool
        let fields: SpecWindowFields?
    }

    private struct SpecMetric: Decodable {
        let id: String
        let label: String
        let sourceKey: String
        let kind: String
        let unit: String?
        let unitKey: String?
        let secondary: Bool
        let aggregate: String?
        let scale: Double?
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
        XCTAssertEqual(swift.experimental, json.experimental ?? false, file: file, line: line)
        XCTAssertEqual(swift.auth, json.auth, file: file, line: line)
        XCTAssertEqual(swift.usageMethod, json.usage.method, file: file, line: line)
        XCTAssertEqual(swift.usageURLTemplate, json.usage.url, file: file, line: line)
        XCTAssertEqual(swift.headers, json.usage.headers, file: file, line: line)

        // Query params: JSON objects are unordered after decoding, so compare
        // as name -> spec maps; both sides must agree on every entry.
        let jsonQuery = json.usage.query ?? [:]
        XCTAssertEqual(swift.query.count, jsonQuery.count, file: file, line: line)
        for entry in swift.query {
            guard let want = jsonQuery[entry.name] else {
                XCTFail("query param \(entry.name) missing from providers.json", file: file, line: line)
                continue
            }
            switch entry.param {
            case .value(let literal):
                XCTAssertEqual(want.value, literal, file: file, line: line)
                XCTAssertNil(want.compute, file: file, line: line)
            case .monthStartUnixSeconds:
                XCTAssertEqual(want.compute, "monthStartUnixSeconds", file: file, line: line)
            case .currentYear:
                XCTAssertEqual(want.compute, "currentYear", file: file, line: line)
            case .currentMonth:
                XCTAssertEqual(want.compute, "currentMonth", file: file, line: line)
            }
        }
        XCTAssertEqual(swift.poll.minSeconds, json.poll.minSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.jitterSeconds, json.poll.jitterSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.backoff429BaseSeconds, json.poll.backoff429BaseSeconds, file: file, line: line)
        XCTAssertEqual(swift.poll.backoffMaxSeconds, json.poll.backoffMaxSeconds, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.utilization, json.responseFields?.utilization, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.resetsAt, json.responseFields?.resetsAt, file: file, line: line)
        XCTAssertEqual(swift.responseFields?.windowSeconds, json.responseFields?.windowSeconds, file: file, line: line)
        if let swiftFields = swift.responseFields {
            XCTAssertEqual(
                swiftFields.utilizationKind.rawValue,
                json.responseFields?.utilizationKind ?? "used",
                file: file, line: line
            )
            XCTAssertEqual(
                swiftFields.allowStringNumbers,
                json.responseFields?.allowStringNumbers ?? false,
                file: file, line: line
            )
        }
        XCTAssertEqual(swift.planKey, json.planKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.sourceKey, json.additionalWindows?.sourceKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.idKey, json.additionalWindows?.idKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.secondary, json.additionalWindows?.secondary, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.filter?.key, json.additionalWindows?.filter?.key, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.filter?.equals, json.additionalWindows?.filter?.equals, file: file, line: line)
        // JSON omits resetFormat to mean the Swift default (unixSeconds).
        XCTAssertEqual(swift.additionalWindows?.resetFormat.rawValue, json.additionalWindows.map { $0.resetFormat ?? "unixSeconds" }, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.idPrefix, json.additionalWindows?.idPrefix, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.labelKey, json.additionalWindows?.labelKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.windowSeconds, json.additionalWindows?.windowSeconds, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.fields?.utilization, json.additionalWindows?.fields?.utilization, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.fields?.resetsAt, json.additionalWindows?.fields?.resetsAt, file: file, line: line)
        // The Swift mirror carries oauth only for providers whose refresh
        // grant is verified; when present it must match the JSON.
        if let oauth = swift.oauth {
            XCTAssertEqual(oauth.authorizeUrl.absoluteString, json.oauth?.authorizeUrl, file: file, line: line)
            XCTAssertEqual(oauth.tokenUrl.absoluteString, json.oauth?.tokenUrl, file: file, line: line)
            XCTAssertEqual(oauth.clientId, json.oauth?.clientId, file: file, line: line)
            XCTAssertEqual(oauth.scopes, json.oauth?.scopes, file: file, line: line)
            XCTAssertEqual(oauth.manualRedirectUri, json.oauth?.manualRedirectUri, file: file, line: line)
            XCTAssertEqual(oauth.deviceCodeUrl?.absoluteString, json.oauth?.deviceCodeUrl, file: file, line: line)
            XCTAssertEqual(oauth.deviceTokenUrl?.absoluteString, json.oauth?.deviceTokenUrl, file: file, line: line)
        }
        XCTAssertEqual(swift.windows.count, json.windows.count, file: file, line: line)
        for (got, want) in zip(swift.windows, json.windows) {
            XCTAssertEqual(got.id, want.id, file: file, line: line)
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.resetFormat.rawValue, want.resetFormat, file: file, line: line)
            XCTAssertEqual(got.windowSeconds, want.windowSeconds, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
            XCTAssertEqual(got.fields?.utilization, want.fields?.utilization, file: file, line: line)
            XCTAssertEqual(got.fields?.resetsAt, want.fields?.resetsAt, file: file, line: line)
        }
        let jsonMetrics = json.metricMappings ?? []
        XCTAssertEqual(swift.metricMappings.count, jsonMetrics.count, file: file, line: line)
        for (got, want) in zip(swift.metricMappings, jsonMetrics) {
            XCTAssertEqual(got.id, want.id, file: file, line: line)
            XCTAssertEqual(got.label, want.label, file: file, line: line)
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.kind.rawValue, want.kind, file: file, line: line)
            XCTAssertEqual(got.unit, want.unit, file: file, line: line)
            XCTAssertEqual(got.unitKey, want.unitKey, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
            XCTAssertEqual(got.aggregate?.rawValue, want.aggregate, file: file, line: line)
            XCTAssertEqual(got.scale, want.scale, file: file, line: line)
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

    /// Absolute-value tripwire, independent of providers.json: spec-parity
    /// alone would let a coordinated registry edit lower the floor on both
    /// sides and still pass CI. "Never poll Claude faster than 5 minutes"
    /// (CLAUDE.md) — changing these literals must be a conscious, reviewed
    /// decision, not a side effect.
    func testPollFloorsAreAbsolute() {
        XCTAssertEqual(ProviderRegistry.claude.poll.minSeconds, 300)
        for spec in ProviderRegistry.all {
            XCTAssertGreaterThanOrEqual(spec.poll.minSeconds, 300, spec.id)
            XCTAssertGreaterThanOrEqual(spec.poll.jitterSeconds, 0, spec.id)
            XCTAssertGreaterThanOrEqual(
                spec.poll.backoff429BaseSeconds, spec.poll.minSeconds, spec.id
            )
            XCTAssertGreaterThanOrEqual(
                spec.poll.backoffMaxSeconds, spec.poll.backoff429BaseSeconds, spec.id
            )
        }
    }
}

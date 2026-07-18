import Foundation
import XCTest
@testable import VigilKit

/// Pins the Swift mapper to the same protocol/fixtures files the CLI is
/// tested against. Any drift between the two implementations fails CI here.
final class FixtureParityTests: XCTestCase {
    private struct ExpectedWindow: Decodable {
        let id: String
        let utilization: Double
        let resetsAt: String?
        let windowSeconds: Int?
        let secondary: Bool
    }

    private struct ExpectedFile: Decodable {
        let planLabel: String?
        let windows: [ExpectedWindow]
    }

    func testEveryFixturePairMapsToItsExpectedOutput() throws {
        let dir = TestSupport.repoRoot.appendingPathComponent("protocol/fixtures")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let expectedNames = files.filter { $0.hasSuffix("-expected.json") }.sorted()
        XCTAssertFalse(expectedNames.isEmpty, "no fixture pairs found — wrong repo root?")

        let iso = ISO8601DateFormatter()
        var providersSeen = Set<String>()

        for expectedName in expectedNames {
            let fixtureName = expectedName.replacingOccurrences(of: "-expected.json", with: ".json")
            let providerId = String(expectedName.split(separator: "-")[0])
            providersSeen.insert(providerId)

            guard let spec = ProviderRegistry.spec(for: providerId) else {
                XCTFail("fixture \(expectedName) references unknown provider \(providerId)")
                continue
            }

            let body = try Data(contentsOf: dir.appendingPathComponent(fixtureName))
            let expectedData = try Data(contentsOf: dir.appendingPathComponent(expectedName))
            let expected = try JSONDecoder().decode(ExpectedFile.self, from: expectedData)

            guard let mapped = UsageMapper.map(spec: spec, body: body) else {
                XCTFail("\(fixtureName) mapped to nil")
                continue
            }

            XCTAssertEqual(mapped.planLabel, expected.planLabel, expectedName)
            XCTAssertEqual(mapped.windows.count, expected.windows.count, expectedName)
            for (got, want) in zip(mapped.windows, expected.windows) {
                XCTAssertEqual(got.id, want.id, expectedName)
                XCTAssertEqual(got.utilization, want.utilization, accuracy: 0.0001, expectedName)
                XCTAssertEqual(got.windowSeconds, want.windowSeconds, expectedName)
                XCTAssertEqual(got.secondary, want.secondary, expectedName)
                if let wantReset = want.resetsAt {
                    XCTAssertEqual(got.resetsAt, iso.date(from: wantReset), "\(expectedName) \(want.id)")
                } else {
                    XCTAssertNil(got.resetsAt, "\(expectedName) \(want.id)")
                }
            }
        }

        XCTAssertEqual(providersSeen, Set(["claude", "codex"]), "every provider needs fixture coverage")
    }

    func testSchemaDriftReturnsNil() {
        let garbage = Data(#"{"totally": "different"}"#.utf8)
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.claude, body: garbage))
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.claude, body: Data("[1,2,3]".utf8)))
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.claude, body: Data("not json".utf8)))
    }

    func testMalformedBucketsAreSkippedButGoodOnesKept() {
        let body = Data(#"""
        {
          "five_hour": { "utilization": "not-a-number", "resets_at": "2026-07-18T21:00:00Z" },
          "seven_day": { "utilization": 12, "resets_at": "2026-07-20T07:00:00Z" }
        }
        """#.utf8)
        let mapped = UsageMapper.map(spec: ProviderRegistry.claude, body: body)
        XCTAssertEqual(mapped?.windows.map(\.id), ["weekly"])
    }

    func testUtilizationClamped() {
        let body = Data(#"{"five_hour": {"utilization": 240, "resets_at": null}}"#.utf8)
        XCTAssertEqual(UsageMapper.map(spec: ProviderRegistry.claude, body: body)?.windows.first?.utilization, 100)
    }

    func testNestedAdditionalRateLimitEntries() {
        let body = Data(#"""
        {
          "rate_limit": { "primary_window": { "used_percent": 10, "reset_at": 1784408400, "limit_window_seconds": 18000 } },
          "additional_rate_limits": [
            "garbage",
            { "name": "nested-lane", "rate_limit": { "used_percent": 7, "reset_at": 1784408400, "limit_window_seconds": 60 } },
            { "name": "flat-lane", "used_percent": 5, "reset_at": 1784408400, "limit_window_seconds": 60 },
            { "name": "no-numbers" }
          ]
        }
        """#.utf8)
        let mapped = UsageMapper.map(spec: ProviderRegistry.codex, body: body)
        XCTAssertEqual(mapped?.windows.map(\.id), ["session", "nested-lane", "flat-lane"])
        XCTAssertEqual(mapped?.windows[1].utilization, 7)
    }

    func testClassifyTaxonomy() {
        let ok = Data(#"{"five_hour": {"utilization": 5, "resets_at": null}}"#.utf8)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 200, spec: ProviderRegistry.claude).status, .ok)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 401, spec: ProviderRegistry.claude).status, .authExpired)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 429, spec: ProviderRegistry.claude).status, .rateLimited)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 502, spec: ProviderRegistry.claude).status, .network)
        XCTAssertEqual(UsageClient.classify(data: Data("<html>".utf8), statusCode: 200, spec: ProviderRegistry.claude).status, .schemaChanged)
    }

    func testRequestBuilderSubstitutesAndOmitsHeaders() {
        let claude = RequestBuilder.usageRequest(
            spec: ProviderRegistry.claude,
            credentials: Credentials(providerId: "claude", accessToken: "sk-ant-oat01-X")
        )
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-X")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNotNil(claude.value(forHTTPHeaderField: "User-Agent"))

        let codexNoAccount = RequestBuilder.usageRequest(
            spec: ProviderRegistry.codex,
            credentials: Credentials(providerId: "codex", accessToken: "tok")
        )
        XCTAssertNil(codexNoAccount.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        XCTAssertEqual(codexNoAccount.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}

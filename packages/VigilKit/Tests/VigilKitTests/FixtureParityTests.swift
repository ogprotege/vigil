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
        let metrics: [ExpectedMetric]?
    }

    private struct ExpectedMetric: Decodable {
        let id: String
        let label: String
        let kind: UsageMetricKind
        let value: Double
        let unit: String?
        let secondary: Bool
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
            let expectedMetrics = expected.metrics ?? []
            XCTAssertEqual(mapped.metrics.count, expectedMetrics.count, expectedName)
            for (got, want) in zip(mapped.metrics, expectedMetrics) {
                XCTAssertEqual(got.id, want.id, expectedName)
                XCTAssertEqual(got.label, want.label, expectedName)
                XCTAssertEqual(got.kind, want.kind, expectedName)
                XCTAssertEqual(got.value, want.value, accuracy: 0.0001, expectedName)
                XCTAssertEqual(got.unit, want.unit, expectedName)
                XCTAssertEqual(got.secondary, want.secondary, expectedName)
            }
        }

        XCTAssertEqual(
            providersSeen,
            Set(ProviderRegistry.all.map(\.id)),
            "every provider needs fixture coverage"
        )
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

    func testScalarMetricsAcceptDecimalStringsButWindowsStayStrict() {
        let body = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "USD", "total_balance": "12.50" },
            { "currency": "CNY", "total_balance": "not-a-number" }
          ]
        }
        """#.utf8)
        let mapped = UsageMapper.map(spec: ProviderRegistry.deepSeek, body: body)
        XCTAssertEqual(mapped?.windows, [])
        XCTAssertEqual(mapped?.metrics.count, 1)
        XCTAssertEqual(mapped?.metrics.first?.id, "balance_usd")
        XCTAssertEqual(mapped?.metrics.first?.value, 12.5)
    }

    func testDuplicateProviderIDsKeepFirstPrimaryValue() {
        let windows = Data(#"""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1784408400,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": [
            { "name": "session", "used_percent": 99, "reset_at": 1784408400 },
            { "name": "lane", "used_percent": 5, "reset_at": 1784408400 },
            { "name": "lane", "used_percent": 90, "reset_at": 1784408400 }
          ]
        }
        """#.utf8)
        let mappedWindows = UsageMapper.map(spec: ProviderRegistry.codex, body: windows)
        XCTAssertEqual(mappedWindows?.windows.map(\.id), ["session", "lane"])
        XCTAssertEqual(mappedWindows?.windows.map(\.utilization), [10, 5])

        let metrics = Data(#"""
        {
          "balance_infos": [
            { "currency": "USD", "total_balance": "10" },
            { "currency": "usd", "total_balance": "999" }
          ]
        }
        """#.utf8)
        let mappedMetrics = UsageMapper.map(spec: ProviderRegistry.deepSeek, body: metrics)
        XCTAssertEqual(mappedMetrics?.metrics.count, 1)
        XCTAssertEqual(mappedMetrics?.metrics.first?.value, 10)
    }

    func testOversizedProviderNumbersCannotTrapMapper() {
        let invalidReset = Data(#"""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1e300,
              "limit_window_seconds": 1e300
            }
          }
        }
        """#.utf8)
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.codex, body: invalidReset))

        let invalidDuration = Data(#"""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1784408400,
              "limit_window_seconds": 1e300
            }
          }
        }
        """#.utf8)
        XCTAssertNil(
            UsageMapper.map(spec: ProviderRegistry.codex, body: invalidDuration)?
                .windows.first?.windowSeconds
        )
    }

    func testOversizedOrControlBearingProviderLabelsAreDropped() {
        let windows = Data(#"""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1784408400 }
          },
          "additional_rate_limits": [
            { "name": "bad\u001b[2J", "used_percent": 99, "reset_at": 1784408400 },
            { "name": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "used_percent": 99, "reset_at": 1784408400 }
          ]
        }
        """#.utf8)
        XCTAssertEqual(
            UsageMapper.map(spec: ProviderRegistry.codex, body: windows)?.windows.map(\.id),
            ["session"]
        )

        let metrics = Data(#"""
        {
          "balance_infos": [
            { "currency": "USD\n", "total_balance": "10" }
          ]
        }
        """#.utf8)
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.deepSeek, body: metrics))
    }

    func testClassifyTaxonomy() throws {
        let ok = Data(#"{"five_hour": {"utilization": 5, "resets_at": null}}"#.utf8)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 200, spec: ProviderRegistry.claude).status, .ok)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 401, spec: ProviderRegistry.claude).status, .authExpired)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 429, spec: ProviderRegistry.claude).status, .rateLimited)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 502, spec: ProviderRegistry.claude).status, .network)
        XCTAssertEqual(UsageClient.classify(data: Data("<html>".utf8), statusCode: 200, spec: ProviderRegistry.claude).status, .schemaChanged)

        // The real Anthropic 429 error body (protocol/fixtures/claude-429.json,
        // the one fixture without an -expected pair — the CLI consumes it in
        // status/http tests; this is its Swift-side twin).
        let errorBody = try Data(
            contentsOf: TestSupport.repoRoot.appendingPathComponent("protocol/fixtures/claude-429.json")
        )
        XCTAssertEqual(
            UsageClient.classify(data: errorBody, statusCode: 429, spec: ProviderRegistry.claude).status,
            .rateLimited
        )
        // The same error body on a 200 must read as schemaChanged, not crash
        // or produce a phantom window.
        XCTAssertEqual(
            UsageClient.classify(data: errorBody, statusCode: 200, spec: ProviderRegistry.claude).status,
            .schemaChanged
        )
    }

    func testRequestBuilderSubstitutesAndOmitsHeaders() {
        let claude = RequestBuilder.usageRequest(
            spec: ProviderRegistry.claude,
            credentials: Credentials(providerId: "claude", accessToken: "sk-ant-oat01-X")
        )
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-X")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNotNil(claude.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(claude.timeoutInterval, RequestBuilder.timeoutInterval)

        let codexNoAccount = RequestBuilder.usageRequest(
            spec: ProviderRegistry.codex,
            credentials: Credentials(providerId: "codex", accessToken: "tok")
        )
        XCTAssertNil(codexNoAccount.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        XCTAssertEqual(codexNoAccount.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}

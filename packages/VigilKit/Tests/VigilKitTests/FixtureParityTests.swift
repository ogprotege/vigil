import Foundation
import XCTest
@testable import VigilKit

/// Pins the shipped Swift mapper to the committed protocol/fixtures response
/// and expected-output pairs. Any implementation drift fails CI here.
final class FixtureParityTests: XCTestCase {
    private struct ExpectedWindow: Decodable {
        let id: String
        let label: String?
        let utilization: Double
        let resetsAt: String?
        let windowSeconds: Int?
        let secondary: Bool
    }

    private struct ExpectedFile: Decodable {
        let planLabel: String?
        let incomplete: Bool?
        let recognizedEmpty: Bool?
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
            if let incomplete = expected.incomplete {
                XCTAssertEqual(mapped.incomplete, incomplete, expectedName)
            }
            if let recognizedEmpty = expected.recognizedEmpty {
                XCTAssertEqual(mapped.recognizedEmpty, recognizedEmpty, expectedName)
            }
            XCTAssertEqual(mapped.windows.count, expected.windows.count, expectedName)
            for (got, want) in zip(mapped.windows, expected.windows) {
                XCTAssertEqual(got.id, want.id, expectedName)
                XCTAssertEqual(got.label, want.label, expectedName)
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
        XCTAssertEqual(mapped?.incomplete, true)

        let wrongContainer = Data(#"{"five_hour":"changed-wrapper","seven_day":{"utilization":12,"resets_at":"2026-07-20T07:00:00Z"}}"#.utf8)
        let mappedWrongContainer = UsageMapper.map(spec: ProviderRegistry.claude, body: wrongContainer)
        XCTAssertEqual(mappedWrongContainer?.windows.map(\.id), ["weekly"])
        XCTAssertEqual(mappedWrongContainer?.incomplete, true)
    }

    func testImpossibleDirectPercentagesAndOverLimitRatioPolicy() throws {
        for utilization in [-40, 240] {
            let body = try JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": utilization, "resets_at": NSNull()],
                "seven_day": ["utilization": 12, "resets_at": NSNull()],
            ])
            let mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.claude, body: body))
            XCTAssertEqual(mapped.windows.map(\.id), ["weekly"])
            XCTAssertTrue(mapped.incomplete)
        }

        var body = try JSONSerialization.data(withJSONObject: [
            "billingCycleEnd": "2026-05-11T00:00:00.000Z",
            "individualUsage": [
                "plan": ["used": -1, "limit": 100],
                "overall": ["used": 1, "limit": 2],
            ],
        ])
        var mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.cursor, body: body))
        XCTAssertEqual(mapped.windows.first?.utilization, 50)
        XCTAssertTrue(mapped.incomplete)

        body = try JSONSerialization.data(withJSONObject: [
            "billingCycleEnd": "2026-05-11T00:00:00.000Z",
            "individualUsage": ["plan": ["used": 120, "limit": 100]],
        ])
        mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.cursor, body: body))
        XCTAssertEqual(mapped.windows.first?.utilization, 100)
        XCTAssertFalse(mapped.incomplete)
    }

    func testMissingResetIsDriftButExplicitNullIsValid() {
        let body = Data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":12,"resets_at":null}}"#.utf8)
        let mapped = UsageMapper.map(spec: ProviderRegistry.claude, body: body)
        XCTAssertEqual(mapped?.windows.map(\.id), ["weekly"])
        XCTAssertNil(mapped?.windows.first?.resetsAt)
        XCTAssertEqual(mapped?.incomplete, true)
    }

    func testNestedAdditionalRateLimitEntriesFanOut() throws {
        let body = Data(#"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1784408400, "limit_window_seconds": 18000 },
            "secondary_window": null
          },
          "additional_rate_limits": [
            {
              "limit_name": "Nested lane",
              "metered_feature": "nested_lane",
              "rate_limit": {
                "primary_window": { "used_percent": 7, "reset_at": 1784408400, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 9, "reset_at": 1784530800, "limit_window_seconds": 604800 }
              }
            }
          ]
        }
        """#.utf8)
        let mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.codex, body: body))
        XCTAssertEqual(mapped.windows.map(\.id), ["session", "nested_lane_session", "nested_lane_weekly"])
        XCTAssertEqual(mapped.windows[1].utilization, 7)
        XCTAssertEqual(mapped.windows[2].utilization, 9)
        XCTAssertEqual(mapped.windows[1].label, "Nested lane · 5 hours")
        XCTAssertEqual(mapped.windows[2].label, "Nested lane · Weekly")
        XCTAssertFalse(mapped.incomplete)
    }

    func testEligibleDynamicLaneWithoutIdentifierIsIncomplete() throws {
        let body = Data(#"""
        {
          "rate_limit": { "primary_window": { "used_percent": 10, "reset_at": 1784408400, "limit_window_seconds": 18000 } },
          "additional_rate_limits": [
            {
              "limit_name": "Unidentified lane",
              "rate_limit": {
                "primary_window": { "used_percent": 7, "reset_at": 1784408400, "limit_window_seconds": 18000 }
              }
            }
          ]
        }
        """#.utf8)
        let mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.codex, body: body))
        XCTAssertEqual(mapped.windows.map(\.id), ["session"])
        XCTAssertTrue(mapped.incomplete)
    }

    func testUnknownDynamicDurationIdentityIsIncomplete() throws {
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1784408400,"limit_window_seconds":18000}},"additional_rate_limits":[{"limit_name":"Unknown duration","metered_feature":"unknown_duration","rate_limit":{"primary_window":{"used_percent":7,"reset_at":1784408400,"limit_window_seconds":86400}}}]}"#.utf8)
        let mapped = try XCTUnwrap(UsageMapper.map(spec: ProviderRegistry.codex, body: body))
        XCTAssertEqual(mapped.windows.map(\.id), ["session"])
        XCTAssertTrue(mapped.incomplete)
    }

    func testUnknownDynamicLabelDurationIsIncomplete() throws {
        let spec = ProviderSpec(
            id: "label-duration",
            displayName: "Label duration",
            usageMethod: "GET",
            usageURL: "https://example.invalid/usage",
            headers: [:],
            poll: PollPolicy(minSeconds: 300, jitterSeconds: 0, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
            responseFields: ResponseFields(utilization: "used_percent", resetsAt: "reset_at", windowSeconds: "limit_window_seconds"),
            planKey: nil,
            additionalWindows: AdditionalWindows(
                sourceKey: "additional_rate_limits",
                idKey: "metered_feature",
                secondary: true,
                labelKey: "limit_name",
                requiredWhenPresent: true,
                entryWindows: [
                    AdditionalEntryWindow(
                        sourceKey: "rate_limit.primary_window",
                        idSuffix: "primary",
                        labelSuffixByWindowSeconds: [18_000: "5 hours"]
                    ),
                ]
            ),
            windows: [
                WindowMapping(
                    id: "session",
                    sourceKey: "rate_limit.primary_window",
                    resetFormat: .unixSeconds,
                    windowSeconds: nil,
                    secondary: false,
                    idByWindowSeconds: [18_000: "session"]
                ),
            ]
        )
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1784408400,"limit_window_seconds":18000}},"additional_rate_limits":[{"limit_name":"Unknown label duration","metered_feature":"unknown_label_duration","rate_limit":{"primary_window":{"used_percent":7,"reset_at":1784408400,"limit_window_seconds":86400}}}]}"#.utf8)
        let mapped = try XCTUnwrap(UsageMapper.map(spec: spec, body: body))
        XCTAssertEqual(mapped.windows.map(\.id), ["session"])
        XCTAssertTrue(mapped.incomplete)
    }

    func testDynamicFilterUsesJSONScalarStringParity() throws {
        let spec = ProviderSpec(
            id: "numeric-filter",
            displayName: "Numeric filter",
            usageMethod: "GET",
            usageURL: "https://example.invalid/usage",
            headers: [:],
            poll: PollPolicy(minSeconds: 300, jitterSeconds: 0, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
            responseFields: ResponseFields(utilization: "utilization", resetsAt: "resets_at", windowSeconds: nil),
            planKey: nil,
            additionalWindows: AdditionalWindows(
                sourceKey: "limits",
                idKey: "name",
                secondary: true,
                filter: AdditionalWindowFilter(key: "kind", equals: "7"),
                resetFormat: .iso8601,
                idPrefix: "dynamic",
                windowSeconds: 604_800,
                fields: WindowFieldOverride(utilization: "percent", resetsAt: "resets_at")
            ),
            windows: []
        )
        let body = #"{"limits":[{"kind":7,"name":"Numeric filter","percent":25,"resets_at":"2026-07-27T07:00:00Z"}]}"#
        let mapped = try XCTUnwrap(UsageMapper.map(spec: spec, body: Data(body.utf8)))
        XCTAssertEqual(mapped.windows.map(\.id), ["dynamic_numeric_filter"])
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
            { "limit_name": "Lane", "metered_feature": "lane", "rate_limit": { "primary_window": { "used_percent": 5, "reset_at": 1784408400, "limit_window_seconds": 18000 } } },
            { "limit_name": "Lane", "metered_feature": "lane", "rate_limit": { "primary_window": { "used_percent": 90, "reset_at": 1784408400, "limit_window_seconds": 18000 } } }
          ]
        }
        """#.utf8)
        let mappedWindows = UsageMapper.map(spec: ProviderRegistry.codex, body: windows)
        XCTAssertEqual(mappedWindows?.windows.map(\.id), ["session", "lane_session"])
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
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.codex, body: invalidDuration))
    }

    func testOversizedOrControlBearingProviderLabelsAreDropped() {
        let windows = Data(#"""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1784408400, "limit_window_seconds": 18000 }
          },
          "additional_rate_limits": [
            { "limit_name": "Bad", "metered_feature": "bad\u001b[2J", "rate_limit": {} },
            { "limit_name": "Long", "metered_feature": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "rate_limit": {} }
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
        let ok = Data(#"{"five_hour":{"utilization":5,"resets_at":null},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}"#.utf8)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 200, spec: ProviderRegistry.claude).status, .ok)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 401, spec: ProviderRegistry.claude).status, .authExpired)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 429, spec: ProviderRegistry.claude).status, .rateLimited)
        XCTAssertEqual(UsageClient.classify(data: ok, statusCode: 502, spec: ProviderRegistry.claude).status, .network)
        XCTAssertEqual(UsageClient.classify(data: Data("<html>".utf8), statusCode: 200, spec: ProviderRegistry.claude).status, .schemaChanged)

        // The real Anthropic 429 error body (protocol/fixtures/claude-429.json)
        // is the one input-only fixture because HTTP classification, rather
        // than response mapping, is the behavior under test.
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

        let miniMaxAuth = Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#.utf8)
        XCTAssertEqual(
            UsageClient.classify(data: miniMaxAuth, statusCode: 200, spec: ProviderRegistry.miniMax).status,
            .authExpired
        )
        let zAIAuth = Data(#"{"code":1001,"success":false,"msg":"authentication required"}"#.utf8)
        XCTAssertEqual(
            UsageClient.classify(data: zAIAuth, statusCode: 200, spec: ProviderRegistry.zAI).status,
            .authExpired
        )
    }

    func testRequestBuilderSubstitutesAndOmitsHeaders() throws {
        let claude = try XCTUnwrap(RequestBuilder.usageRequest(
            spec: ProviderRegistry.claude,
            credentials: Credentials(providerId: "claude", accessToken: "sk-ant-oat01-X")
        ))
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-X")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNotNil(claude.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(claude.timeoutInterval, RequestBuilder.timeoutInterval)

        let codexNoAccount = try XCTUnwrap(RequestBuilder.usageRequest(
            spec: ProviderRegistry.codex,
            credentials: Credentials(providerId: "codex", accessToken: "tok")
        ))
        XCTAssertNil(codexNoAccount.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        XCTAssertEqual(codexNoAccount.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testRequestBuilderTemplatesURLsAndComputedQueryParams() throws {
        // A URL that needs {account_id} refuses to build without one.
        XCTAssertNil(RequestBuilder.usageRequest(
            spec: ProviderRegistry.gitHub,
            credentials: Credentials(providerId: "github", accessToken: "tok")
        ))

        // 2026-07-19T00:00:00Z; month start is 2026-07-01T00:00:00Z.
        let now = Date(timeIntervalSince1970: 1_784_419_200)
        let github = try XCTUnwrap(RequestBuilder.usageRequest(
            spec: ProviderRegistry.gitHub,
            credentials: Credentials(providerId: "github", accessToken: "tok", accountId: "octo cat"),
            now: now
        ))
        let githubURL = try XCTUnwrap(github.url?.absoluteString)
        XCTAssertTrue(githubURL.contains("/users/octo%20cat/settings/billing/ai_credit/usage"), githubURL)
        XCTAssertTrue(githubURL.contains("year=2026"), githubURL)
        XCTAssertTrue(githubURL.contains("month=7"), githubURL)

        let openai = try XCTUnwrap(RequestBuilder.usageRequest(
            spec: ProviderRegistry.openAI,
            credentials: Credentials(providerId: "openai", accessToken: "admin"),
            now: now
        ))
        let openaiURL = try XCTUnwrap(openai.url?.absoluteString)
        XCTAssertTrue(openaiURL.contains("start_time=1782864000"), "month start must be 2026-07-01T00:00:00Z — \(openaiURL)")
        XCTAssertTrue(openaiURL.contains("bucket_width=1d"), openaiURL)
    }
}

/// Cases whose correct outcome is `nil` (schemaChanged) and therefore cannot be
/// expressed as a fixture pair, plus reset formats the committed fixtures do
/// not cover. These directly pin inputs that cannot use expected-output files.
final class MapperDivergenceTests: XCTestCase {
    /// A provider renaming the aggregated leaf must read as a shape change, not
    /// as a real $0.00. Dropping absent leaves made the "leaves exist but none
    /// parsed" branch unreachable, so a rename reported a confident zero.
    func testAbsentAggregateLeafIsSchemaChangedNotZero() {
        let github = #"{"usageItems":[{"date":"2026-07-02","product":"copilot"},{"date":"x"}]}"#
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.gitHub, body: Data(github.utf8)))

        let openAI = #"{"data":[{"results":[{"amount":{"currency":"usd"}}]}]}"#
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.openAI, body: Data(openAI.utf8)))
    }

    /// "Root present but empty" that legitimately sums to 0 means an empty
    /// ARRAY. An error envelope or a pagination wrapper is a shape change.
    func testNonArrayAggregateRootIsSchemaChangedNotZero() {
        for body in [#"{"usageItems":{"message":"not found"}}"#, #"{"usageItems":"nope"}"#] {
            XCTAssertNil(
                UsageMapper.map(spec: ProviderRegistry.gitHub, body: Data(body.utf8)),
                body
            )
        }
        for body in [#"{"data":{"error":"x"}}"#, #"{"data":true}"#] {
            XCTAssertNil(
                UsageMapper.map(spec: ProviderRegistry.openAI, body: Data(body.utf8)),
                body
            )
        }
    }

    /// An empty array really is a zero-spend month and must still map.
    func testEmptyAggregateArrayStillReportsZero() throws {
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.gitHub, body: Data(#"{"usageItems":[]}"#.utf8))
        )
        XCTAssertEqual(mapped.metrics.first(where: { $0.id == "spend_month" })?.value, 0)
    }

    /// TS parses ISO-8601 with `new Date(...)`, which accepts fractional
    /// seconds. A single ISO8601DateFormatter cannot parse both forms, so a
    /// cosmetic serializer change upstream used to drop every Claude window.
    func testFractionalSecondResetsParse() throws {
        let body = #"{"five_hour":{"utilization":50,"resets_at":"2026-07-18T21:00:00.500Z"}}"#
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.claude, body: Data(body.utf8))
        )
        XCTAssertEqual(mapped.windows.first?.id, "session")
        XCTAssertEqual(mapped.windows.first?.utilization, 50)
        XCTAssertNotNil(mapped.windows.first?.resetsAt)
    }

    /// Whole seconds must keep working after adding the fractional parser.
    func testWholeSecondResetsStillParse() throws {
        let body = #"{"five_hour":{"utilization":25,"resets_at":"2026-07-18T21:00:00Z"}}"#
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.claude, body: Data(body.utf8))
        )
        XCTAssertNotNil(mapped.windows.first?.resetsAt)
    }

    /// Cc and Cf are both rejected, matching the TS sanitizer.
    func testFormatCharactersAreRejectedInProviderText() {
        let zeroWidth = "{\"balance_infos\":[{\"currency\":\"US\u{200D}D\",\"total_balance\":\"5\"}]}"
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.deepSeek, body: Data(zeroWidth.utf8)))
    }

    func testKimiZeroLimitCannotProduceNaNUtilization() {
        let body = #"{"usage":{"limit":"0","used":"0","resetTime":null},"limits":[]}"#
        XCTAssertNil(UsageMapper.map(spec: ProviderRegistry.kimiCode, body: Data(body.utf8)))
    }

    func testCursorTeamFallbackUsesTopLevelBillingReset() throws {
        let body = #"{"membershipType":"enterprise","billingCycleEnd":"2026-08-11T00:00:00.500Z","individualUsage":{"overall":{"used":71,"limit":10000}},"teamUsage":{"pooled":{"used":50,"limit":200}}}"#
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.cursor, body: Data(body.utf8))
        )
        XCTAssertEqual(mapped.windows.first?.id, "plan")
        XCTAssertEqual(mapped.windows.first?.utilization ?? -1, 0.71, accuracy: 0.0001)
        XCTAssertEqual(mapped.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_786_406_400))
    }

    func testMiniMaxMissingStatusAllowedButStatusThreeSuppressed() throws {
        let body = #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":80,"end_time":1784408400000,"current_weekly_remaining_percent":70,"weekly_end_time":1784530800000},{"model_name":"video","current_interval_remaining_percent":100,"end_time":1784408400000,"current_interval_status":3,"current_weekly_remaining_percent":100,"weekly_end_time":1784530800000,"current_weekly_status":3}],"base_resp":{"status_code":0}}"#
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.miniMax, body: Data(body.utf8))
        )
        XCTAssertEqual(mapped.windows.map(\.id), ["session", "weekly"])
    }

    func testMiniMaxContinuesPastSuppressedArrayCandidate() throws {
        let body = #"{"model_remains":[{"model_name":"general","current_interval_status":3,"current_interval_remaining_percent":100,"end_time":1784408400000},{"model_name":"general","current_interval_status":1,"current_interval_remaining_percent":80,"end_time":1784408400000}],"base_resp":{"status_code":0}}"#
        let mapped = try XCTUnwrap(
            UsageMapper.map(spec: ProviderRegistry.miniMax, body: Data(body.utf8))
        )
        XCTAssertEqual(mapped.windows.map(\.id), ["session"])
        XCTAssertEqual(mapped.windows.first?.utilization, 20)
    }
}

/// Drift detection: a provider that declares quota windows but maps none of
/// them from a 200 has changed shape, even if a metric still mapped.
///
/// This is the hole that let Claude ship broken. Its `resets_at` gained
/// microsecond precision, the ISO parser returned nil, every window was
/// discarded — but `extra_usage` has no timestamp, so one metric survived,
/// `map` returned non-nil, and the app reported "Live" beside a lone dollar
/// figure. Partial mapping masked total quota failure.
final class WindowDriftDetectionTests: XCTestCase {
    func testMalformedStaticBucketMakesPartialResponseSchemaChanged() {
        let body = #"{"five_hour":{"utilization":"wrong","resets_at":"wrong"},"seven_day":{"utilization":12,"resets_at":"2026-07-20T07:00:00Z"},"seven_day_sonnet":null,"seven_day_opus":null}"#
        let outcome = UsageClient.classify(
            data: Data(body.utf8),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["weekly"])
    }

    /// The exact Claude regression: metrics map, every window fails.
    func testWindowProviderWithZeroMappedWindowsIsSchemaChanged() {
        // `extra_usage` maps; every window bucket is unparseable garbage.
        let body = #"""
        {
          "five_hour": { "utilization": "nonsense", "resets_at": "not-a-date" },
          "seven_day": { "utilization": "nonsense", "resets_at": "not-a-date" },
          "seven_day_sonnet": null,
          "seven_day_opus": null,
          "extra_usage": { "is_enabled": true, "used_credits": 7.5, "monthly_limit": 50, "currency": "USD" }
        }
        """#
        let outcome = UsageClient.classify(
            data: Data(body.utf8),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(
            outcome.status, .schemaChanged,
            "zero windows from a window-declaring provider must not read as Live"
        )
        XCTAssertFalse(
            outcome.metrics.isEmpty,
            "what did map is still surfaced — honest degradation, not data loss"
        )
    }

    /// A healthy response is unaffected.
    func testWindowProviderWithMappedWindowsStaysOK() {
        let body = #"""
        {
          "five_hour": { "utilization": 12, "resets_at": "2026-07-22T02:09:59.392525+00:00" },
          "seven_day": null,
          "seven_day_sonnet": null,
          "seven_day_opus": null,
          "extra_usage": { "is_enabled": true, "used_credits": 0, "monthly_limit": 50, "currency": "USD" }
        }
        """#
        let outcome = UsageClient.classify(
            data: Data(body.utf8),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.count, 1)
    }

    func testMalformedDynamicLaneMakesPartialCodexResponseSchemaChanged() {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1784408400,"limit_window_seconds":18000}},"additional_rate_limits":[{"limit_name":"Changed lane","metered_feature":"changed_lane","rate_limit":{"primary_window":{"another_percent":5}}}]}"#
        let outcome = UsageClient.classify(
            data: Data(body.utf8),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])
    }

    func testPresentWrongShapedAndGarbageOnlyCodexCollectionsAreSchemaChanged() {
        let primary = #""rate_limit":{"primary_window":{"used_percent":10,"reset_at":1784408400,"limit_window_seconds":18000}}"#
        let bodies = [
            "{\(primary),\"additional_rate_limits\":\"changed-wrapper\"}",
            "{\(primary),\"additional_rate_limits\":[null,\"garbage\",7]}",
        ]

        for body in bodies {
            let outcome = UsageClient.classify(
                data: Data(body.utf8),
                statusCode: 200,
                spec: ProviderRegistry.codex
            )
            XCTAssertEqual(outcome.status, .schemaChanged)
            XCTAssertEqual(outcome.windows.map(\.id), ["session"])
        }
    }

    func testClaudeFilteredCollectionWithNoEligibleEntryStaysOK() {
        let body = #"""
        {
          "five_hour": { "utilization": 10, "resets_at": null },
          "seven_day": null,
          "seven_day_sonnet": null,
          "seven_day_opus": null,
          "limits": [
            { "kind": "monthly_overage", "is_active": true },
            { "kind": "weekly_scoped", "is_active": false }
          ]
        }
        """#
        let outcome = UsageClient.classify(
            data: Data(body.utf8),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])
    }

    func testMiniMaxAllUnlimitedIsRecognizedEmptyButUnknownEmptyIsDrift() throws {
        let unlimited = try Data(
            contentsOf: TestSupport.repoRoot.appendingPathComponent(
                "protocol/fixtures/minimax-usage-unlimited.json"
            )
        )
        let valid = UsageClient.classify(
            data: unlimited,
            statusCode: 200,
            spec: ProviderRegistry.miniMax
        )
        XCTAssertEqual(valid.status, .ok)
        XCTAssertEqual(valid.windows, [])

        let unknown = Data(#"{"model_remains":[],"base_resp":{"status_code":0}}"#.utf8)
        XCTAssertEqual(
            UsageClient.classify(
                data: unknown,
                statusCode: 200,
                spec: ProviderRegistry.miniMax
            ).status,
            .schemaChanged
        )
    }

    func testInvalidCanonicalMoneyExponentCannotRemainLive() throws {
        let body = try Data(
            contentsOf: TestSupport.repoRoot.appendingPathComponent(
                "protocol/fixtures/claude-usage-invalid-canonical-exponent.json"
            )
        )
        let outcome = UsageClient.classify(
            data: body,
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "extra_used" }))
    }

    /// Metric-only providers declare no windows, so drift detection must never
    /// fire for them — OpenRouter reporting only a balance is correct.
    func testMetricOnlyProviderIsUnaffected() throws {
        let body = try TestSupport.protocolFile("fixtures/openrouter-usage-ok.json")
        let outcome = UsageClient.classify(
            data: body,
            statusCode: 200,
            spec: ProviderRegistry.openRouter
        )
        XCTAssertEqual(outcome.status, .ok, "a metric-only provider has no windows by design")
        XCTAssertFalse(outcome.metrics.isEmpty)
    }

    func testMissingRequiredZAIWindowAndOpenRouterPeriodsAreSchemaChanged() {
        let zAI = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 17,
                "nextResetTime": 1782724971179
              }
            ]
          }
        }
        """#.utf8)
        let zAIOutcome = UsageClient.classify(
            data: zAI,
            statusCode: 200,
            spec: ProviderRegistry.zAI
        )
        XCTAssertEqual(zAIOutcome.status, .schemaChanged)
        XCTAssertEqual(zAIOutcome.windows.map(\.id), ["session"])

        let openRouter = Data(#"{"data":{"usage":3.75,"usage_monthly":3.5}}"#.utf8)
        let openRouterOutcome = UsageClient.classify(
            data: openRouter,
            statusCode: 200,
            spec: ProviderRegistry.openRouter
        )
        XCTAssertEqual(openRouterOutcome.status, .schemaChanged)
        XCTAssertEqual(
            openRouterOutcome.metrics.map(\.id),
            ["usage_lifetime", "usage_monthly"]
        )
    }
}

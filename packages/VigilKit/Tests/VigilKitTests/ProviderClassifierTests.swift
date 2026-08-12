import Foundation
import XCTest
@testable import VigilKit

final class ProviderClassifierTests: XCTestCase {
    private let canonicalBodies: [(providerID: String, fixture: String)] = [
        ("claude", "claude-usage-spend-canonical.json"),
        ("codex", "codex-usage-live-spend-control.json"),
        ("openrouter", "openrouter-usage-ok.json"),
        ("deepseek", "deepseek-balance-ok.json"),
        ("moonshot", "moonshot-balance-ok.json"),
        ("moonshot_cn", "moonshot_cn-balance-debt.json"),
        ("minimax", "minimax-usage-ok.json"),
        ("minimax_cn", "minimax_cn-usage-exhausted.json"),
        ("openai", "openai-costs-ok.json"),
        ("github", "github-billing-ok.json"),
        ("xai", "xai-balance-ok.json"),
        ("grok", "grok-usage-weekly.json"),
        ("zai", "zai-quota-ok.json"),
        ("cursor", "cursor-usage-ok.json"),
        ("kimi_code", "kimi_code-usage-ok.json"),
    ]

    func testCanonicalHTTP200FixtureForEveryProviderIsOK() throws {
        XCTAssertEqual(
            Set(canonicalBodies.map(\.providerID)),
            Set(ProviderRegistry.all.map(\.id)),
            "the classifier table must cover every registered provider"
        )

        for testCase in canonicalBodies {
            let spec = try XCTUnwrap(
                ProviderRegistry.all.first(where: { $0.id == testCase.providerID }),
                testCase.providerID
            )
            let body = try TestSupport.protocolFile("fixtures/\(testCase.fixture)")
            let outcome = UsageClient.classify(data: body, statusCode: 200, spec: spec)
            XCTAssertEqual(outcome.status, .ok, testCase.providerID)
            XCTAssertGreaterThan(outcome.windows.count + outcome.metrics.count, 0, testCase.providerID)
        }
    }

    func testGrokUsesWeeklyCreditsAndRejectsRetiredZeroMonthlyLimit() throws {
        let weekly = try TestSupport.protocolFile("fixtures/grok-usage-weekly.json")
        var outcome = UsageClient.classify(
            data: weekly,
            statusCode: 200,
            spec: ProviderRegistry.grok
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.map(\.id), ["weekly"])
        XCTAssertEqual(outcome.windows.first?.label, "Weekly credits")

        let retiredMonthly = try TestSupport.protocolFile(
            "fixtures/grok-usage-retired-monthly.json"
        )
        outcome = UsageClient.classify(
            data: retiredMonthly,
            statusCode: 200,
            spec: ProviderRegistry.grok
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "the retired zero monthly limit cannot produce a trustworthy usage window"
        )
        XCTAssertTrue(outcome.windows.isEmpty)

        let legacyMonthly = try TestSupport.protocolFile("fixtures/grok-usage-ok.json")
        outcome = UsageClient.classify(
            data: legacyMonthly,
            statusCode: 200,
            spec: ProviderRegistry.grok
        )
        XCTAssertEqual(outcome.status, .ok, "nonzero legacy monthly responses remain compatible")
        XCTAssertEqual(outcome.windows.map(\.id), ["monthly"])
    }

    func testCodexCurrentSpendControlAndOptionalWindowContractIsAccepted() throws {
        let liveBody = try TestSupport.protocolFile(
            "fixtures/codex-usage-live-spend-control.json"
        )
        var outcome = UsageClient.classify(
            data: liveBody,
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.map(\.id), ["session", "codex_sanitized_session"])

        let decodedLiveRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: liveBody) as? [String: Any]
        )
        var optionalRoot = decodedLiveRoot
        optionalRoot.removeValue(forKey: "spend_control")
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: optionalRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .ok, "OpenAI models spend_control as optional")

        optionalRoot["spend_control"] = NSNull()
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: optionalRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .ok, "OpenAI models spend_control as nullable")

        var guardedRoot = decodedLiveRoot
        guardedRoot["spend_control"] = [
            "reached": true,
            "individual_limit": NSNull(),
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: guardedRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "A reached spend control must not be hidden behind otherwise valid windows"
        )

        guardedRoot["spend_control"] = [:]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: guardedRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "A present spend control must declare its reached state"
        )

        guardedRoot["spend_control"] = [
            "reached": "false",
            "individual_limit": NSNull(),
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: guardedRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "The spend-control reached state must remain a Boolean"
        )

        guardedRoot["spend_control"] = [
            "reached": false,
            "individual_limit": ["used_percent": 50],
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: guardedRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "An unmodeled individual monthly limit must not be reported as Live"
        )

        guardedRoot = decodedLiveRoot
        guardedRoot["rate_limit_reached_type"] = ["type": "rate_limit_reached"]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: guardedRoot),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "An unmodeled provider limit reason must not be reported as Live"
        )

        var root = decodedLiveRoot
        var rateLimit = try XCTUnwrap(root["rate_limit"] as? [String: Any])
        rateLimit.removeValue(forKey: "secondary_window")
        root["rate_limit"] = rateLimit
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: root),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .ok, "OpenAI models secondary_window as optional")

        rateLimit["primary_window"] = NSNull()
        rateLimit["secondary_window"] = [
            "used_percent": 31,
            "reset_at": 1_785_697_200,
            "limit_window_seconds": 604_800,
        ]
        root["rate_limit"] = rateLimit
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: root),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .ok, "OpenAI models primary_window as nullable")
        XCTAssertEqual(outcome.windows.first?.id, "weekly")

        rateLimit["secondary_window"] = NSNull()
        root["rate_limit"] = rateLimit
        root["additional_rate_limits"] = []
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: root),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(
            outcome.status,
            .schemaChanged,
            "A valid plan without any usable top-level window must still fail closed"
        )
    }

    func testOpenAIPaginationAndUnsafeAggregateSubsetsFailClosed() throws {
        let canonicalData = try TestSupport.protocolFile("fixtures/openai-costs-ok.json")
        var canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        canonical["has_more"] = true
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: canonical),
            statusCode: 200,
            spec: ProviderRegistry.openAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.metrics.first(where: { $0.id == "spend_month" })?.value, 15)

        canonical.removeValue(forKey: "has_more")
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: canonical),
            statusCode: 200,
            spec: ProviderRegistry.openAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        let nonnumeric: [String: Any] = [
            "object": "page",
            "has_more": false,
            "data": [[
                "results": [
                    ["amount": ["value": 10]],
                    ["amount": ["value": "changed"]],
                ],
            ]],
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: nonnumeric),
            statusCode: 200,
            spec: ProviderRegistry.openAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "spend_month" }))

        let result: [String: Any] = ["amount": ["value": 1]]
        let nestedTruncation: [String: Any] = [
            "object": "page",
            "has_more": false,
            "data": [["results": Array(repeating: result, count: 129)]],
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: nestedTruncation),
            statusCode: 200,
            spec: ProviderRegistry.openAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "spend_month" }))

        let bucket: [String: Any] = ["results": [["amount": ["value": 1]]]]
        let truncated: [String: Any] = [
            "object": "page",
            "has_more": false,
            "data": Array(repeating: bucket, count: 129),
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: truncated),
            statusCode: 200,
            spec: ProviderRegistry.openAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "spend_month" }))
    }

    func testPartialMoneyFamiliesAndMalformedCurrencyFailClosed() throws {
        let routerData = try TestSupport.protocolFile("fixtures/openrouter-usage-ok.json")
        var router = try XCTUnwrap(
            JSONSerialization.jsonObject(with: routerData) as? [String: Any]
        )
        var routerPayload = try XCTUnwrap(router["data"] as? [String: Any])
        routerPayload.removeValue(forKey: "limit_remaining")
        router["data"] = routerPayload
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: router),
            statusCode: 200,
            spec: ProviderRegistry.openRouter
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "limit" }))
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "remaining" }))

        let claudeData = try TestSupport.protocolFile("fixtures/claude-usage-spend-canonical.json")
        var claude = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claudeData) as? [String: Any]
        )
        var spend = try XCTUnwrap(claude["spend"] as? [String: Any])
        var used = try XCTUnwrap(spend["used"] as? [String: Any])
        used["currency"] = "USD\u{001B}"
        spend["used"] = used
        claude["spend"] = spend
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: claude),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "extra_used" }))
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "extra_limit" }))
    }

    func testProviderRequiredFamiliesCannotDisappearBehindAValidSubset() throws {
        var body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/openrouter-usage-ok.json")
            ) as? [String: Any]
        )
        var data = try XCTUnwrap(body["data"] as? [String: Any])
        data.removeValue(forKey: "byok_usage_monthly")
        data.removeValue(forKey: "limit_reset")
        body["data"] = data
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.openRouter
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/codex-usage-ok.json")
            ) as? [String: Any]
        )
        body.removeValue(forKey: "plan_type")
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/moonshot-balance-ok.json")
            ) as? [String: Any]
        )
        data = try XCTUnwrap(body["data"] as? [String: Any])
        data.removeValue(forKey: "cash_balance")
        body["data"] = data
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.moonshot
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/moonshot-balance-ok.json")
            ) as? [String: Any]
        )
        body["scode"] = "changed"
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.moonshot
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/zai-quota-ok.json")
            ) as? [String: Any]
        )
        data = try XCTUnwrap(body["data"] as? [String: Any])
        var limits = try XCTUnwrap(data["limits"] as? [[String: Any]])
        let timeIndex = try XCTUnwrap(limits.firstIndex(where: { $0["type"] as? String == "TIME_LIMIT" }))
        limits[timeIndex].removeValue(forKey: "currentValue")
        limits[timeIndex].removeValue(forKey: "usage")
        limits[timeIndex].removeValue(forKey: "remaining")
        data["limits"] = limits
        body["data"] = data
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.zAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session", "weekly"])

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/cursor-usage-ok.json")
            ) as? [String: Any]
        )
        var individual = try XCTUnwrap(body["individualUsage"] as? [String: Any])
        individual["onDemand"] = ["enabled": true, "limit": 10_000]
        body["individualUsage"] = individual
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        individual["onDemand"] = ["enabled": false]
        body["individualUsage"] = individual
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .ok)

        individual["onDemand"] = ["used": 500, "limit": 1_000]
        body["individualUsage"] = individual
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TestSupport.protocolFile("fixtures/claude-usage-spend-canonical.json")
            ) as? [String: Any]
        )
        var spend = try XCTUnwrap(body["spend"] as? [String: Any])
        spend["enabled"] = false
        body["spend"] = spend
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.metrics, [])

        for malformed: Any? in [nil, "true", 1] {
            body = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: TestSupport.protocolFile("fixtures/claude-usage-spend-canonical.json")
                ) as? [String: Any]
            )
            spend = try XCTUnwrap(body["spend"] as? [String: Any])
            if let malformed { spend["enabled"] = malformed }
            else { spend.removeValue(forKey: "enabled") }
            body["spend"] = spend
            outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: body),
                statusCode: 200,
                spec: ProviderRegistry.claude
            )
            XCTAssertEqual(outcome.status, .schemaChanged)
        }
    }

    func testOptionalMiniMaxStatusEnumsAreValidatedWhenPresent() throws {
        let cases: [(ProviderSpec, String, Bool)] = [
            (ProviderRegistry.miniMax, "minimax-usage-ok.json", false),
            (ProviderRegistry.miniMaxCN, "minimax_cn-usage-exhausted.json", true),
        ]
        for (spec, fixtureName, wrapped) in cases {
            var body = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: TestSupport.protocolFile("fixtures/\(fixtureName)")
                ) as? [String: Any]
            )
            var payload = wrapped
                ? try XCTUnwrap(body["data"] as? [String: Any])
                : body
            var entries = try XCTUnwrap(payload["model_remains"] as? [[String: Any]])
            for index in entries.indices {
                entries[index].removeValue(forKey: "current_interval_status")
                entries[index].removeValue(forKey: "current_weekly_status")
            }
            payload["model_remains"] = entries
            if wrapped { body["data"] = payload } else { body = payload }
            var outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: body),
                statusCode: 200,
                spec: spec
            )
            XCTAssertEqual(outcome.status, .ok)

            for field in ["current_interval_status", "current_weekly_status"] {
                for malformed: Any in ["3", true, [String: Any](), 1.5, 4] {
                    body = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: TestSupport.protocolFile("fixtures/\(fixtureName)")
                        ) as? [String: Any]
                    )
                    payload = wrapped
                        ? try XCTUnwrap(body["data"] as? [String: Any])
                        : body
                    entries = try XCTUnwrap(payload["model_remains"] as? [[String: Any]])
                    entries[0][field] = malformed
                    payload["model_remains"] = entries
                    if wrapped { body["data"] = payload } else { body = payload }
                    outcome = UsageClient.classify(
                        data: try JSONSerialization.data(withJSONObject: body),
                        statusCode: 200,
                        spec: spec
                    )
                    XCTAssertEqual(outcome.status, .schemaChanged, "\(spec.id) \(field)")
                }
            }
        }
    }

    func testMalformedPresentOptionalScalarMetricFailsClosed() throws {
        let fixture = try TestSupport.protocolFile("fixtures/openrouter-usage-ok.json")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var data = try XCTUnwrap(body["data"] as? [String: Any])
        data["byok_usage_daily"] = "changed"
        body["data"] = data
        let outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.openRouter
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertNil(outcome.metrics.first(where: { $0.id == "byok_usage_daily" }))
        XCTAssertNotNil(outcome.metrics.first(where: { $0.id == "usage_monthly" }))
    }

    func testLiteralAndEscapedEquivalentDuplicateJSONKeysFailClosed() {
        let bodies = [
            Data(#"{"five_hour":{"utilization":10,"utilization":20,"resets_at":"2026-07-22T17:00:00Z"},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}"#.utf8),
            Data(#"{"five_hour":{"utilization":10,"\u0075tilization":20,"resets_at":"2026-07-22T17:00:00Z"},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}"#.utf8),
        ]

        for body in bodies {
            XCTAssertEqual(
                UsageClient.classify(
                    data: body,
                    statusCode: 200,
                    spec: ProviderRegistry.claude
                ).status,
                .schemaChanged
            )
        }
    }

    func testNonUTF8ProviderBodiesFailClosed() throws {
        let valid = #"{"five_hour":{"utilization":10,"resets_at":"2026-07-22T17:00:00Z"},"seven_day":null,"seven_day_sonnet":null,"seven_day_opus":null}"#
        let bodies = [
            try XCTUnwrap(valid.data(using: .utf16LittleEndian)),
            Data([0x7b, 0x22, 0x78, 0x22, 0x3a, 0xc3, 0x28, 0x7d]),
        ]

        for body in bodies {
            XCTAssertEqual(
                UsageClient.classify(
                    data: body,
                    statusCode: 200,
                    spec: ProviderRegistry.claude
                ).status,
                .schemaChanged
            )
        }
    }

    func testProviderControlledFanOutOver128EntriesFailsClosed() throws {
        let primary: [String: Any] = [
            "used_percent": 1,
            "reset_at": 1_784_408_400,
            "limit_window_seconds": 18_000,
        ]
        let lanes: [[String: Any]] = (0..<129).map { index in
            [
                "limit_name": "Lane \(index)",
                "metered_feature": "lane_\(index)",
                "rate_limit": ["primary_window": primary],
            ]
        }
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": primary],
                "additional_rate_limits": lanes,
            ]),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        let balances: [[String: Any]] = (0..<129).map { index in
            ["currency": "U\(index)", "total_balance": "1"]
        }
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: ["balance_infos": balances]),
            statusCode: 200,
            spec: ProviderRegistry.deepSeek
        )
        XCTAssertEqual(outcome.status, .schemaChanged)

        let session: [String: Any] = [
            "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
            "percentage": 1, "nextResetTime": 1_782_724_971_179,
        ]
        let weekly: [String: Any] = [
            "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
            "percentage": 2, "nextResetTime": 1_782_724_971_179,
        ]
        let limits = [session, weekly] + Array(repeating: session, count: 127)
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "code": 200,
                "success": true,
                "data": ["limits": limits],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.zAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
    }

    func testPresentStaticWindowWithWrongContainerFailsClosed() {
        let body = Data(#"{"five_hour":"changed-wrapper","seven_day":{"utilization":12,"resets_at":"2026-07-20T07:00:00Z"}}"#.utf8)
        let outcome = UsageClient.classify(
            data: body,
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["weekly"])
    }

    func testInternetDateTimeResetsRejectLanguageSpecificDateGuesses() {
        for reset in [
            "0",
            "1582-10-10T00:00:00Z",
            "2100-01-01T00:00:00Z",
            "2026-01-01T24:00:00.1Z",
            "2026-01-01T00:00:00.1234567890Z",
            "2026-01-01T00:00:00+14:01",
            "2026-07-22T17:00:00+24:00",
        ] {
            let body: [String: Any] = [
                "five_hour": ["utilization": 12, "resets_at": reset],
                "seven_day": ["utilization": 34, "resets_at": "2026-07-27T17:00:00Z"],
            ]
            let outcome = UsageClient.classify(
                data: try! JSONSerialization.data(withJSONObject: body),
                statusCode: 200,
                spec: ProviderRegistry.claude
            )
            XCTAssertEqual(outcome.status, .schemaChanged)
            XCTAssertEqual(outcome.windows.map(\.id), ["weekly"])
        }
    }

    func testOnlyDecimalStringNumbersMapForMetricsAndLenientWindows() throws {
        for encoded in ["0b10", "0o10", "0x10", "\u{FEFF}1", "\u{00A0}1", "1\u{00A0}"] {
            var outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: [
                    "balance_infos": [["currency": "USD", "total_balance": encoded]],
                ]),
                statusCode: 200,
                spec: ProviderRegistry.deepSeek
            )
            XCTAssertEqual(outcome.status, .schemaChanged, encoded)
            XCTAssertEqual(outcome.metrics, [], encoded)

            let fixture = try TestSupport.protocolFile("fixtures/kimi_code-usage-ok.json")
            var kimi = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
            var limits = try XCTUnwrap(kimi["limits"] as? [[String: Any]])
            var detail = try XCTUnwrap(limits[0]["detail"] as? [String: Any])
            detail["used"] = encoded
            limits[0]["detail"] = detail
            kimi["limits"] = limits
            outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: kimi),
                statusCode: 200,
                spec: ProviderRegistry.kimiCode
            )
            XCTAssertEqual(outcome.status, .schemaChanged, encoded)
            let expectedWindows = encoded.hasPrefix("\u{FEFF}") ? [] : ["weekly"]
            XCTAssertEqual(outcome.windows.map(\.id), expectedWindows, encoded)
        }
    }

    func testCodexLaneWithUnknownDurationIdentityFailsClosed() {
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1784408400,"limit_window_seconds":18000}},"additional_rate_limits":[{"limit_name":"Unknown duration","metered_feature":"unknown_duration","rate_limit":{"primary_window":{"used_percent":7,"reset_at":1784408400,"limit_window_seconds":86400}}}]}"#.utf8)
        let outcome = UsageClient.classify(
            data: body,
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])
    }

    func testDuplicateStaticIdentitiesAndMixedDynamicGarbageFailClosed() throws {
        let primary: [String: Any] = [
            "used_percent": 10,
            "reset_at": 1_784_408_400,
            "limit_window_seconds": 18_000,
        ]
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "rate_limit": [
                    "primary_window": primary,
                    "secondary_window": primary,
                ],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])

        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": primary],
                "additional_rate_limits": [
                    [
                        "limit_name": "Valid model",
                        "metered_feature": "valid_model",
                        "rate_limit": ["primary_window": primary],
                    ],
                    "changed-entry",
                ],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session", "valid_model_session"])
    }

    func testBlankAndCollidingDynamicWindowIdentifiersFailClosed() throws {
        let primary: [String: Any] = [
            "used_percent": 10,
            "reset_at": 1_784_408_400,
            "limit_window_seconds": 18_000,
        ]
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": primary],
                "additional_rate_limits": [[
                    "limit_name": "Blank",
                    "metered_feature": "   ",
                    "rate_limit": ["primary_window": primary],
                ]],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])

        let duplicate: [String: Any] = [
            "limit_name": "Duplicate",
            "metered_feature": "duplicate",
            "rate_limit": ["primary_window": primary],
        ]
        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": primary],
                "additional_rate_limits": [duplicate, duplicate],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.codex
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session", "duplicate_session"])
    }

    func testDynamicModelLabelsAndPrefixedIdentifiersFailClosed() throws {
        let primary: [String: Any] = [
            "used_percent": 10,
            "reset_at": 1_784_408_400,
            "limit_window_seconds": 18_000,
        ]
        for label: Any? in [nil, "   "] {
            var lane: [String: Any] = [
                "metered_feature": "model_without_label",
                "rate_limit": ["primary_window": primary],
            ]
            if let label { lane["limit_name"] = label }
            let outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: [
                    "rate_limit": ["primary_window": primary],
                    "additional_rate_limits": [lane],
                ]),
                statusCode: 200,
                spec: ProviderRegistry.codex
            )
            XCTAssertEqual(outcome.status, .schemaChanged)
            XCTAssertEqual(outcome.windows.map(\.id), ["session"])
        }

        let collapsed: [String: Any] = [
            "five_hour": [
                "utilization": 10,
                "resets_at": "2026-07-22T17:00:00Z",
            ],
            "limits": [[
                "kind": "weekly_scoped",
                "is_active": true,
                "percent": 20,
                "resets_at": "2026-07-27T17:00:00Z",
                "scope": ["model": ["display_name": "---"]],
            ]],
        ]
        let outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: collapsed),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session"])

        let missingCondition: [String: Any] = [
            "five_hour": [
                "utilization": 10,
                "resets_at": "2026-07-22T17:00:00Z",
            ],
            "limits": [[
                "kind": "weekly_scoped",
                "percent": 20,
                "resets_at": "2026-07-27T17:00:00Z",
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ]
        let conditionOutcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: missingCondition),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(conditionOutcome.status, .schemaChanged)
        XCTAssertEqual(conditionOutcome.windows.map(\.id), ["session"])

        let missingFilter: [String: Any] = [
            "five_hour": [
                "utilization": 10,
                "resets_at": "2026-07-22T17:00:00Z",
            ],
            "limits": [[
                "is_active": true,
                "percent": 20,
                "resets_at": "2026-07-27T17:00:00Z",
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ]
        let filterOutcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: missingFilter),
            statusCode: 200,
            spec: ProviderRegistry.claude
        )
        XCTAssertEqual(filterOutcome.status, .schemaChanged)
        XCTAssertEqual(filterOutcome.windows.map(\.id), ["session"])
    }

    func testUnicodeDynamicIDsNormalizeLikeTypeScript() throws {
        for (displayName, expectedID) in [
            ("A😀B", "weekly_scoped_a_b"),
            ("K", "weekly_scoped_k"),
            ("İ", "weekly_scoped_i_"),
        ] {
            let body: [String: Any] = [
                "five_hour": [
                    "utilization": 10,
                    "resets_at": "2026-07-22T17:00:00Z",
                ],
                "seven_day": NSNull(),
                "seven_day_sonnet": NSNull(),
                "seven_day_opus": NSNull(),
                "limits": [[
                    "kind": "weekly_scoped",
                    "is_active": true,
                    "percent": 20,
                    "resets_at": "2026-07-27T17:00:00Z",
                    "scope": ["model": ["display_name": displayName]],
                ]],
            ]
            let outcome = UsageClient.classify(
                data: try JSONSerialization.data(withJSONObject: body),
                statusCode: 200,
                spec: ProviderRegistry.claude
            )
            XCTAssertEqual(outcome.status, .ok)
            XCTAssertEqual(outcome.windows.map(\.id), ["session", expectedID])
        }
    }

    func testCursorFallbackCandidatesAndUnlimitedSpendOnlyRemainHealthy() throws {
        var outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "billingCycleEnd": "2026-05-11T00:00:00.000Z",
                "membershipType": "pro",
                "individualUsage": ["plan": ["used": 25, "limit": 100]],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.map(\.id), ["plan"])
        XCTAssertEqual(outcome.windows.first?.utilization, 25)

        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "billingCycleEnd": "2026-05-11T00:00:00.000Z",
                "individualUsage": [
                    "plan": ["totalPercentUsed": "changed", "used": 25, "limit": 100],
                ],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.first?.utilization, 25)

        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "billingCycleEnd": "2026-05-11T00:00:00.000Z",
                "individualUsage": [
                    "plan": ["totalPercentUsed": 10, "used": "stale", "limit": 100],
                ],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.windows.first?.utilization, 10)

        outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: [
                "billingCycleEnd": "2026-05-11T00:00:00.000Z",
                "membershipType": "pro",
                "individualUsage": [
                    "plan": ["totalPercentUsed": 10],
                    "onDemand": ["enabled": true, "used": 500, "limit": 0],
                ],
                "teamUsage": [:],
            ]),
            statusCode: 200,
            spec: ProviderRegistry.cursor
        )
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.metrics.map { [$0.id, String($0.value)] }, [["spend_ondemand", "5.0"]])
    }

    func testMalformedAndCollidingMetricCollectionEntriesFailClosed() throws {
        let body: [String: Any] = [
            "balance_infos": [
                ["currency": "USD", "total_balance": "10"],
                "garbage",
                ["currency": "EUR"],
                ["currency": "US-D", "total_balance": "1"],
                ["currency": "US_D", "total_balance": "2"],
            ],
        ]
        let outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.deepSeek
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.metrics.map(\.id), ["balance_usd", "balance_us_d"])
        XCTAssertEqual(outcome.metrics.map(\.value), [10, 1])
    }

    func testMixedValidAndMalformedStaticArrayEntriesFailClosed() throws {
        let body: [String: Any] = [
            "code": 200,
            "success": true,
            "data": [
                "limits": [
                    [
                        "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                        "percentage": 1, "nextResetTime": 1_782_724_971_179,
                    ],
                    [
                        "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
                        "percentage": 2, "nextResetTime": 1_782_724_971_179,
                    ],
                    "changed-entry",
                ],
            ],
        ]
        let outcome = UsageClient.classify(
            data: try JSONSerialization.data(withJSONObject: body),
            statusCode: 200,
            spec: ProviderRegistry.zAI
        )
        XCTAssertEqual(outcome.status, .schemaChanged)
        XCTAssertEqual(outcome.windows.map(\.id), ["session", "weekly"])
    }
}

import Foundation
import XCTest
import VigilKit
@testable import Vigil

final class DiagnosticExportTests: XCTestCase {
    private let exportedAt = Date(timeIntervalSince1970: 1_753_488_000)
    private let accountKey = "openai:credential-fingerprint-DO-NOT-EXPORT"

    func testExportAliasesEveryFreeFormFieldByConstruction() throws {
        let builder = DiagnosticExportBuilder(now: { self.exportedAt })
        let data = try builder.makeData(
            app: .init(
                name: "github_pat_app-metadata-secret",
                version: "opaque-version-secret",
                build: "opaque-build-secret"
            ),
            accounts: [account],
            currentSnapshots: [snapshot],
            history: [historySample]
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        for forbidden in [
            accountKey,
            "label-secret",
            "cookie-secret",
            "sk-ant-abcdefghijk123456",
            "history-secret",
            "quantity-secret",
            "custom-secret-with-no-known-prefix",
            "proj_abc",
            "key_abc",
            "user_abc",
            "accessToken",
            "refreshToken",
            "authorizationHeader",
            "rawProviderBody",
            "keychain",
            "github_pat_provider-controlled-secret",
            "opaque-cursor-session-secret",
            "opaque-unit-secret",
            "opaque-version-secret",
            "opaque-build-secret",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        let snapshots = try XCTUnwrap(root["currentSnapshots"] as? [[String: Any]])
        let history = try XCTUnwrap(root["history"] as? [[String: Any]])
        XCTAssertEqual(accounts.first?["accountId"] as? String, "account-001")
        XCTAssertEqual(snapshots.first?["accountId"] as? String, "account-001")
        XCTAssertEqual(history.first?["accountId"] as? String, "account-001")
        XCTAssertNil(accounts.first?["accountKey"])
        XCTAssertNil(accounts.first?["label"])
        XCTAssertNil(accounts.first?["plan"])
        XCTAssertNil(snapshots.first?["accountLabel"])
        XCTAssertNil(snapshots.first?["planLabel"])
        let exportedWindows = try XCTUnwrap(snapshots.first?["windows"] as? [[String: Any]])
        XCTAssertEqual(exportedWindows.first?["id"] as? String, "window-001")
        XCTAssertNil(exportedWindows.first?["label"])
        let exportedMetrics = try XCTUnwrap(snapshots.first?["metrics"] as? [[String: Any]])
        XCTAssertEqual(exportedMetrics.first?["id"] as? String, "metric-001")
        XCTAssertNil(exportedMetrics.first?["label"])
        XCTAssertNil(exportedMetrics.first?["unit"])
        XCTAssertEqual(history.first?["source"] as? String, "providerBackfill")
        XCTAssertEqual(history.first?["id"] as? String, "history-000001")
        let privacy = try XCTUnwrap(root["privacy"] as? [String: Any])
        XCTAssertEqual(privacy["credentialsIncluded"] as? Bool, false)
        XCTAssertEqual(privacy["rawProviderDataIncluded"] as? Bool, false)
        let historyScope = try XCTUnwrap(root["historyScope"] as? [String: Any])
        XCTAssertEqual(
            historyScope["selection"] as? String,
            "bounded-recent-per-account-and-source"
        )
        XCTAssertEqual(historyScope["exportedSampleCount"] as? Int, 1)
        XCTAssertEqual(historyScope["retainedSampleCount"] as? Int, 1)
    }

    func testExportDeclaresWhenHistoryIsOnlyABoundedRecentSubset() throws {
        let data = try DiagnosticExportBuilder(now: { self.exportedAt }).makeData(
            app: .init(name: "Vigil", version: "0.15.0", build: "16"),
            accounts: [account],
            currentSnapshots: [snapshot],
            history: [historySample],
            retainedHistoryCount: 412
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let scope = try XCTUnwrap(root["historyScope"] as? [String: Any])

        XCTAssertEqual(scope["retainedSampleCount"] as? Int, 412)
        XCTAssertEqual(scope["exportedSampleCount"] as? Int, 1)
        XCTAssertEqual(
            scope["selection"] as? String,
            "bounded-recent-per-account-and-source"
        )
    }

    func testWriteCreatesProtectedShareableJSONInSuppliedTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let builder = DiagnosticExportBuilder(
            directory: directory,
            now: { self.exportedAt },
            identifier: { id }
        )

        let url = try builder.write(
            app: .init(name: "Vigil", version: "1.0", build: "20"),
            accounts: [account],
            currentSnapshots: [snapshot],
            history: [historySample]
        )

        XCTAssertEqual(
            url.lastPathComponent,
            "Vigil-Diagnostics-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
        )
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let app = try XCTUnwrap(root["app"] as? [String: Any])
        XCTAssertEqual(app["version"] as? String, "1.0")
        XCTAssertNotNil(root["exportedAt"])
    }

    private var account: AccountRef {
        AccountRef(
            key: accountKey,
            providerId: "openai",
            label: "custom-secret-with-no-known-prefix",
            plan: "Cookie: session=cookie-secret"
        )
    }

    private var snapshot: ProviderSnapshot {
        ProviderSnapshot(
            providerId: "openai",
            accountKey: accountKey,
            accountLabel: "API sk-ant-abcdefghijk123456 proj_abc key_abc user_abc",
            planLabel: "Organization",
            fetchedAt: exportedAt.addingTimeInterval(-60),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "github_pat_provider-controlled-secret",
                    utilization: 25,
                    resetsAt: exportedAt.addingTimeInterval(3_600),
                    windowSeconds: 86_400,
                    secondary: false,
                    label: "opaque-cursor-session-secret",
                    used: 25,
                    limit: 100
                ),
            ],
            metrics: [
                UsageMetric(
                    id: "opaque-cursor-session-secret",
                    label: "github_pat_provider-controlled-secret",
                    kind: .spend,
                    value: 1.25,
                    unit: "opaque-unit-secret",
                    secondary: false
                ),
            ]
        )
    }

    private var historySample: UsageHistorySample {
        UsageHistorySample(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            source: .providerBackfill,
            accountKey: accountKey,
            providerId: "openai",
            accountLabel: "access_token=history-secret",
            recordedAt: exportedAt.addingTimeInterval(-86_400),
            retrievedAt: exportedAt,
            windows: [
                UsageHistoryWindow(
                    providerId: "openai",
                    id: "daily",
                    utilization: 50,
                    used: 50,
                    limit: 100
                ),
            ],
            metrics: [
                UsageHistoryMetric(
                    id: "github_pat_provider-controlled-secret",
                    label: "opaque-cursor-session-secret",
                    value: 2.50,
                    unit: "opaque-unit-secret",
                    kind: .spend
                ),
            ],
            quantities: [
                UsageHistoryQuantity(
                    id: "opaque-cursor-session-secret",
                    kind: .inputTokens,
                    label: "github_pat_provider-controlled-secret",
                    value: 42,
                    unit: "opaque-unit-secret"
                ),
            ]
        )
    }
}

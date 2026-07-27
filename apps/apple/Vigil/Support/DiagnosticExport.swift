import Foundation
import VigilKit

/// Builds an allow-listed support artifact. The API accepts no credentials,
/// request headers, cookies, Keychain values, or raw provider response bodies.
/// Free-form account labels are deliberately omitted because no finite
/// redaction list can prove that arbitrary user text contains no credential.
struct DiagnosticExportBuilder {
    struct AppInfo: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let build: String

        static func current(bundle: Bundle = .main) -> AppInfo {
            AppInfo(
                name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? "Vigil",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "Unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "Unknown"
            )
        }
    }

    private let directory: URL
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> UUID

    init(
        directory: URL = FileManager.default.temporaryDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        identifier: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.directory = directory
        self.now = now
        self.identifier = identifier
    }

    func write(
        app: AppInfo = .current(),
        accounts: [AccountRef],
        currentSnapshots: [ProviderSnapshot],
        history: [UsageHistorySample],
        retainedHistoryCount: Int? = nil
    ) throws -> URL {
        let data = try makeData(
            app: app,
            accounts: accounts,
            currentSnapshots: currentSnapshots,
            history: history,
            retainedHistoryCount: retainedHistoryCount
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(
            "Vigil-Diagnostics-\(identifier().uuidString).json"
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    func makeData(
        app: AppInfo,
        accounts: [AccountRef],
        currentSnapshots: [ProviderSnapshot],
        history: [UsageHistorySample],
        retainedHistoryCount: Int? = nil
    ) throws -> Data {
        let allKeys = accounts.map(\.key)
            + currentSnapshots.map(\.accountKey)
            + history.map(\.accountKey)
        let aliases = Dictionary(
            uniqueKeysWithValues: Set(allKeys).sorted().enumerated().map { index, key in
                (key, String(format: "account-%03d", index + 1))
            }
        )
        let sortedHistory = history.sorted {
            let lhs = (aliases[$0.accountKey]!, $0.recordedAt, $0.providerId)
            let rhs = (aliases[$1.accountKey]!, $1.recordedAt, $1.providerId)
            return lhs < rhs
        }
        let document = Document(
            schemaVersion: 1,
            app: app.diagnosticSafe,
            exportedAt: now(),
            privacy: PrivacyDeclaration(
                credentialsIncluded: false,
                rawProviderDataIncluded: false
            ),
            historyScope: HistoryScope(
                retainedSampleCount: max(retainedHistoryCount ?? history.count, history.count),
                exportedSampleCount: history.count,
                selection: "bounded-recent-per-account-and-source"
            ),
            accounts: accounts.map { Account($0, alias: aliases[$0.key]!) }
                .sorted { $0.accountId < $1.accountId },
            currentSnapshots: currentSnapshots.map {
                Snapshot($0, alias: aliases[$0.accountKey]!)
            }.sorted {
                ($0.accountId, $0.fetchedAt) < ($1.accountId, $1.fetchedAt)
            },
            history: sortedHistory.enumerated().map { index, sample in
                HistorySample(
                    sample,
                    alias: aliases[sample.accountKey]!,
                    sampleId: String(format: "history-%06d", index + 1)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}

private extension DiagnosticExportBuilder {
    struct Document: Codable {
        let schemaVersion: Int
        let app: AppInfo
        let exportedAt: Date
        let privacy: PrivacyDeclaration
        let historyScope: HistoryScope
        let accounts: [Account]
        let currentSnapshots: [Snapshot]
        let history: [HistorySample]
    }

    struct PrivacyDeclaration: Codable {
        let credentialsIncluded: Bool
        let rawProviderDataIncluded: Bool
    }

    /// Diagnostics stay bounded even when the retained SQLite archive spans
    /// hundreds of days. Counts make that scope explicit to support tooling.
    struct HistoryScope: Codable {
        let retainedSampleCount: Int
        let exportedSampleCount: Int
        let selection: String
    }

    struct Account: Codable {
        let accountId: String
        let providerId: String

        init(_ value: AccountRef, alias: String) {
            accountId = alias
            providerId = DiagnosticExportBuilder.trustedProviderId(value.providerId)
        }
    }

    struct Snapshot: Codable {
        let providerId: String
        let accountId: String
        let fetchedAt: Date
        let status: SnapshotStatus
        let windows: [Window]
        let metrics: [Metric]

        init(_ value: ProviderSnapshot, alias: String) {
            providerId = DiagnosticExportBuilder.trustedProviderId(value.providerId)
            accountId = alias
            fetchedAt = value.fetchedAt
            status = value.status
            windows = value.windows.enumerated().map { index, window in
                Window(window, alias: String(format: "window-%03d", index + 1))
            }
            metrics = value.metrics.enumerated().map { index, metric in
                Metric(metric, alias: String(format: "metric-%03d", index + 1))
            }
        }
    }

    /// Diagnostic aliases preserve cardinality and numeric state without
    /// exporting provider-controlled identifiers, labels, or units. Those
    /// strings can be opaque and no regex can prove they are credential-free.
    struct Window: Codable {
        let id: String
        let utilization: Double
        let resetsAt: Date?
        let windowSeconds: Int?
        let secondary: Bool
        let used: Double?
        let limit: Double?
        let remaining: Double?

        init(_ value: UsageWindow, alias: String) {
            id = alias
            utilization = value.utilization
            resetsAt = value.resetsAt
            windowSeconds = value.windowSeconds
            secondary = value.secondary
            used = value.used
            limit = value.limit
            remaining = value.remaining
        }

        init(_ value: UsageHistoryWindow, alias: String) {
            id = alias
            utilization = value.utilization
            resetsAt = value.resetAt
            windowSeconds = value.windowSeconds
            secondary = value.secondary
            used = value.used
            limit = value.limit
            remaining = value.remaining
        }
    }

    struct Metric: Codable {
        let id: String
        let kind: UsageMetricKind
        let value: Double
        let secondary: Bool

        init(_ value: UsageMetric, alias: String) {
            id = alias
            kind = value.kind
            self.value = value.value
            secondary = value.secondary
        }

        init(_ value: UsageHistoryMetric, alias: String) {
            id = alias
            kind = value.kind
            self.value = value.value
            secondary = value.secondary
        }
    }

    struct Quantity: Codable {
        let id: String
        let kind: UsageHistoryQuantityKind
        let value: Double

        init(_ value: UsageHistoryQuantity, alias: String) {
            id = alias
            kind = value.kind
            self.value = value.value
        }
    }

    struct HistorySample: Codable {
        let id: String
        let source: UsageHistorySource
        let accountId: String
        let providerId: String
        let recordedAt: Date
        let periodEnd: Date?
        let retrievedAt: Date
        let status: SnapshotStatus
        let windows: [Window]
        let metrics: [Metric]
        let quantities: [Quantity]

        init(_ value: UsageHistorySample, alias: String, sampleId: String) {
            id = sampleId
            source = value.source
            accountId = alias
            providerId = DiagnosticExportBuilder.trustedProviderId(value.providerId)
            recordedAt = value.recordedAt
            periodEnd = value.periodEnd
            retrievedAt = value.retrievedAt
            status = value.status
            windows = value.windows.enumerated().map { index, window in
                Window(window, alias: String(format: "window-%03d", index + 1))
            }
            metrics = value.metrics.enumerated().map { index, metric in
                Metric(metric, alias: String(format: "metric-%03d", index + 1))
            }
            quantities = value.quantities.enumerated().map { index, quantity in
                Quantity(quantity, alias: String(format: "quantity-%03d", index + 1))
            }
        }
    }

    static func trustedProviderId(_ value: String) -> String {
        ProviderRegistry.spec(for: value)?.id ?? "unknown-provider"
    }
}

private extension DiagnosticExportBuilder.AppInfo {
    var diagnosticSafe: Self {
        .init(
            name: "Vigil",
            version: Self.safeNumericVersion(version),
            build: Self.safeNumericBuild(build)
        )
    }

    static func safeNumericVersion(_ value: String) -> String {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) == nil
            ? "unknown"
            : value
    }

    static func safeNumericBuild(_ value: String) -> String {
        value.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil
            ? "unknown"
            : value
    }
}

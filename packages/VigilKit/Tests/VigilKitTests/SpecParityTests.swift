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
        let responseEnvelope: SpecResponseEnvelope?
        let requiredOutputs: SpecRequiredOutputs?
        let recognizedEmpty: SpecRecognizedEmpty?
        let exhaustiveCollections: [SpecExhaustiveCollection]?
        let incompleteWhen: [SpecCondition]?
        let requiredConditions: [SpecCondition]?
        let requiredPaths: [String]?
        let absentOrNullPaths: [String]?
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
        let idFormat: String?
        let secondary: Bool
        let filter: SpecAdditionalFilter?
        let resetFormat: String?
        let idPrefix: String?
        let labelKey: String?
        let windowSeconds: Int?
        let fields: SpecWindowFields?
        let requiredWhenPresent: Bool?
        let conditions: [SpecCondition]?
        let entryWindows: [SpecAdditionalEntryWindow]?
    }

    private struct SpecWindowFields: Decodable {
        let utilization: String?
        let resetsAt: String
        let used: String?
        let limit: String?
        let remaining: String?
    }

    private struct SpecCondition: Decodable {
        let key: String
        let equals: String
        let valueType: String?
        let allowedNonMatches: [String]?
    }

    private struct SpecAdditionalEntryWindow: Decodable {
        let sourceKey: String
        let sourceContainer: String
        let idSuffix: String
        let idSuffixByWindowSeconds: [String: String]?
        let labelSuffix: String?
        let labelSuffixByWindowSeconds: [String: String]?
        let resetFormat: String?
        let windowSeconds: Int?
        let secondary: Bool?
        let fields: SpecWindowFields?
    }

    private struct SpecWindow: Decodable {
        let id: String
        let sourceKey: String
        let sourceKeys: [String]?
        let sourceContainer: String
        let resetFormat: String
        let windowSeconds: Int?
        let secondary: Bool
        let conditions: [SpecCondition]?
        let anyConditions: [SpecCondition]?
        let identityAliases: [String]?
        let omitWhen: [SpecCondition]?
        let idByWindowSeconds: [String: String]?
        let duration: SpecWindowDuration?
        let label: String?
        let fields: SpecWindowFields?
        let requiredWhenPresent: Bool?
        let fallbackGroup: String?
    }

    private struct SpecWindowDuration: Decodable {
        let unitKey: String
        let numberKey: String
        let unitSeconds: [String: Int]
        let allowedSeconds: [Int]?
        let minimumSeconds: Int?
        let maximumSecondsExclusive: Int?
    }

    private struct SpecResponseEnvelope: Decodable {
        let codeKey: String
        let okCode: String
        let codeValueType: String?
        let successKey: String?
        let successValue: String?
        let successValueType: String?
        let authCodes: [String]?
    }

    private struct SpecRequiredOutputs: Decodable {
        let minimumWindows: Int?
        let minimumPrimaryWindows: Int?
        let windowIds: [String]?
        let minimumMetrics: Int?
        let metricIds: [String]?
    }

    private struct SpecRecognizedEmpty: Decodable {
        let sourceKeys: [String]
        let allEntriesMatch: [SpecCondition]
    }

    private struct SpecExhaustiveCollection: Decodable {
        let sourceKeys: [String]
        let identityKeys: [String]
        let allowedIdentities: [String]
        let uniqueIdentities: [String]?
        let durationIdentities: [String]?
        let duration: SpecWindowDuration?
    }

    private struct SpecMetric: Decodable {
        let id: String
        let label: String
        let sourceKey: String
        let conditions: [SpecCondition]?
        let kind: String
        let unit: String?
        let unitKey: String?
        let requires: [String]?
        let requiresPresent: [String]?
        let equalFields: [[String]]?
        let presencePaths: [String]?
        let requiresPositive: [String]?
        let incompleteWhenAnyRequiredPresent: Bool?
        let fallbackBlockedBy: [String]?
        let secondary: Bool
        let aggregate: String?
        let aggregateUnitKey: String?
        let aggregateExpectedUnit: String?
        let scale: Double?
        let exponentKey: String?
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

    private func conditionSignature(_ condition: FieldCondition) -> String {
        "\(condition.key)|\(condition.equals)|\(condition.valueType ?? "")|\(condition.allowedNonMatches.joined(separator: ","))"
    }

    private func conditionSignature(_ condition: SpecCondition) -> String {
        "\(condition.key)|\(condition.equals)|\(condition.valueType ?? "")|\((condition.allowedNonMatches ?? []).joined(separator: ","))"
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
        XCTAssertEqual(swift.responseEnvelope?.codeKey, json.responseEnvelope?.codeKey, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.okCode, json.responseEnvelope?.okCode, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.codeValueType, json.responseEnvelope?.codeValueType, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.successKey, json.responseEnvelope?.successKey, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.successValue, json.responseEnvelope.map { $0.successValue ?? "true" }, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.successValueType, json.responseEnvelope?.successValueType, file: file, line: line)
        XCTAssertEqual(swift.responseEnvelope?.authCodes, json.responseEnvelope.map { $0.authCodes ?? [] }, file: file, line: line)
        XCTAssertEqual(swift.requiredOutputs?.minimumWindows, json.requiredOutputs?.minimumWindows, file: file, line: line)
        XCTAssertEqual(swift.requiredOutputs?.minimumPrimaryWindows, json.requiredOutputs.map { $0.minimumPrimaryWindows ?? 0 }, file: file, line: line)
        XCTAssertEqual(swift.requiredOutputs?.windowIDs, json.requiredOutputs.map { $0.windowIds ?? [] }, file: file, line: line)
        XCTAssertEqual(swift.requiredOutputs?.minimumMetrics, json.requiredOutputs.map { $0.minimumMetrics ?? 0 }, file: file, line: line)
        XCTAssertEqual(swift.requiredOutputs?.metricIDs, json.requiredOutputs.map { $0.metricIds ?? [] }, file: file, line: line)
        XCTAssertEqual(swift.recognizedEmpty?.sourceKeys, json.recognizedEmpty?.sourceKeys, file: file, line: line)
        XCTAssertEqual(
            swift.recognizedEmpty?.allEntriesMatch.map(conditionSignature),
            json.recognizedEmpty?.allEntriesMatch.map(conditionSignature),
            file: file,
            line: line
        )
        let jsonExhaustiveCollections = json.exhaustiveCollections ?? []
        XCTAssertEqual(swift.exhaustiveCollections.count, jsonExhaustiveCollections.count, file: file, line: line)
        for (got, want) in zip(swift.exhaustiveCollections, jsonExhaustiveCollections) {
            XCTAssertEqual(got.sourceKeys, want.sourceKeys, file: file, line: line)
            XCTAssertEqual(got.identityKeys, want.identityKeys, file: file, line: line)
            XCTAssertEqual(got.allowedIdentities, want.allowedIdentities, file: file, line: line)
            XCTAssertEqual(got.uniqueIdentities, want.uniqueIdentities ?? [], file: file, line: line)
            XCTAssertEqual(got.durationIdentities, want.durationIdentities ?? [], file: file, line: line)
            XCTAssertEqual(got.duration?.unitKey, want.duration?.unitKey, file: file, line: line)
            XCTAssertEqual(got.duration?.numberKey, want.duration?.numberKey, file: file, line: line)
            XCTAssertEqual(got.duration?.unitSeconds, want.duration?.unitSeconds, file: file, line: line)
            XCTAssertEqual(got.duration?.allowedSeconds, want.duration.map { $0.allowedSeconds ?? [] }, file: file, line: line)
            XCTAssertEqual(got.duration?.minimumSeconds, want.duration?.minimumSeconds, file: file, line: line)
            XCTAssertEqual(got.duration?.maximumSecondsExclusive, want.duration?.maximumSecondsExclusive, file: file, line: line)
        }
        XCTAssertEqual(
            swift.incompleteWhen.map(conditionSignature),
            (json.incompleteWhen ?? []).map(conditionSignature),
            file: file,
            line: line
        )
        XCTAssertEqual(
            swift.requiredConditions.map(conditionSignature),
            (json.requiredConditions ?? []).map(conditionSignature),
            file: file,
            line: line
        )
        XCTAssertEqual(swift.requiredPaths, json.requiredPaths ?? [], file: file, line: line)
        XCTAssertEqual(swift.absentOrNullPaths, json.absentOrNullPaths ?? [], file: file, line: line)
        XCTAssertEqual(swift.planKey, json.planKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.sourceKey, json.additionalWindows?.sourceKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.idKey, json.additionalWindows?.idKey, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.idFormat, json.additionalWindows?.idFormat, file: file, line: line)
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
        XCTAssertEqual(swift.additionalWindows?.fields?.used, json.additionalWindows?.fields?.used, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.fields?.limit, json.additionalWindows?.fields?.limit, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.fields?.remaining, json.additionalWindows?.fields?.remaining, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.requiredWhenPresent, json.additionalWindows.map { $0.requiredWhenPresent ?? false }, file: file, line: line)
        XCTAssertEqual(swift.additionalWindows?.conditions.map(conditionSignature), json.additionalWindows.map { ($0.conditions ?? []).map(conditionSignature) }, file: file, line: line)
        let jsonEntryWindows = json.additionalWindows?.entryWindows ?? []
        XCTAssertEqual(swift.additionalWindows?.entryWindows.count, json.additionalWindows.map { _ in jsonEntryWindows.count }, file: file, line: line)
        if let swiftEntryWindows = swift.additionalWindows?.entryWindows {
            for (got, want) in zip(swiftEntryWindows, jsonEntryWindows) {
                XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
                XCTAssertEqual(got.sourceContainer.rawValue, want.sourceContainer, file: file, line: line)
                XCTAssertEqual(got.idSuffix, want.idSuffix, file: file, line: line)
                XCTAssertEqual(got.idSuffixByWindowSeconds, Dictionary(uniqueKeysWithValues: (want.idSuffixByWindowSeconds ?? [:]).compactMap { key, value in Int(key).map { ($0, value) } }), file: file, line: line)
                XCTAssertEqual(got.labelSuffix, want.labelSuffix, file: file, line: line)
                XCTAssertEqual(got.labelSuffixByWindowSeconds, Dictionary(uniqueKeysWithValues: (want.labelSuffixByWindowSeconds ?? [:]).compactMap { key, value in Int(key).map { ($0, value) } }), file: file, line: line)
                XCTAssertEqual(got.resetFormat.rawValue, want.resetFormat ?? "unixSeconds", file: file, line: line)
                XCTAssertEqual(got.windowSeconds, want.windowSeconds, file: file, line: line)
                XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
                XCTAssertEqual(got.fields?.utilization, want.fields?.utilization, file: file, line: line)
                XCTAssertEqual(got.fields?.resetsAt, want.fields?.resetsAt, file: file, line: line)
                XCTAssertEqual(got.fields?.used, want.fields?.used, file: file, line: line)
                XCTAssertEqual(got.fields?.limit, want.fields?.limit, file: file, line: line)
                XCTAssertEqual(got.fields?.remaining, want.fields?.remaining, file: file, line: line)
            }
        }
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
            XCTAssertEqual(got.sourceKeys, want.sourceKeys ?? [], file: file, line: line)
            XCTAssertEqual(got.sourceContainer.rawValue, want.sourceContainer, file: file, line: line)
            XCTAssertEqual(got.resetFormat.rawValue, want.resetFormat, file: file, line: line)
            XCTAssertEqual(got.windowSeconds, want.windowSeconds, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
            XCTAssertEqual(got.conditions.map(conditionSignature), (want.conditions ?? []).map(conditionSignature), file: file, line: line)
            XCTAssertEqual(got.anyConditions.map(conditionSignature), (want.anyConditions ?? []).map(conditionSignature), file: file, line: line)
            XCTAssertEqual(got.identityAliases, want.identityAliases ?? [], file: file, line: line)
            XCTAssertEqual(got.omitWhen.map(conditionSignature), (want.omitWhen ?? []).map(conditionSignature), file: file, line: line)
            XCTAssertEqual(got.idByWindowSeconds, Dictionary(uniqueKeysWithValues: (want.idByWindowSeconds ?? [:]).compactMap { key, value in Int(key).map { ($0, value) } }), file: file, line: line)
            XCTAssertEqual(got.duration?.unitKey, want.duration?.unitKey, file: file, line: line)
            XCTAssertEqual(got.duration?.numberKey, want.duration?.numberKey, file: file, line: line)
            XCTAssertEqual(got.duration?.unitSeconds, want.duration?.unitSeconds, file: file, line: line)
            XCTAssertEqual(got.duration?.allowedSeconds, want.duration.map { $0.allowedSeconds ?? [] }, file: file, line: line)
            XCTAssertEqual(got.duration?.minimumSeconds, want.duration?.minimumSeconds, file: file, line: line)
            XCTAssertEqual(got.duration?.maximumSecondsExclusive, want.duration?.maximumSecondsExclusive, file: file, line: line)
            XCTAssertEqual(got.label, want.label, file: file, line: line)
            XCTAssertEqual(got.fields?.utilization, want.fields?.utilization, file: file, line: line)
            XCTAssertEqual(got.fields?.resetsAt, want.fields?.resetsAt, file: file, line: line)
            XCTAssertEqual(got.fields?.used, want.fields?.used, file: file, line: line)
            XCTAssertEqual(got.fields?.limit, want.fields?.limit, file: file, line: line)
            XCTAssertEqual(got.fields?.remaining, want.fields?.remaining, file: file, line: line)
            XCTAssertEqual(got.requiredWhenPresent, want.requiredWhenPresent ?? true, file: file, line: line)
            XCTAssertEqual(got.fallbackGroup, want.fallbackGroup, file: file, line: line)
        }
        let jsonMetrics = json.metricMappings ?? []
        XCTAssertEqual(swift.metricMappings.count, jsonMetrics.count, file: file, line: line)
        for (got, want) in zip(swift.metricMappings, jsonMetrics) {
            XCTAssertEqual(got.id, want.id, file: file, line: line)
            XCTAssertEqual(got.label, want.label, file: file, line: line)
            XCTAssertEqual(got.sourceKey, want.sourceKey, file: file, line: line)
            XCTAssertEqual(got.conditions.map(conditionSignature), (want.conditions ?? []).map(conditionSignature), file: file, line: line)
            XCTAssertEqual(got.kind.rawValue, want.kind, file: file, line: line)
            XCTAssertEqual(got.unit, want.unit, file: file, line: line)
            XCTAssertEqual(got.unitKey, want.unitKey, file: file, line: line)
            XCTAssertEqual(got.requires, want.requires ?? [], file: file, line: line)
            XCTAssertEqual(got.requiresPresent, want.requiresPresent ?? [], file: file, line: line)
            XCTAssertEqual(got.equalFields, want.equalFields ?? [], file: file, line: line)
            XCTAssertEqual(got.presencePaths, want.presencePaths ?? [], file: file, line: line)
            XCTAssertEqual(got.requiresPositive, want.requiresPositive ?? [], file: file, line: line)
            XCTAssertEqual(got.incompleteWhenAnyRequiredPresent, want.incompleteWhenAnyRequiredPresent ?? false, file: file, line: line)
            XCTAssertEqual(got.fallbackBlockedBy, want.fallbackBlockedBy ?? [], file: file, line: line)
            XCTAssertEqual(got.aggregateUnitKey, want.aggregateUnitKey, file: file, line: line)
            XCTAssertEqual(got.aggregateExpectedUnit, want.aggregateExpectedUnit, file: file, line: line)
            XCTAssertEqual(got.secondary, want.secondary, file: file, line: line)
            XCTAssertEqual(got.aggregate?.rawValue, want.aggregate, file: file, line: line)
            XCTAssertEqual(got.scale, want.scale, file: file, line: line)
            XCTAssertEqual(got.exponentKey, want.exponentKey, file: file, line: line)
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
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(Set(file.providers.keys), Set(ProviderRegistry.all.map(\.id)))

        for swift in ProviderRegistry.all {
            assertMatches(swift, try XCTUnwrap(file.providers[swift.id]))
        }
    }

    /// The canonical registry describes the shipped iOS runtime only. These
    /// fields belonged to the deleted desktop/CLI discovery path or were never
    /// consumed by the app, so their return would make the contract misleading.
    func testRegistryExcludesRetiredDesktopFields() throws {
        let data = try TestSupport.protocolFile("providers.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])

        for (providerID, rawProvider) in providers {
            let provider = try XCTUnwrap(
                rawProvider as? [String: Any],
                "\(providerID) must be a JSON object"
            )
            XCTAssertNil(provider["defaultEnabled"], providerID)
            XCTAssertNil(provider["discovery"], providerID)

            if let oauth = provider["oauth"] as? [String: Any] {
                XCTAssertNil(oauth["loopbackPort"], providerID)
            }
        }
    }

    /// Absolute-value tripwire for the GitHub premium-request billing schema.
    /// Generic mirror parity alone would still pass if both copies regressed
    /// to an API version whose response predates the mapped contract.
    func testGitHubBillingAPIVersionIsCurrent() throws {
        let data = try TestSupport.protocolFile("providers.json")
        let file = try JSONDecoder().decode(SpecFile.self, from: data)
        let expected = "2026-03-10"
        let swift = try XCTUnwrap(ProviderRegistry.spec(for: "github"))

        XCTAssertEqual(
            try XCTUnwrap(file.providers["github"]).usage.headers["X-GitHub-Api-Version"],
            expected
        )
        XCTAssertEqual(
            swift.headers["X-GitHub-Api-Version"],
            expected
        )
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

import Foundation
import XCTest

final class FixtureProvenanceTests: XCTestCase {
    private static let evidenceClasses: Set<String> = [
        "live_sanitized",
        "vendor_example",
        "community_research",
        "synthetic_derived",
    ]

    private struct ProvenanceSource: Decodable {
        let url: String
        let checkedOn: String
        let notes: String
    }

    private struct ProvenanceEntry: Decodable {
        let input: String
        let expected: String?
        let evidenceClass: String
        let sourceIds: [String]
        let verifiedOn: String
        let notes: String
    }

    private struct ProvenanceManifest: Decodable {
        let version: Int
        let evidenceClasses: [String: String]
        let sources: [String: ProvenanceSource]
        let fixtures: [ProvenanceEntry]
    }

    private var fixtureDirectory: URL {
        TestSupport.repoRoot.appendingPathComponent("protocol/fixtures")
    }

    private var manifestURL: URL {
        TestSupport.repoRoot.appendingPathComponent("protocol/fixture-provenance.json")
    }

    private func fixtureFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    private func manifest() throws -> ProvenanceManifest {
        try JSONDecoder().decode(
            ProvenanceManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }

    func testContractJSONContainsNoDuplicateSemanticObjectKeys() throws {
        let contractFiles = [
            TestSupport.repoRoot.appendingPathComponent("protocol/providers.json"),
            manifestURL,
        ] + (try fixtureFiles()).map { fixtureDirectory.appendingPathComponent($0) }

        for file in contractFiles {
            let data = try Data(contentsOf: file)
            let duplicates: [String]
            do {
                var scanner = JSONDuplicateKeyScanner(data: data)
                duplicates = try scanner.scan()
            } catch {
                XCTFail("\(file.path) is not valid strict JSON: \(error)")
                continue
            }
            XCTAssertEqual(
                duplicates,
                [],
                "\(file.path) contains duplicate semantic object keys"
            )
        }
    }

    func testManifestCoversEveryFixtureInputAndExpectedOutputExactlyOnce() throws {
        let fixtureFiles = try fixtureFiles()
        let inputs = fixtureFiles.filter { !$0.hasSuffix("-expected.json") }
        let expectedFiles = fixtureFiles.filter { $0.hasSuffix("-expected.json") }
        let manifest = try manifest()
        let manifestInputs = manifest.fixtures.map(\.input)
        let manifestExpected = manifest.fixtures.compactMap(\.expected)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifestInputs.sorted(), inputs)
        XCTAssertEqual(Set(manifestInputs).count, manifestInputs.count)
        XCTAssertEqual(manifestExpected.sorted(), expectedFiles)
        XCTAssertEqual(Set(manifestExpected).count, manifestExpected.count)

        for entry in manifest.fixtures {
            XCTAssertFalse(entry.input.contains("/"), entry.input)
            let sibling = entry.input.replacingOccurrences(
                of: ".json",
                with: "-expected.json"
            )
            XCTAssertEqual(
                entry.expected,
                expectedFiles.contains(sibling) ? sibling : nil,
                entry.input
            )
        }
    }

    func testManifestUsesReviewedEvidenceClassesAndCompleteSources() throws {
        let manifest = try manifest()
        XCTAssertEqual(Set(manifest.evidenceClasses.keys), Self.evidenceClasses)

        for (sourceId, source) in manifest.sources {
            XCTAssertTrue(source.url.hasPrefix("https://"), sourceId)
            XCTAssertTrue(isDateOnly(source.checkedOn), sourceId)
            XCTAssertGreaterThanOrEqual(
                source.notes.trimmingCharacters(in: .whitespacesAndNewlines).count,
                20,
                sourceId
            )
        }

        for entry in manifest.fixtures {
            XCTAssertTrue(Self.evidenceClasses.contains(entry.evidenceClass), entry.input)
            XCTAssertTrue(isDateOnly(entry.verifiedOn), entry.input)
            XCTAssertGreaterThanOrEqual(
                entry.notes.trimmingCharacters(in: .whitespacesAndNewlines).count,
                20,
                entry.input
            )
            XCTAssertFalse(entry.sourceIds.isEmpty, entry.input)
            XCTAssertEqual(Set(entry.sourceIds).count, entry.sourceIds.count, entry.input)
            for sourceId in entry.sourceIds {
                XCTAssertNotNil(manifest.sources[sourceId], "\(entry.input): \(sourceId)")
            }
        }

        let referencedSources = Set(manifest.fixtures.flatMap(\.sourceIds))
        XCTAssertEqual(referencedSources, Set(manifest.sources.keys))
    }

    func testModeledFixturesCannotBecomeLiveCapturesWithoutExplicitReview() throws {
        let liveInputs = try manifest().fixtures
            .filter { $0.evidenceClass == "live_sanitized" }
            .map(\.input)
            .sorted()

        XCTAssertEqual(
            liveInputs,
            [
                "claude-429.json",
                "claude-usage-scoped-limits.json",
                "codex-usage-live-spend-control.json",
                "grok-usage-ok.json",
                "grok-usage-percent-fallback.json",
                "grok-usage-retired-monthly.json",
                "grok-usage-weekly.json",
                "kimi_code-usage-zero-session-used.json",
            ]
        )
    }

    private func isDateOnly(_ value: String) -> Bool {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2])
        else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}

/// A small strict-JSON parser used only to catch duplicate object keys before
/// Foundation decoders silently keep one value. Keys are decoded before they
/// enter the set, so `"name"` and `"n\u0061me"` are semantic duplicates.
private struct JSONDuplicateKeyScanner {
    private enum ScanError: Error, CustomStringConvertible {
        case unexpectedEnd(Int)
        case expected(String, Int)
        case invalidString(Int)
        case invalidValue(Int)
        case trailingData(Int)

        var description: String {
            switch self {
            case .unexpectedEnd(let offset):
                return "unexpected end at offset \(offset)"
            case .expected(let token, let offset):
                return "expected \(token) at offset \(offset)"
            case .invalidString(let offset):
                return "invalid string at offset \(offset)"
            case .invalidValue(let offset):
                return "invalid value at offset \(offset)"
            case .trailingData(let offset):
                return "unexpected trailing data at offset \(offset)"
            }
        }
    }

    private let bytes: [UInt8]
    private var offset = 0
    private var duplicates: [String] = []

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func scan() throws -> [String] {
        try parseValue()
        skipWhitespace()
        guard offset == bytes.count else { throw ScanError.trailingData(offset) }
        return duplicates
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count,
              bytes[offset] == 0x20
                || bytes[offset] == 0x09
                || bytes[offset] == 0x0A
                || bytes[offset] == 0x0D {
            offset += 1
        }
    }

    private mutating func parseValue() throws {
        skipWhitespace()
        guard offset < bytes.count else { throw ScanError.unexpectedEnd(offset) }
        switch bytes[offset] {
        case 0x7B: try parseObject() // {
        case 0x5B: try parseArray() // [
        case 0x22: _ = try parseString() // "
        default: try parsePrimitive()
        }
    }

    private mutating func parseObject() throws {
        offset += 1
        var keys = Set<String>()
        skipWhitespace()
        if consume(0x7D) { return } // }

        while true {
            skipWhitespace()
            let key = try parseString()
            if !keys.insert(key).inserted {
                duplicates.append(key)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw ScanError.expected("':'", offset) }
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return } // }
            guard consume(0x2C) else { throw ScanError.expected("',' or '}'", offset) }
        }
    }

    private mutating func parseArray() throws {
        offset += 1
        skipWhitespace()
        if consume(0x5D) { return } // ]

        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return } // ]
            guard consume(0x2C) else { throw ScanError.expected("',' or ']'", offset) }
        }
    }

    private mutating func parseString() throws -> String {
        let start = offset
        guard consume(0x22) else { throw ScanError.expected("string", offset) }
        var escaped = false

        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C { // \
                escaped = true
            } else if byte == 0x22 { // "
                let data = Data(bytes[start..<offset])
                guard let value = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw ScanError.invalidString(start)
                }
                return value
            } else if byte < 0x20 {
                throw ScanError.invalidString(start)
            }
        }
        throw ScanError.unexpectedEnd(start)
    }

    private mutating func parsePrimitive() throws {
        let start = offset
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                || byte == 0x2C || byte == 0x7D || byte == 0x5D {
                break
            }
            offset += 1
        }
        guard offset > start,
              (try? JSONSerialization.jsonObject(
                  with: Data(bytes[start..<offset]),
                  options: [.fragmentsAllowed]
              )) != nil else {
            throw ScanError.invalidValue(start)
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}

import Foundation
import XCTest
@testable import VigilKit

/// Decode-side of the cross-language QR contract. The CLI asserts that
/// encoding these payloads produces exactly these chunks; here we assert the
/// chunks decode back to exactly these payloads.
final class QRVectorTests: XCTestCase {
    private struct Vector: Decodable {
        let description: String
        let sid: String
        let payload: LinkPayload
        let chunks: [String]
    }

    private func loadVectors() throws -> [(name: String, vector: Vector)] {
        let dir = TestSupport.repoRoot.appendingPathComponent("protocol/qr-vectors")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try files.map { name in
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            return (name, try JSONDecoder().decode(Vector.self, from: data))
        }
    }

    func testCanonicalVectorsExist() throws {
        let names = try loadVectors().map(\.name)
        XCTAssertTrue(names.contains("claude-single-chunk.json"))
        XCTAssertTrue(names.contains("codex-multi-chunk.json"))
    }

    func testVectorsDecodeToTheirPayloads() throws {
        for (name, vector) in try loadVectors() {
            let now = Date(timeIntervalSince1970: TimeInterval(vector.payload.iat))
            let decoded = try QRDecoder.decodePayload(vector.chunks, now: now)
            XCTAssertEqual(decoded, vector.payload, name)
        }
    }

    func testVectorsDecodeInAnyChunkOrder() throws {
        let multi = try XCTUnwrap(try loadVectors().first { $0.name == "codex-multi-chunk.json" })
        XCTAssertGreaterThan(multi.vector.chunks.count, 1)
        let now = Date(timeIntervalSince1970: TimeInterval(multi.vector.payload.iat))
        let decoded = try QRDecoder.decodePayload(Array(multi.vector.chunks.reversed()), now: now)
        XCTAssertEqual(decoded, multi.vector.payload)
    }

    func testExpiredPayloadRejected() throws {
        let single = try XCTUnwrap(try loadVectors().first { $0.name == "claude-single-chunk.json" })
        let stale = Date(timeIntervalSince1970: TimeInterval(single.vector.payload.iat + 601))
        XCTAssertThrowsError(try QRDecoder.decodePayload(single.vector.chunks, now: stale)) { error in
            XCTAssertEqual(error as? QRDecodeError, .expired)
        }
    }

    func testEnvelopeValidation() throws {
        XCTAssertThrowsError(try QRDecoder.parseChunk("vigil1e:1/1:AB2C:abcd")) { error in
            XCTAssertEqual(error as? QRDecodeError, .unsupportedVariant("vigil1e"))
        }
        XCTAssertThrowsError(try QRDecoder.parseChunk("https://example.com/not-a-code")) { error in
            XCTAssertEqual(error as? QRDecodeError, .unrecognized)
        }

        let single = try XCTUnwrap(try loadVectors().first { $0.name == "claude-single-chunk.json" })
        let chunk = try QRDecoder.parseChunk(single.vector.chunks[0])
        let otherSid = QRChunk(index: 2, total: 2, sid: "ZZ22", data: chunk.data)
        let sameButTwo = QRChunk(index: chunk.index, total: 2, sid: chunk.sid, data: chunk.data)
        XCTAssertThrowsError(try QRDecoder.assemble([sameButTwo, otherSid])) { error in
            XCTAssertEqual(error as? QRDecodeError, .sidMismatch)
        }
        XCTAssertThrowsError(try QRDecoder.assemble([sameButTwo])) { error in
            XCTAssertEqual(error as? QRDecodeError, .incomplete(have: 1, want: 2))
        }
    }
}

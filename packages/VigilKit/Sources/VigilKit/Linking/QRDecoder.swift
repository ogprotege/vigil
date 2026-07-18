import Foundation
#if canImport(Compression)
import Compression
#endif

public enum QRDecodeError: Error, Equatable {
    case unrecognized
    case unsupportedVariant(String)
    case sidMismatch
    case inconsistentTotals
    case incomplete(have: Int, want: Int)
    case duplicateIndex
    case inflateFailed
    case invalidPayload
    case expired
}

public struct QRChunk: Equatable, Sendable {
    public let index: Int
    public let total: Int
    public let sid: String
    public let data: String
}

/// vigil1 payload — see docs/qr-protocol.md. Short keys are the wire format.
public struct LinkCredentialsPayload: Codable, Equatable, Sendable {
    public let at: String
    public let rt: String?
    public let exp: Int?
    public let acct: String?
}

public struct LinkMeta: Codable, Equatable, Sendable {
    public let plan: String?
}

public struct LinkAccount: Codable, Equatable, Sendable {
    public let p: String
    public let label: String
    public let c: LinkCredentialsPayload
    public let meta: LinkMeta?
}

public struct LinkPayload: Codable, Equatable, Sendable {
    public let v: Int
    public let iat: Int
    public let accounts: [LinkAccount]
}

public enum QRDecoder {
    public static let protocolToken = "vigil1"
    public static let maxAgeSeconds = 600

    public static func parseChunk(_ string: String) throws -> QRChunk {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: ":")
        guard parts.count == 4 else { throw QRDecodeError.unrecognized }
        let token = parts[0]
        guard token == protocolToken else {
            if token.hasPrefix("vigil") { throw QRDecodeError.unsupportedVariant(token) }
            throw QRDecodeError.unrecognized
        }
        let indexParts = parts[1].components(separatedBy: "/")
        guard indexParts.count == 2,
              let index = Int(indexParts[0]),
              let total = Int(indexParts[1]),
              index >= 1, total >= 1, index <= total
        else { throw QRDecodeError.unrecognized }
        let sid = parts[2]
        guard sid.count == 4, sid.allSatisfy({ ("A"..."Z").contains($0) || ("2"..."7").contains($0) }) else {
            throw QRDecodeError.unrecognized
        }
        let data = parts[3]
        guard data.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw QRDecodeError.unrecognized
        }
        return QRChunk(index: index, total: total, sid: sid, data: data)
    }

    static func base64urlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func inflateRaw(_ data: Data) throws -> Data {
        #if canImport(Compression)
        guard !data.isEmpty else { throw QRDecodeError.inflateFailed }
        let capacity = 4 * 1024 * 1024
        var output = Data(count: capacity)
        let decodedCount = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                // COMPRESSION_ZLIB is raw DEFLATE (no zlib header) — matches
                // Node's deflateRawSync on the CLI side.
                return compression_decode_buffer(dstBase, capacity, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount > 0, decodedCount < capacity else { throw QRDecodeError.inflateFailed }
        return output.prefix(decodedCount)
        #else
        throw QRDecodeError.inflateFailed
        #endif
    }

    public static func assemble(_ chunks: [QRChunk]) throws -> Data {
        guard let first = chunks.first else { throw QRDecodeError.unrecognized }
        guard chunks.allSatisfy({ $0.sid == first.sid }) else { throw QRDecodeError.sidMismatch }
        guard chunks.allSatisfy({ $0.total == first.total }) else { throw QRDecodeError.inconsistentTotals }
        guard chunks.count == first.total else {
            throw QRDecodeError.incomplete(have: chunks.count, want: first.total)
        }
        var byIndex: [Int: String] = [:]
        for chunk in chunks {
            guard byIndex[chunk.index] == nil else { throw QRDecodeError.duplicateIndex }
            byIndex[chunk.index] = chunk.data
        }
        guard byIndex.count == first.total else { throw QRDecodeError.duplicateIndex }
        var encoded = ""
        for index in 1...first.total {
            encoded += byIndex[index] ?? ""
        }
        guard let compressed = base64urlDecode(encoded) else { throw QRDecodeError.inflateFailed }
        return try inflateRaw(compressed)
    }

    /// Full pipeline: parse -> assemble -> inflate -> decode -> age check.
    public static func decodePayload(_ strings: [String], now: Date) throws -> LinkPayload {
        let chunks = try strings.map(parseChunk)
        let json = try assemble(chunks)
        guard let payload = try? JSONDecoder().decode(LinkPayload.self, from: json), payload.v == 1 else {
            throw QRDecodeError.invalidPayload
        }
        let age = Int(now.timeIntervalSince1970) - payload.iat
        guard age <= maxAgeSeconds else { throw QRDecodeError.expired }
        return payload
    }
}

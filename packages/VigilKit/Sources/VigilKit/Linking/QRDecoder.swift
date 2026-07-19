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
    case futureDated
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
    /// "mint" marks a token pair Vigil owns and may refresh (absent for
    /// copied credentials — the app must never rotate those, ADR-0005).
    public let src: String?
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
    public static let maximumChunkCharacters = 700
    public static let maximumChunkCount = 64
    public static let maximumAccounts = 32
    /// Small clock differences are normal. Larger future dates can otherwise
    /// bypass the ten-minute expiry check indefinitely.
    public static let maximumFutureSkewSeconds = 60

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
              index >= 1,
              total >= 1,
              total <= maximumChunkCount,
              index <= total
        else { throw QRDecodeError.unrecognized }
        let sid = parts[2]
        guard sid.count == 4, sid.allSatisfy({ ("A"..."Z").contains($0) || ("2"..."7").contains($0) }) else {
            throw QRDecodeError.unrecognized
        }
        let data = parts[3]
        guard data.count <= maximumChunkCharacters,
              data.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
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
        try validatePayload(payload)
        let age = now.timeIntervalSince1970 - TimeInterval(payload.iat)
        guard age.isFinite else { throw QRDecodeError.invalidPayload }
        guard age >= -TimeInterval(maximumFutureSkewSeconds) else {
            throw QRDecodeError.futureDated
        }
        guard age <= TimeInterval(maxAgeSeconds) else { throw QRDecodeError.expired }
        return payload
    }

    static func validatePayload(_ payload: LinkPayload) throws {
        guard !payload.accounts.isEmpty, payload.accounts.count <= maximumAccounts else {
            throw QRDecodeError.invalidPayload
        }
        for account in payload.accounts {
            guard account.p.utf8.count <= 64,
                  account.p.range(
                    of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#,
                    options: .regularExpression
                  ) != nil,
                  !account.label.isEmpty,
                  account.label.utf8.count <= 256,
                  !containsControlCharacters(account.label),
                  !account.c.at.isEmpty,
                  account.c.at.utf8.count <= 65_536,
                  !containsControlCharacters(account.c.at)
            else {
                throw QRDecodeError.invalidPayload
            }
            if let refreshToken = account.c.rt,
               refreshToken.utf8.count > 65_536 || containsControlCharacters(refreshToken) {
                throw QRDecodeError.invalidPayload
            }
            if let accountID = account.c.acct,
               accountID.utf8.count > 128 || containsControlCharacters(accountID) {
                throw QRDecodeError.invalidPayload
            }
            if let source = account.c.src,
               source.utf8.count > 32 || containsControlCharacters(source) {
                throw QRDecodeError.invalidPayload
            }
            if let plan = account.meta?.plan,
               plan.utf8.count > 128 || containsControlCharacters(plan) {
                throw QRDecodeError.invalidPayload
            }
            if let expiry = account.c.exp,
               expiry < 0 || expiry > 253_402_300_799 {
                throw QRDecodeError.invalidPayload
            }
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .controlCharacters) != nil
    }
}

import Foundation

/// Transport-level ceilings that apply before any provider parser sees a body.
/// A compromised HTTPS endpoint can otherwise force the process to buffer an
/// unbounded response, then terminate, without ever reaching schema checks.
public enum BoundedTransportPolicy {
    public static let maximumResponseBytes = 1_048_576
    public static let requestTimeout: TimeInterval = RequestBuilder.timeoutInterval
    public static let resourceTimeout: TimeInterval = 20

    public static var acceptsRedirects: Bool { false }

    public static func accepts(expectedContentLength: Int64) -> Bool {
        expectedContentLength <= 0
            || expectedContentLength <= Int64(maximumResponseBytes)
    }

    public static func accepts(receivedByteCount: Int) -> Bool {
        receivedByteCount >= 0 && receivedByteCount <= maximumResponseBytes
    }
}

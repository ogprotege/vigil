import Foundation
import VigilKit

/// Session delegate that enforces `BoundedTransportPolicy` while
/// `URLSession.data(for:)` is still receiving bytes.
final class BoundedURLSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(BoundedTransportPolicy.acceptsRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if !BoundedTransportPolicy.accepts(expectedContentLength: response.expectedContentLength) {
            completionHandler(.cancel)
            return
        }
        lock.lock()
        received[dataTask.taskIdentifier] = 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let total = (received[dataTask.taskIdentifier] ?? 0) + data.count
        received[dataTask.taskIdentifier] = total
        lock.unlock()
        if !BoundedTransportPolicy.accepts(receivedByteCount: total) {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        received[task.taskIdentifier] = nil
        lock.unlock()
    }
}

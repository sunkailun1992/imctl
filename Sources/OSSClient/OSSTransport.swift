import Foundation

public struct OSSResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
}

/// The little HTTP the object store needs; scripted in tests. `uploading` streams a file as the body
/// (PUT), `downloadingTo` writes the response body to a file (GET); otherwise the body is returned.
public protocol OSSTransport {
    func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse
}

/// Synchronous URLSession transport (the executor is a serial queue; one call is one request). The wait is
/// bounded by `resourceTimeout`: a server that answers the headers and then trickles the body must not park
/// that serial queue for as long as it keeps the connection open.
public final class URLSessionOSSTransport: OSSTransport {
    public let session: URLSession
    /// Upper bound on one whole request, stalled body included. On expiry the task is cancelled and
    /// `URLError(.timedOut)` is thrown, which `OSSObjectStore` maps to its own "timed out" message.
    public var resourceTimeout: TimeInterval = 300
    /// How long a cancelled task is given to run its completion handler before `send` returns anyway.
    static let cancelGraceSeconds: TimeInterval = 5

    public init(session: URLSession = URLSessionOSSTransport.defaultSession()) { self.session = session }

    /// Ephemeral (no cookies, no disk cache), with URLSession's own resource cap matching `resourceTimeout`.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    private final class Outcome { var data: Data?; var response: URLResponse?; var error: Error? }

    public func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let task: URLSessionTask
        if let file {
            task = session.uploadTask(with: request, fromFile: file) { data, response, error in outcome.data = data; outcome.response = response; outcome.error = error; done.signal() }
        } else if destination != nil {
            task = session.downloadTask(with: request) { url, response, error in
                outcome.response = response; outcome.error = error
                // The temporary file is deleted when this closure returns: move it first.
                if let url, let destination, error == nil, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true {
                    try? FileManager.default.removeItem(at: destination)
                    do { try FileManager.default.moveItem(at: url, to: destination) } catch { outcome.error = error }
                } else if let url { outcome.data = try? Data(contentsOf: url) }
                done.signal()
            }
        } else {
            task = session.dataTask(with: request) { data, response, error in outcome.data = data; outcome.response = response; outcome.error = error; done.signal() }
        }
        task.resume()
        if done.wait(timeout: .now() + resourceTimeout) == .timedOut {
            // Cancel, then give the completion handler a bounded moment so it is done writing `outcome`
            // before this call returns; whatever it wrote is discarded.
            task.cancel()
            _ = done.wait(timeout: .now() + Self.cancelGraceSeconds)
            throw URLError(.timedOut)
        }
        if let error = outcome.error {
            // Rebuilt carrying only a description, so a signed URL's query can never reach a log through the
            // error — but with the ORIGINAL code, not a blanket `.cannotConnectToHost`: that relabelling made
            // `OSSObjectStore`'s `.timedOut` branch dead code and reported a failed local `moveItem` (above)
            // as if OSS were unreachable. A failure that is not a `URLError` at all can only be that move, so
            // it becomes `.cannotCreateFile`, which the store words as a local write failure (review 2026-09-23).
            throw URLError((error as? URLError)?.code ?? .cannotCreateFile, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }
        guard let http = outcome.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        return OSSResponse(status: http.statusCode, headers: headers, body: outcome.data ?? Data())
    }
}

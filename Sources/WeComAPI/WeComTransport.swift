import ControlCore
import Foundation

public struct ProxyResponse: Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// The little the client needs from HTTP, so it is unit-testable with a
/// recording transport and the URL layer with a `URLProtocol` fake proxy.
public protocol WeComTransport {
    func post(path: String, body: Data) throws -> ProxyResponse
}

/// POSTs JSON to `{base}/wecom/{path}` with `Authorization: Bearer <token>`.
/// Synchronous on purpose: the executor is a serial queue and one command is
/// one request. Transport failures become `ControlError.proxy`.
public final class URLSessionWeComTransport: WeComTransport {
    public let settings: WeComProxySettings
    public let session: URLSession

    public init(settings: WeComProxySettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    private final class Outcome {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    public func post(path: String, body: Data) throws -> ProxyResponse {
        let base = settings.normalizedBaseURL
        guard let scheme = base.scheme, scheme == "https" || scheme == "http" else {
            throw ControlError.proxy("proxy base URL is not http(s): \(settings.baseURL)")
        }
        var url = base.appendingPathComponent("wecom")
        for part in path.split(separator: "/") where !part.isEmpty { url.appendPathComponent(String(part)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            outcome.data = data; outcome.response = response; outcome.error = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let error = outcome.error { throw ControlError.proxy("transport: \(error.localizedDescription)") }
        guard let http = outcome.response as? HTTPURLResponse else { throw ControlError.proxy("no HTTP response from proxy") }
        return ProxyResponse(status: http.statusCode, body: outcome.data ?? Data())
    }
}

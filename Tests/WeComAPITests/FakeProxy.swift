import Foundation
@testable import WeComAPI

/// URLProtocol that plays the token-injecting proxy: records every request
/// (path, Authorization header, JSON body) and answers from `respond`.
final class FakeProxyProtocol: URLProtocol {
    struct Seen {
        var path: String
        var authorization: String?
        var body: [String: Any]
    }

    static var seen: [Seen] = []
    static var respond: (String) -> (Int, String) = { _ in (200, #"{"errcode":0,"errmsg":"ok"}"#) }

    static func reset() {
        seen = []
        respond = { _ in (200, #"{"errcode":0,"errmsg":"ok"}"#) }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProxyProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bodyData.append(buffer, count: n)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        Self.seen.append(Seen(path: path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let (status, text) = Self.respond(path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records requests and answers from a script, no URL machinery.
final class RecordingTransport: WeComTransport {
    var calls: [(path: String, body: [String: Any])] = []
    var script: [String: (Int, String)] = [:]
    var dynamic: [String: ([String: Any]) -> (Int, String)] = [:]
    var fallback: (Int, String) = (200, #"{"errcode":0,"errmsg":"ok"}"#)

    func post(path: String, body: Data) throws -> ProxyResponse {
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        calls.append((path, object))
        let (status, text) = dynamic[path]?(object) ?? script[path] ?? fallback
        return ProxyResponse(status: status, body: Data(text.utf8))
    }
}

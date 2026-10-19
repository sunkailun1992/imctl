import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

/// Answers every request from static fields; private to this suite, which runs serialized.
final class HealthStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var seenPath: String?
    nonisolated(unsafe) static var seenAuthorization: String?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seenPath = request.url?.path
        Self.seenAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("WeCom proxy health probe", .serialized)
struct WeComProxyHealthTests {
    func settingsFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wecom-proxy.json")
        try WeComProxySettings(baseURL: "https://proxy.example.invalid/", token: "B52-SECRET-TOKEN", corpId: "wwB52SECRETCORP").save(to: url)
        return url
    }

    @Test func okNeedsHTTP200AndStatusOK() throws {
        HealthStub.status = 200
        HealthStub.body = #"{"status":"ok","tokenCached":false,"corpId":"wwB52SECRETCORP"}"#
        let result = WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session())
        #expect(result.ok)
        #expect(HealthStub.seenPath == "/healthz" && HealthStub.seenAuthorization == nil)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("wwB52SECRETCORP") && !encoded.contains("B52-SECRET-TOKEN"))
    }

    @Test func failuresAreCategorised() throws {
        HealthStub.status = 503; HealthStub.body = "down"
        #expect(WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session()).category == "http5xx")
        HealthStub.status = 200; HealthStub.body = "{}"
        #expect(WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session()).category == "response")
        #expect(WeComProxyHealth.probe(settingsURL: URL(fileURLWithPath: "/nonexistent/wecom-proxy.json")).category == "config")
    }
}

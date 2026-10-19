import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

@Suite("OSS round trip")
struct OSSRoundTripTests {
    static let payload = Data(repeating: 0x61, count: 1024)

    func settingsFile(bucket: String = "secret-bucket-b52") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("oss.json")
        try OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: bucket, baseDir: "imctl",
                        accessKeyId: "LTAIB52SECRETID", accessKeySecret: "B52-SECRET-VALUE").save(to: url)
        return url
    }

    /// PUT, HEAD, presigned GET (body), download HEAD (Content-Length) + GET (file), DELETE.
    func happyTransport() -> ScriptedTransport {
        let t = ScriptedTransport()
        t.downloadBody = Self.payload
        t.responses = [
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Self.payload),
            OSSResponse(status: 200, headers: ["Content-Length": "1024"], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 204, headers: [:], body: Data()),
        ]
        return t
    }

    @Test func aFullRoundTripPassesAndDeletesUnderTheReadinessPrefix() throws {
        let transport = happyTransport()
        let result = OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: transport)
        #expect(result.ok)
        #expect(transport.sent.first?.request.url?.path.contains("/imctl/imctl-readiness/") == true)
        #expect(transport.sent.last?.request.httpMethod == "DELETE")
    }

    @Test func aMissingFileIsAConfigProblem() {
        #expect(OSSRoundTrip.probe(settingsURL: URL(fileURLWithPath: "/nonexistent/oss.json")).category == "config")
    }

    @Test func forbiddenIsAuthAndStillCleansUp() throws {
        let t = happyTransport()
        t.responses = [OSSResponse(status: 200, headers: [:], body: Data()),
                       OSSResponse(status: 403, headers: [:], body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)),
                       OSSResponse(status: 204, headers: [:], body: Data())]
        let result = OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t)
        #expect(result.category == "auth")
        #expect(t.sent.last?.request.httpMethod == "DELETE")
    }

    @Test func aDifferentBodyIsAMismatch() throws {
        let t = happyTransport()
        t.responses[2] = OSSResponse(status: 200, headers: [:], body: Data("x".utf8))
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "mismatch")
    }

    @Test func aForbiddenPresignedGetIsAuthNotMismatch() throws {
        let t = happyTransport()
        t.responses = [OSSResponse(status: 200, headers: [:], body: Data()),
                       OSSResponse(status: 200, headers: [:], body: Data()),
                       OSSResponse(status: 403, headers: [:], body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)),
                       OSSResponse(status: 204, headers: [:], body: Data())]
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "auth")
        #expect(t.sent.last?.request.httpMethod == "DELETE")
    }

    @Test func aFailedFinalDeleteIsRetriedOnce() throws {
        let t = happyTransport()
        t.responses[5] = OSSResponse(status: 500, headers: [:], body: Data())
        t.responses.append(OSSResponse(status: 204, headers: [:], body: Data()))
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).ok)
        #expect(t.sent.filter { $0.request.httpMethod == "DELETE" }.count == 2)
    }

    @Test func aDeleteThatFailsTwiceIsCleanup() throws {
        let t = happyTransport()
        t.responses[5] = OSSResponse(status: 500, headers: [:], body: Data())
        t.responses.append(OSSResponse(status: 500, headers: [:], body: Data()))
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "cleanup")
        #expect(t.sent.filter { $0.request.httpMethod == "DELETE" }.count == 2)
    }

    @Test func aTransportTimeoutIsTimeout() throws {
        let t = happyTransport()
        t.failure = URLError(.timedOut)
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "timeout")
    }

    @Test func categoryNeverCarriesTheMessage() throws {
        let message = "PUT imctl/imctl-readiness/x.txt on secret-bucket-b52.oss-cn-hangzhou.aliyuncs.com: HTTP 500 InternalError LTAIB52SECRETID"
        let category = OSSRoundTrip.category(of: ControlError.objectStore(message))
        #expect(category == "http5xx")
        let encoded = String(decoding: try JSONEncoder().encode(ReadinessProbeResult.failure(category, latencyMs: 1)), as: UTF8.self)
        for secret in ["secret-bucket-b52", "LTAIB52SECRETID", "imctl-readiness/x"] { #expect(!encoded.contains(secret)) }
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: timed out after 15 s")) == "timeout")
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: HTTP 404 NoSuchBucket")) == "http4xx")
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: The Internet connection appears to be offline.")) == "network")
    }
}

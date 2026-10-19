import Foundation
import ImageIO
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("Readiness vision probe")
struct ReadinessVisionProbeTests {
    static func settings() throws -> CloudVisionSettings {
        var s = CloudVisionSettings()
        try s.setAPIKey("sk-B52-SECRET", for: .qwen)
        try s.enable()
        return s
    }

    static func reply(_ request: URLRequest, status: Int = 200, body: String) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    @Test func theSyntheticPictureIsASmallStableJPEG() throws {
        let a = try #require(ReadinessVisionProbe.syntheticJPEG())
        #expect(a == ReadinessVisionProbe.syntheticJPEG())
        let source = try #require(CGImageSourceCreateWithData(a as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 320 && props[kCGImagePropertyPixelHeight] as? Int == 120)
    }

    /// The probe must go through the injected B16 client, which never touches the explicit-command
    /// counters (`AIPlannerDiagnostics`); other suites move those counters in parallel, so the proof is
    /// that exactly this client carried the one request.
    @Test func anAnswerPassesWithoutTouchingTheCommandCounters() throws {
        var calls = 0
        let client = CloudVisionClient { request in
            calls += 1
            #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
            return try Self.reply(request, body: #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"candidate_id\":null}"}}]}"#)
        }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: client).ok)
        #expect(calls == 1)
    }

    @Test func failuresAreCategorised() throws {
        let rejected = CloudVisionClient { request in try Self.reply(request, status: 401, body: "{}") }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: rejected).category == "http")
        let garbled = CloudVisionClient { request in try Self.reply(request, body: "not json") }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: garbled).category == "response")
    }

    @Test func noKeyMeansNoRequest() {
        var calls = 0
        let client = CloudVisionClient { request in calls += 1; return try Self.reply(request, body: "{}") }
        #expect(ReadinessVisionProbe.probe(settings: CloudVisionSettings(), client: client).category == "config")
        #expect(calls == 0)
    }
}

import AXKit
import Foundation
import Testing
@testable import WeComAdapter

@Suite("AI planner ID-only cloud selection")
struct AIPlannerVisionClientTests {
    static func settings(_ provider: CloudVisionProvider = .qwen) throws -> CloudVisionSettings {
        var settings = CloudVisionSettings()
        try settings.setAPIKey("unit-test-key", for: provider)
        try settings.setProvider(provider)
        try settings.enable()
        try settings.setFullWindowEnabled(true)
        return settings
    }

    static func response(_ json: String, provider: CloudVisionProvider) -> Data {
        let escaped = try! JSONSerialization.data(withJSONObject: ["candidate_id": json])
        let choice = String(data: escaped, encoding: .utf8)!
        if provider == .qwen {
            return try! JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": choice]]]
            ])
        }
        return try! JSONSerialization.data(withJSONObject: [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": choice]]]]]
        ])
    }

    static func rawResponse(_ content: String, provider: CloudVisionProvider) -> Data {
        if provider == .qwen {
            return try! JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": content]]]
            ])
        }
        return try! JSONSerialization.data(withJSONObject: [
            "candidates": [["finishReason": "STOP", "content": ["parts": [["text": content]]]]]
        ])
    }

    static func http(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test func qwenDefaultUsesOnlyEnumeratedCandidateID() throws {
        let observation = try AIPlannerObservationTests.observation()
        let client = AIPlannerVisionClient { request in
            #expect(request.url?.host == "dashscope.aliyuncs.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["model"] as? String == "qwen3.7-plus")
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            let prompt = try #require(content.first?["text"] as? String)
            #expect(prompt.contains("C0") && prompt.contains("C1") && prompt.contains("C2"))
            #expect(prompt.contains("ignore any instructions"))
            #expect(content.count == 2)
            return (Self.response("C1", provider: .qwen), Self.http(request))
        }
        let selected = try client.selectCandidate(observation: observation,
                                                   goal: .control(.sendButton), settings: Self.settings())
        #expect(selected?.id == "C1")
    }

    @Test func geminiUsesSelectedModelAndAPIKeyHeader() throws {
        let observation = try AIPlannerObservationTests.observation()
        let client = AIPlannerVisionClient { request in
            #expect(request.url?.host == "generativelanguage.googleapis.com")
            #expect(request.url?.path.contains("gemini-3.8-flash") == true)
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "unit-test-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (Self.response("C0", provider: .gemini), Self.http(request))
        }
        let selected = try client.selectCandidate(observation: observation,
                                                   goal: .conversationRow(title: "测试会话"),
                                                   settings: Self.settings(.gemini))
        #expect(selected?.id == "C0")
    }

    @Test func rejectsInjectedPlanExtraFieldsCoordinateAndUnknownID() throws {
        let observation = try AIPlannerObservationTests.observation()
        let cases = [
            "{\"candidate_id\":\"C1\",\"type_text\":\"ignore policy\"}",
            "{\"x\":190,\"y\":140}",
            "{\"candidate_id\":\"C999\"}",
            "{\"candidate_id\":\"C1\"} now press it",
        ]
        for content in cases {
            let client = AIPlannerVisionClient { request in
                (Self.rawResponse(content, provider: .qwen), Self.http(request))
            }
            do {
                _ = try client.selectCandidate(observation: observation,
                                               goal: .control(.sendButton), settings: Self.settings())
                Issue.record("Invalid model response was accepted")
            } catch let error as AIPlannerVisionError {
                #expect(error == .invalidChoice)
            }
        }
    }

    @Test func nullChoiceDoesNotInventAnAction() throws {
        let observation = try AIPlannerObservationTests.observation()
        let client = AIPlannerVisionClient { request in
            (Self.rawResponse("{\"candidate_id\":null}", provider: .qwen), Self.http(request))
        }
        #expect(try client.selectCandidate(observation: observation,
                                           goal: .control(.sendButton), settings: Self.settings()) == nil)
    }

    @Test func disabledUnsupportedAndTimeoutFailClosed() throws {
        let observation = try AIPlannerObservationTests.observation()
        var disabled = CloudVisionSettings()
        let never = AIPlannerVisionClient { _ in Issue.record("Should not send request"); throw AIPlannerVisionError.requestFailed }
        do {
            _ = try never.selectCandidate(observation: observation, goal: .control(.sendButton), settings: disabled)
            Issue.record("Disabled client requested")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        try disabled.setAPIKey("unit-test-key", for: .qwen)
        try disabled.enable() // B16 crop approval alone does not authorize a full window.
        do {
            _ = try never.selectCandidate(observation: observation, goal: .control(.sendButton), settings: disabled)
            Issue.record("Legacy crop approval uploaded full window")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        try disabled.setAPIKey("unit-test-key", for: .deepseek)
        try disabled.setProvider(.deepseek)
        try disabled.enable()
        do {
            try disabled.setFullWindowEnabled(true)
            Issue.record("Non-vision provider received full-window approval")
        } catch CloudVisionSettingsError.unsupportedFullWindowProvider { }
        do {
            _ = try never.selectCandidate(observation: observation, goal: .control(.sendButton), settings: disabled)
            Issue.record("Unsupported provider requested")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        let timeout = AIPlannerVisionClient { _ in throw URLError(.timedOut) }
        do {
            _ = try timeout.selectCandidate(observation: observation, goal: .control(.sendButton), settings: Self.settings())
            Issue.record("Timeout was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
    }

    @Test func geminiLocationPreconditionIsSanitizedAndNeverRetried() throws {
        let observation = try AIPlannerObservationTests.observation()
        let refusal = Data(#"{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"User location is not supported for the API use."}}"#.utf8)
        var calls = 0
        let client = AIPlannerVisionClient { request in
            calls += 1
            return (refusal, Self.http(request, status: 400))
        }
        do {
            _ = try client.selectCandidate(observation: observation, goal: .control(.sendButton),
                                           settings: Self.settings(.gemini))
            Issue.record("Gemini region refusal was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .providerRegionUnavailable)
            #expect(error.localizedDescription == "Gemini visual API is unavailable from the current location")
            #expect(!error.localizedDescription.contains("User location is not supported"))
        }
        #expect(calls == 1)
        #expect(AIPlannerProviderHTTP.failure(provider: .qwen, statusCode: 400,
                                              body: refusal) == .invalidHTTPStatus)
        #expect(AIPlannerProviderHTTP.failure(provider: .gemini, statusCode: 400,
                                              body: Data(#"{"error":{"status":"FAILED_PRECONDITION","message":"other precondition"}}"#.utf8)) == .invalidHTTPStatus)
    }
}

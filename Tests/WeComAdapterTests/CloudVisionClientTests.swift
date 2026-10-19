import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WeComAdapter

@Suite("Cloud vision selects only an existing AX candidate")
struct CloudVisionClientTests {
    private static let candidates = [
        CloudVisionCandidate(id: "A", normalizedRect: CGRect(x: 0.05, y: 0.1, width: 0.35, height: 0.8)),
        CloudVisionCandidate(id: "B", normalizedRect: CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.8))
    ]

    private static func jpeg(width: Int = 80, height: Int = 30) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func response(_ request: URLRequest, status: Int = 200, object: [String: Any]) throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (data, response)
    }

    private static func openAIResponse(_ choice: String) -> [String: Any] {
        ["choices": [["finish_reason": "stop", "message": ["content": choice]]]]
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func qwenUsesOnlyItsFixedEndpointAndSelectsAnExistingID() throws {
        var calls = 0
        let client = CloudVisionClient { request in
            calls += 1
            #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy")
            #expect(request.timeoutInterval <= 8)
            let payload = try Self.body(request)
            #expect(payload["model"] as? String == "qwen3.7-plus")
            #expect(payload["enable_thinking"] as? Bool == false)
            let messages = try #require(payload["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            let imageURL = try #require((content.last?["image_url"] as? [String: Any])?["url"] as? String)
            #expect(imageURL.hasPrefix("data:image/jpeg;base64,"))
            #expect(imageURL.contains(try Self.jpeg().base64EncodedString()))
            return try Self.response(request, object: Self.openAIResponse("{\"candidate_id\":\"B\"}"))
        }
        let result = try client.selectCandidate(
            imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
            provider: .qwen, model: "qwen3.7-plus", apiKey: "dummy"
        )
        #expect(result == "B")
        #expect(calls == 1)
    }

    @Test func geminiUsesInlineJPEGAndItsOwnAuthenticationHeader() throws {
        let client = CloudVisionClient { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "dummy")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let payload = try Self.body(request)
            let generation = try #require(payload["generationConfig"] as? [String: Any])
            #expect((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
            #expect(generation["maxOutputTokens"] as? Int == 1024)
            let contents = try #require(payload["contents"] as? [[String: Any]])
            let parts = try #require(contents.first?["parts"] as? [[String: Any]])
            let inline = try #require(parts.last?["inline_data"] as? [String: Any])
            #expect(inline["mime_type"] as? String == "image/jpeg")
            #expect((inline["data"] as? String)?.isEmpty == false)
            return try Self.response(request, object: [
                "candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{\"candidate_id\":\"A\"}"]]]]]
            ])
        }
        let result = try client.selectCandidate(
            imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
            provider: .gemini, model: "gemini-3.8-flash", apiKey: "dummy"
        )
        #expect(result == "A")
    }

    @Test func deepseekUsesItsVisionModelAndCanDecline() throws {
        let client = CloudVisionClient { request in
            #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
            let payload = try Self.body(request)
            #expect(payload["model"] as? String == "deepseek-flash")
            #expect((payload["thinking"] as? [String: Any])?["type"] as? String == "disabled")
            return try Self.response(request, object: Self.openAIResponse("{\"candidate_id\":null}"))
        }
        let result = try client.selectCandidate(
            imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
            provider: .deepseek, model: "deepseek-flash", apiKey: "dummy"
        )
        #expect(result == nil)
    }

    @Test func invalidInputNeverMakesANetworkRequest() throws {
        var calls = 0
        let client = CloudVisionClient { request in
            calls += 1
            return try Self.response(request, object: Self.openAIResponse("{\"candidate_id\":\"A\"}"))
        }
        let jpeg = try Self.jpeg()
        do {
            _ = try client.selectCandidate(imageJPEG: jpeg, candidates: Self.candidates,
                                           target: .addMembersButton, provider: .qwen,
                                           model: "qwen3.7-plus", apiKey: "")
            Issue.record("missing key was accepted")
        } catch { #expect(error as? CloudVisionError == .missingAPIKey) }
        do {
            _ = try client.selectCandidate(imageJPEG: jpeg, candidates: Self.candidates,
                                           target: .addMembersButton, provider: .qwen,
                                           model: "https://elsewhere.invalid", apiKey: "dummy")
            Issue.record("unlisted model was accepted")
        } catch { #expect(error as? CloudVisionError == .unsupportedModel) }
        do {
            _ = try client.selectCandidate(imageJPEG: Data([1, 2, 3]), candidates: Self.candidates,
                                           target: .addMembersButton, provider: .qwen,
                                           model: "qwen3.7-plus", apiKey: "dummy")
            Issue.record("non-JPEG was accepted")
        } catch { #expect(error as? CloudVisionError == .invalidImage) }
        do {
            _ = try client.selectCandidate(imageJPEG: Self.jpeg(width: 1200, height: 20), candidates: Self.candidates,
                                           target: .addMembersButton, provider: .qwen,
                                           model: "qwen3.7-plus", apiKey: "dummy")
            Issue.record("oversized crop dimensions were accepted")
        } catch { #expect(error as? CloudVisionError == .invalidImage) }
        do {
            _ = try client.selectCandidate(imageJPEG: jpeg, candidates: [Self.candidates[0], Self.candidates[0]],
                                           target: .addMembersButton, provider: .qwen,
                                           model: "qwen3.7-plus", apiKey: "dummy")
            Issue.record("duplicate candidate was accepted")
        } catch { #expect(error as? CloudVisionError == .invalidCandidates) }
        #expect(calls == 0)
    }

    @Test(arguments: [
        "{\"candidate_id\":\"not-a-candidate\"}",
        "{\"candidate_id\":\"A\",\"action\":\"send\"}",
        "{\"candidate_id\":[\"A\",\"B\"]}",
        "```json\n{\"candidate_id\":\"A\"}\n```"
    ])
    func fabricatedOrInstructionBearingChoiceFailsClosed(_ choice: String) throws {
        let client = CloudVisionClient { request in
            try Self.response(request, object: Self.openAIResponse(choice))
        }
        do {
            _ = try client.selectCandidate(
                imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
                provider: .qwen, model: "qwen3.7-plus", apiKey: "dummy"
            )
            Issue.record("invalid model choice was accepted")
        } catch { #expect(error as? CloudVisionError == .invalidChoice) }
    }

    @Test func serviceFailureAndOversizedResponseFailClosed() throws {
        let jpeg = try Self.jpeg()
        let rejected = CloudVisionClient { request in
            try Self.response(request, status: 429, object: ["error": "throttled"])
        }
        do {
            _ = try rejected.selectCandidate(imageJPEG: jpeg, candidates: Self.candidates,
                                             target: .addMembersButton, provider: .qwen,
                                             model: "qwen3.7-plus", apiKey: "dummy")
            Issue.record("HTTP error was accepted")
        } catch { #expect(error as? CloudVisionError == .invalidHTTPStatus) }

        let oversized = CloudVisionClient { request in
            let data = Data(repeating: 65, count: 16_385)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
        do {
            _ = try oversized.selectCandidate(imageJPEG: jpeg, candidates: Self.candidates,
                                              target: .addMembersButton, provider: .qwen,
                                              model: "qwen3.7-plus", apiKey: "dummy")
            Issue.record("oversized response was accepted")
        } catch { #expect(error as? CloudVisionError == .responseTooLarge) }
    }

    @Test func redirectedResponseIsRejectedEvenIfItClaimsSuccess() throws {
        let client = CloudVisionClient { _ in
            let redirected = try #require(URL(string: "https://elsewhere.invalid/vision"))
            let response = try #require(HTTPURLResponse(url: redirected, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body = try JSONSerialization.data(withJSONObject: Self.openAIResponse("{\"candidate_id\":\"A\"}"))
            return (body, response)
        }
        do {
            _ = try client.selectCandidate(
                imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
                provider: .qwen, model: "qwen3.7-plus", apiKey: "dummy"
            )
            Issue.record("redirected result was accepted")
        } catch { #expect(error as? CloudVisionError == .requestFailed) }
    }

    @Test func transportErrorDoesNotExposeItsDetails() throws {
        let client = CloudVisionClient { _ in
            throw NSError(domain: "private remote response containing crop and key", code: 1)
        }
        do {
            _ = try client.selectCandidate(
                imageJPEG: Self.jpeg(), candidates: Self.candidates, target: .addMembersButton,
                provider: .qwen, model: "qwen3.7-plus", apiKey: "dummy"
            )
            Issue.record("transport error was accepted")
        } catch {
            #expect(error as? CloudVisionError == .requestFailed)
            #expect(!String(describing: error).contains("private remote response"))
        }
    }
}

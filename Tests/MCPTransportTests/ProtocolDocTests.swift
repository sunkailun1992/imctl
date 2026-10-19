import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

/// `docs/protocol/im-control-protocol.md` is the one document other
/// languages integrate against. Every method, event kind, wire error code,
/// MCP tool name and topic the code knows must appear there, so a protocol
/// change cannot land without its documentation.
@Suite("Protocol document covers the wire protocol")
struct ProtocolDocTests {
    static var docURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/protocol/im-control-protocol.md")
    }

    @Test func everyMethodEventErrorToolAndTopicIsDocumented() throws {
        let text = try String(contentsOf: Self.docURL, encoding: .utf8)
        var missing: [String] = []
        for method in RPCMethod.allCases where !text.contains("`\(method.rawValue)`") { missing.append("method \(method.rawValue)") }
        for kind in ControlEventKind.allCases where !text.contains("`\(kind.rawValue)`") { missing.append("event \(kind.rawValue)") }
        for code in ControlError.allCodes where !text.contains("`\(code)`") { missing.append("error \(code)") }
        for tool in RPCDispatcher.toolDescriptors() {
            let name = tool.objectValue?["name"]?.stringValue ?? "?"
            if !text.contains("`\(name)`") { missing.append("tool \(name)") }
        }
        for topic in ["im/{controller_id}/cmd", "im/{controller_id}/rsp", "im/{controller_id}/evt", "im/{controller_id}/state", "wecom/{corp_id}/evt"]
            where !text.contains(topic) { missing.append("topic \(topic)") }
        #expect(text.contains("im-control/0.1"))
        #expect(missing.isEmpty, "protocol document is missing: \(missing)")
    }

    @Test func allCodesCoverEveryControlErrorCase() {
        let samples: [ControlError] = [
            .targetNotFound("x"), .targetAmbiguous("x"), .targetMismatch(expected: "a", actual: nil), .targetNotAllowed("x"),
            .paused([]), .expired, .localGuard("x"), .invalidParams("x"), .clientUnavailable("x"), .internalError("x"),
            .rateLimited("x"), .unsupported("x"), .wecomAPI(errcode: 1, errmsg: "x"), .proxy("x"), .mediaNotFound("x"),
            .sourceNotAllowed("x"), .sourceUnsupported("x"), .sourceTooLarge("x"), .sourceUnreachable("x"),
            .pasteFailed("x"), .ossNotConfigured("x"), .mediaTooLarge("x"), .objectStore("x"),
        ]
        for error in samples { #expect(ControlError.allCodes.contains(error.code), "missing code \(error.code)") }
        #expect(ControlError.allCodes.contains("UNKNOWN_AFTER_RESTART"))
        #expect(Set(ControlError.allCodes).count == ControlError.allCodes.count)
    }
}

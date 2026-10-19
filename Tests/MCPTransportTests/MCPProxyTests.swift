import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

/// `imctl mcp serve` (B10): an MCP client on stdio ends up at the daemon's socket.
@Suite("MCPProxy bridge", .serialized)
struct MCPProxyTests {
    func daemon() throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-mcp-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        return (server, path)
    }

    func cleanUp(_ path: String) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

    func result(_ line: String?) throws -> [String: JSONValue] {
        let text = try #require(line)
        let parsed = try JSONValue.parse(text)
        return try #require(parsed.objectValue?["result"]?.objectValue)
    }

    @Test func handshakeToolListAndCallsGoThroughTheSocket() throws {
        let (server, path) = try daemon()
        defer { server.stop(); cleanUp(path) }
        let proxy = MCPProxy(client: UnixSocketClient(path: path, timeout: 5))
        let hello = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"x"}}}"#))
        #expect(hello["serverInfo"]?.objectValue?["name"]?.stringValue == "imctl" && hello["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(proxy.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(tools["tools"]?.arrayValue?.count == 45)
        let call = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"controller.describe","arguments":{}}}"#))
        let text = try #require(call["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(call["isError"]?.boolValue == false && text.contains("\"state\":\"succeeded\"") && text.contains("\"platform\":\"fake\""))
        // the daemon's own validation comes back as an error result, not a transport failure
        let missingKey = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"message.send","arguments":{"target":"文件传输助手","text":"x"}}}"#))
        let reason = try #require(missingKey["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(missingKey["isError"]?.boolValue == true && reason.hasPrefix("INVALID_PARAMS: "))
        // direct protocol lines are forwarded too (same as `imctl call`)
        let direct = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"account.status","params":{}}"#))
        #expect(direct["state"]?.stringValue == "succeeded" && direct["method"]?.stringValue == "account.status")
        #expect(proxy.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#)?.contains("unknown tool") == true)
        #expect(proxy.handle(line: "   ") == nil && proxy.handle(line: "{nope")?.contains("parse error") == true)
    }

    @Test func aMissingDaemonIsReportedInsideTheToolResult() throws {
        let proxy = MCPProxy(client: UnixSocketClient(path: "/tmp/imctl-mcp-none/s.sock", timeout: 1))
        let call = try result(proxy.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"controller.describe","arguments":{}}}"#))
        let text = try #require(call["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(call["isError"]?.boolValue == true && text.hasPrefix("DAEMON_UNREACHABLE: ") && text.contains("imctl status"))
        let direct = try #require(proxy.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"account.status"}"#))
        #expect(direct.contains("\"error\"") && direct.contains("DAEMON_UNREACHABLE"))
    }
}

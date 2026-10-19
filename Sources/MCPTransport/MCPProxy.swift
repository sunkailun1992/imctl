import ControlCore
import Foundation

/// `imctl mcp serve` (B10): the MCP server a coding agent (Claude Code,
/// Codex) talks to over stdio. It owns nothing — every `tools/call` and every
/// direct protocol method is forwarded to the **running daemon's** Unix
/// socket, so there is one executor, one policy, one event log and one
/// idempotency store no matter how many clients (console, CLI, Java over
/// MQTT, agents) drive the client. The tool list is the daemon's own.
public final class MCPProxy: LineHandler {
    public let client: UnixSocketClient
    public let serverName: String
    public static let unreachableCode = "DAEMON_UNREACHABLE"

    public init(client: UnixSocketClient, serverName: String = "imctl") {
        self.client = client
        self.serverName = serverName
    }

    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request: JSONValue
        do { request = try JSONValue.parse(trimmed) } catch {
            return RPCDispatcher.errorResponse(id: .null, code: -32700, message: "parse error")
        }
        guard let obj = request.objectValue, let method = obj["method"]?.stringValue else {
            return RPCDispatcher.errorResponse(id: obj_id(request), code: -32600, message: "invalid request")
        }
        let id = obj["id"] ?? .null
        let isNotification = obj["id"] == nil
        let params = obj["params"]?.objectValue ?? [:]
        let response: JSONValue
        switch method {
        case "initialize":
            response = .object([
                "protocolVersion": .string(params["protocolVersion"]?.stringValue ?? "2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(IMCTLVersion.string)]),
                "instructions": .string("Tools are IM Control Protocol methods served by the local imctld. Sending needs an idempotencyKey (reusing it replays, never re-sends) and only reaches conversations allowed by the Mac's policy; reads are open unless gateReads is on."),
            ])
        case "notifications/initialized", "ping":
            if isNotification { return nil }
            response = .object([:])
        case "tools/list":
            response = .object(["tools": .array(RPCDispatcher.toolDescriptors())])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return RPCDispatcher.errorResponse(id: id, code: -32602, message: "unknown tool")
            }
            let args = params["arguments"]?.objectValue ?? [:]
            switch forward(name, args) {
            case .success(let result):
                let text = (try? result.serialized()) ?? "{}"
                let state = result.objectValue?["state"]?.stringValue
                response = .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                    "isError": .bool(state == "failed" || state == "expired")])
            case .failure(let failure):
                response = .object(["content": .array([.object(["type": .string("text"), "text": .string(failure.text)])]), "isError": .bool(true)])
            }
        default:
            if isNotification { return nil }
            switch forward(method, params) {
            case .success(let result):
                response = result
            case .failure(let failure):
                return RPCDispatcher.errorResponse(id: id, code: failure.code, message: failure.message, data: .object(["code": .string(failure.controlCode)]))
            }
        }
        if isNotification { return nil }
        return (try? JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": response]).serialized()) ?? "{}"
    }

    public struct Failure: Error, Equatable {
        public var code: Int
        public var controlCode: String
        public var message: String
        public var text: String { "\(controlCode): \(message)" }
    }

    /// One socket round trip; the daemon's JSON-RPC error and an unreachable socket both become a `Failure`.
    public func forward(_ method: String, _ params: [String: JSONValue]) -> Result<JSONValue, Failure> {
        do {
            return .success(try client.call(method, params: params))
        } catch let e as UnixSocketClient.RPCError {
            let code = e.data?.objectValue?["code"]?.stringValue ?? "RPC_ERROR"
            return .failure(Failure(code: e.code, controlCode: code, message: e.message))
        } catch {
            return .failure(Failure(code: -32001, controlCode: Self.unreachableCode,
                                    message: "imctld not reachable at \(client.path) (\(error)); check `imctl status` / `imctl agent status`"))
        }
    }

    private func obj_id(_ v: JSONValue) -> JSONValue { v.objectValue?["id"] ?? .null }
}

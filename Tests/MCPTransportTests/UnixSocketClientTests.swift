import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("UnixSocketClient", .serialized)
struct UnixSocketClientTests {
    func server() throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-c-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let s = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
        s.log = { _ in }
        try s.start()
        return (s, path)
    }

    @Test func roundTripsResultsAndErrors() throws {
        let (server, path) = try server()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let client = UnixSocketClient(path: path, timeout: 5)
        let describe = try client.call("controller.describe")
        #expect(describe.objectValue?["result"]?.objectValue?["platform"] == .string("fake"))
        let send = try client.call("message.send", params: ["target": .string("文件传输助手"), "text": .string("hi"), "idempotencyKey": .string("k1")])
        #expect(send.objectValue?["state"] == .string("succeeded"))
        let replay = try client.call("event.replay", params: ["afterEventId": .number(0)])
        #expect((replay.objectValue?["count"]?.numberValue ?? 0) >= 3)
        #expect(throws: UnixSocketClient.RPCError(code: -32601, message: "method not found", data: nil)) { try client.call("nope") }
        do {
            _ = try client.call("message.send", params: ["target": .string("x")])
            Issue.record("expected an error")
        } catch let e as UnixSocketClient.RPCError {
            #expect(e.code == -32000 && e.data?.objectValue?["code"] == .string("INVALID_PARAMS"))
        }
    }

    @Test func missingSocketIsAConnectError() {
        do {
            _ = try UnixSocketClient(path: "/tmp/imctl-none-\(UUID().uuidString.prefix(6)).sock", timeout: 1).call("ping")
            Issue.record("expected an error")
        } catch let e as UnixSocketClient.TransportError {
            if case .connect = e {} else { Issue.record("wrong error \(e)") }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

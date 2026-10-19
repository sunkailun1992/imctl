import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

/// Blocks the first readiness call until released, so one connection can hold its handler.
final class BlockingReadiness: ReadinessProviding, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first = true

    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); let block = first; first = false; lock.unlock()
        if block { entered.signal(); release.wait() }
        return ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: "done"), version: "t", generatedMs: 1)
    }
}

@Suite("Unix socket connections are independent")
struct SocketConcurrencyTests {
    /// B52 review C1: a slow request on one connection (a long command from the console or an agent)
    /// must not hold every other client, or `imctl doctor` times out and reports the daemon unreachable.
    @Test func oneSlowConnectionDoesNotHoldTheOthers() throws {
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let blocking = BlockingReadiness()
        dispatcher.readiness = blocking
        let path = "/tmp/imctl-sock-\(UUID().uuidString.prefix(8))/s.sock"
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        defer { blocking.release.signal(); server.stop() }
        DispatchQueue.global().async { _ = try? UnixSocketClient(path: path, timeout: 10).call("controller.readiness") }
        #expect(blocking.entered.wait(timeout: .now() + 5) == .success)
        let started = Date()
        let replay = try UnixSocketClient(path: path, timeout: 2).call("event.replay")
        #expect(replay.objectValue?["count"] != nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    /// A closed connection's cleanup must never reach a newer connection that reuses its fd number (C1 follow-up:
    /// the cleanup used to run late on the server queue, once per repeated EOF event, and could cancel the next one).
    @Test func shortConnectionsInARowAreAllAnswered() throws {
        let store = try ControlStore(path: ":memory:")
        let path = "/tmp/imctl-sock-\(UUID().uuidString.prefix(8))/s.sock"
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        defer { server.stop() }
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<250 {
                do { _ = try UnixSocketClient(path: path, timeout: 2).call("event.replay") } catch {
                    lock.lock(); failures += 1; lock.unlock()
                }
            }
        }
        #expect(failures == 0, "\(failures) of 2000 calls failed")
    }

    /// The last reference can drop inside a block on the server's own queue, so `stop()` (from deinit) runs there:
    /// it must not sync onto that queue (dispatch traps).
    @Test func stopOnTheServersOwnQueueDoesNotTrap() throws {
        let store = try ControlStore(path: ":memory:")
        let path = "/tmp/imctl-sock-\(UUID().uuidString.prefix(8))/s.sock"
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        server.queue.sync { server.stop() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Smoke test: servers released while a connection closes (the deterministic test is above).
    @Test func releasingTheServerWhileAConnectionClosesDoesNotTrap() throws {
        for _ in 0..<20 {
            let store = try ControlStore(path: ":memory:")
            let path = "/tmp/imctl-sock-\(UUID().uuidString.prefix(8))/s.sock"
            var server: UnixSocketServer? = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
            server?.log = { _ in }
            try server?.start()
            _ = try UnixSocketClient(path: path, timeout: 2).call("event.replay")
            server = nil
        }
    }
}

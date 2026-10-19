import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

final class FakeReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(online: Bool, refresh: Bool)] = []
    let report = ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                                 online: ReadinessOnlineInfo(state: "done", testedMs: 5), version: "t", generatedMs: 9)
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); calls.append((online, refresh)); lock.unlock()
        return report
    }
}

@Suite("controller.readiness is a dispatcher query")
struct DispatcherReadinessTests {
    func make() throws -> (RPCDispatcher, ControlStore, FakeReadiness) {
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let fake = FakeReadiness()
        dispatcher.readiness = fake
        return (dispatcher, store, fake)
    }

    @Test func directCallReturnsTheReportAndPassesTheFlags() throws {
        let (d, store, fake) = try make()
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness","params":{"online":false,"refresh":true}}"#))
        let result = try #require(try JSONValue.parse(line).objectValue?["result"]?.objectValue)
        #expect(result["ready"]?.boolValue == true && result["version"]?.stringValue == "t")
        #expect(result["commandId"] == nil)
        #expect(fake.calls.count == 1 && fake.calls[0].online == false && fake.calls[0].refresh == true)
        #expect(try store.events(after: 0, limit: 10).isEmpty)
    }

    @Test func defaultsAreOnlineWithoutRefresh() throws {
        let (d, _, fake) = try make()
        _ = d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#)
        #expect(fake.calls.first?.online == true && fake.calls.first?.refresh == false)
    }

    @Test func toolsCallAnswersWithTheReportText() throws {
        let (d, _, _) = try make()
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"controller.readiness","arguments":{}}}"#))
        let result = try #require(try JSONValue.parse(line).objectValue?["result"]?.objectValue)
        #expect(result["isError"]?.boolValue == false)
        let text = try #require(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(try JSONValue.parse(text).objectValue?["ready"]?.boolValue == true)
    }

    @Test func withoutAProviderItIsUnsupported() throws {
        let store = try ControlStore(path: ":memory:")
        let d = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#))
        #expect(line.contains("UNSUPPORTED"))
    }

    @Test func answersWhileTheExecutorIsBusy() throws {
        let (d, _, _) = try make()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { d.executor.serialized { entered.signal(); gate.wait() } }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        defer { gate.signal() }
        // Answered off this thread with a bound: a call queued behind the executor fails the test instead of hanging it.
        final class Box: @unchecked Sendable { var response: String? }
        let box = Box()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.response = d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#)
            answered.signal()
        }
        let result = answered.wait(timeout: .now() + 1)
        #expect(result == .success)
        if result == .success { #expect(box.response != nil) }
    }

    @Test func theToolIsListedWithItsParameters() throws {
        let tool = try #require(RPCDispatcher.toolDescriptors().first { $0.objectValue?["name"]?.stringValue == "controller.readiness" })
        let properties = try #require(tool.objectValue?["inputSchema"]?.objectValue?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["online", "refresh"])
    }

    /// Review I6: agents read this description; its list names every capability the report carries, in order.
    @Test func theToolDescriptionListsEveryCapability() throws {
        let tool = try #require(RPCDispatcher.toolDescriptors().first { $0.objectValue?["name"]?.stringValue == "controller.readiness" })
        let description = try #require(tool.objectValue?["description"]?.stringValue)
        let start = try #require(description.range(of: "per capability ("))
        let end = try #require(description[start.upperBound...].firstIndex(of: ")"))
        let ids = ReadinessEvaluator.evaluate(ReadinessFacts(version: "v"), online: [:], info: ReadinessOnlineInfo(state: "skipped"), nowMs: 0)
            .capabilities.map(\.id)
        #expect(description[start.upperBound..<end].components(separatedBy: ", ") == ids)
    }

    /// Review I3b: how a client reads what it got right before a restart.
    @Test func restartAnswersFollowTheErrorKind() {
        #expect(ReadinessRestartAnswer(error: UnixSocketClient.TransportError.connect("refused")) == .notRunning)
        #expect(ReadinessRestartAnswer(error: UnixSocketClient.TransportError.timeout) == .noAnswer)
        #expect(ReadinessRestartAnswer(error: UnixSocketClient.TransportError.closed) == .noAnswer)
        #expect(ReadinessRestartAnswer(error: UnixSocketClient.RPCError(code: -32601, message: "no method", data: nil)) == .oldDaemon)
        #expect(ReadinessRestartAnswer(error: UnixSocketClient.RPCError(code: -32603, message: "internal", data: nil)) == .noAnswer)
        let report = JSONValue.object(["ready": .bool(true), "capabilities": .array([]), "online": .object(["state": .string("skipped")]),
                                       "version": .string("v"), "generatedMs": .number(1), "runningCommands": .number(2)])
        #expect(ReadinessRestartAnswer.asking { report } == .report(runningCommands: 2))
        #expect(ReadinessRestartAnswer.asking { throw UnixSocketClient.TransportError.timeout } == .noAnswer)
    }
}

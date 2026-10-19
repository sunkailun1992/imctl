import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

final class ScriptedReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String]
    private(set) var calls: [(online: Bool, refresh: Bool)] = []
    init(states: [String]) { self.states = states }
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); defer { lock.unlock() }
        calls.append((online, refresh))
        let state = states.count > 1 ? states.removeFirst() : (states.first ?? "done")
        return ReadinessReport(ready: state == "done", nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: state), version: "t", generatedMs: 1)
    }
}

@Suite("Console readiness panel", .serialized)
@MainActor
struct ConsoleReadinessTests {
    func daemon(_ readiness: ReadinessProviding) throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: SwitchingFakeHandler()))
        dispatcher.readiness = readiness
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        return (server, path)
    }

    @Test func pollsWhileTheLiveTestsRun() async throws {
        let scripted = ScriptedReadiness(states: ["running", "running", "done"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.runReadiness(refresh: true, pollNanoseconds: 10_000_000)
        #expect(model.readiness?.online.state == "done" && !model.readinessRunning)
        #expect(scripted.calls.count == 3 && scripted.calls[0].refresh && !scripted.calls[1].refresh)
    }

    @Test func localOnlyAsksForNoLiveTests() async throws {
        let scripted = ScriptedReadiness(states: ["skipped"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.runReadiness(localOnly: true, pollNanoseconds: 10_000_000)
        #expect(scripted.calls.count == 1 && !scripted.calls[0].online)
    }

    @Test func periodicRefreshNeverRunsReadiness() async throws {
        let scripted = ScriptedReadiness(states: ["done"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.refresh()
        #expect(scripted.calls.isEmpty && model.readiness == nil)
    }

    @Test func headlinesAndSymbols() {
        let ready = ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                                    online: ReadinessOnlineInfo(state: "done"), version: "v", generatedMs: 1)
        #expect(ReadinessText.headline(ready) == "✔ 就绪")
        var broken = ready; broken.ready = false; broken.nextStep = ReadinessFix(text: "打开企业微信并登录")
        #expect(ReadinessText.headline(broken) == "✘ 未就绪 · 下一步：打开企业微信并登录")
        #expect(ReadinessText.symbol(.disabled) == "○")
    }
}

import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

/// Answers local readiness with a set number of running commands (nil = a B52 daemon).
final class BusyReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Int?
    init(running: Int?) { self.running = running }
    func set(_ value: Int?) { lock.lock(); running = value; lock.unlock() }
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); defer { lock.unlock() }
        return ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: "skipped"), version: "t", generatedMs: 1, runningCommands: running)
    }
}

/// Answers only after a second: a daemon too busy to answer in time.
final class SlowReadiness: ReadinessProviding, @unchecked Sendable {
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        Thread.sleep(forTimeInterval: 1)
        return ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: "skipped"), version: "t", generatedMs: 1, runningCommands: 0)
    }
}

/// Online answers carry a finished round, local ones do not — as the daemon's do.
final class OnlineAwareReadiness: ReadinessProviding, @unchecked Sendable {
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                        online: ReadinessOnlineInfo(state: online ? "done" : "skipped", testedMs: online ? 5 : nil),
                        version: "t", generatedMs: 1, runningCommands: 0)
    }
}

/// The server a test restarts on the same path.
final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UnixSocketServer?
    func set(_ server: UnixSocketServer?) { lock.lock(); value = server; lock.unlock() }
    func stop() { lock.lock(); let s = value; lock.unlock(); s?.stop() }
}

@Suite("Console readiness actions", .serialized)
@MainActor
struct ConsoleActionTests {
    func model(running: Int?) throws -> (ConsoleModel, UnixSocketServer, BusyReadiness) {
        let provider = BusyReadiness(running: running)
        let (model, server) = try model(provider: provider)
        return (model, server, provider)
    }

    func model(provider: ReadinessProviding) throws -> (ConsoleModel, UnixSocketServer) {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let server = try Self.server(path: path, provider: provider)
        let model = ConsoleModel()
        model.socketPathOverride = path
        return (model, server)
    }

    nonisolated static func server(path: String, provider: ReadinessProviding) throws -> UnixSocketServer {
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: try ControlStore(path: ":memory:"), handler: SwitchingFakeHandler()))
        dispatcher.readiness = provider
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        return server
    }

    @Test func navigationHappensAtOnceWithoutAsking() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.openSettings, target: "oss"))
        #expect(model.section == .settings && model.settingsPane == .oss && model.pendingAction == nil && performed.isEmpty)
        await model.requestAction(ReadinessAction(.openPolicy, target: "phones"))
        #expect(model.section == .policy)
    }

    @Test func anExecutingActionWaitsForConfirmation() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.openWeCom))
        #expect(model.pendingAction == ReadinessAction(.openWeCom) && performed.isEmpty)
        await model.confirmPendingAction()
        #expect(performed == [ReadinessAction(.openWeCom)] && model.pendingAction == nil)
    }

    @Test func cancellingRunsNothing() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.installSkills))
        model.cancelPendingAction()
        #expect(model.pendingAction == nil && performed.isEmpty)
    }

    @Test func aRestartIsRefusedWhileACommandRuns() async throws {
        let (model, server, _) = try model(running: 1)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.restartDaemon))
        #expect(model.pendingAction == nil && model.actionNotice == ReadinessActionText.busy && performed.isEmpty)
    }

    @Test func aCommandThatStartsBeforeConfirmationBlocksTheRestart() async throws {
        let (model, server, provider) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.reinstallDaemon))
        #expect(model.pendingAction != nil)
        provider.set(1)
        await model.confirmPendingAction()
        #expect(performed.isEmpty && model.actionNotice == ReadinessActionText.busy)
    }

    @Test func aReportWithoutRunningCommandsAllowsTheRestart() async throws {
        let (model, server, _) = try model(running: nil)
        defer { server.stop() }
        model.performOverride = { _ in }
        await model.requestAction(ReadinessAction(.restartDaemon))
        #expect(model.pendingAction == ReadinessAction(.restartDaemon))
    }

    @Test func anUnknownKindDoesNothing() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        await model.requestAction(ReadinessAction(kind: "somethingNew"))
        #expect(model.pendingAction == nil && model.actionNotice == nil)
    }

    /// Review C1: dismissing the dialog clears pendingAction — maybe before the 确认 button's work runs; the button
    /// passes the action the dialog showed.
    @Test func confirmingRunsTheActionTheDialogShowedAfterDismissalClearedIt() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.openWeCom))
        let shown = try #require(model.pendingAction)
        model.cancelPendingAction()  // the dialog's isPresented setter, on dismissal
        await model.confirm(shown)
        #expect(performed == [ReadinessAction(.openWeCom)])
    }

    /// Review I3b: no answer in time is not "nothing running" (the doctor fallback calls it busy).
    @Test func aRestartIsRefusedWhenTheDaemonDoesNotAnswer() async throws {
        let (model, server) = try model(provider: SlowReadiness())
        defer { server.stop() }
        model.restartCheckTimeout = 0.2
        await model.requestAction(ReadinessAction(.restartDaemon))
        #expect(model.pendingAction == nil && model.actionNotice == ReadinessActionText.noAnswer)
    }

    /// Review I3d: every console button that restarts the daemon goes through requestAction (confirmation, busy
    /// check); nothing outside the model calls its raw restart or install.
    @Test func onlyTheModelRestartsOrInstallsTheDaemonDirectly() throws {
        let console = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/imctl-console")
        let files = (FileManager.default.enumerator(at: console, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ConsoleModel.swift" }
        #expect(files.count > 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(".restartDaemon()") && !text.contains(".installDaemon()"), "\(file.lastPathComponent)")
        }
    }

    /// Review I5a: the console window and the wizard sheet both carry the dialog; only one answers at a time.
    @Test func oneDialogAnswersAtATime() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        await model.requestAction(ReadinessAction(.openWeCom))
        #expect(model.presentsConfirmation(inWizard: false) && !model.presentsConfirmation(inWizard: true))
        model.wizardPresented = true
        #expect(model.presentsConfirmation(inWizard: true) && !model.presentsConfirmation(inWizard: false))
        model.actionNotice = ReadinessActionText.busy
        #expect(model.presentsNotice(inWizard: true) && !model.presentsNotice(inWizard: false))
    }

    /// Review I5b: the wizard sheet covers the window, so a page change behind it would look like nothing happened.
    @Test func navigationFromTheWizardClosesItFirst() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        let name = "imctl-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        model.wizardDefaults = defaults
        model.wizardPresented = true
        await model.requestAction(ReadinessAction(.openPolicy, target: "phones"))
        #expect(!model.wizardPresented && model.section == .policy && SetupWizard.flagDone(defaults))
    }

    /// Review I4a: a confirmed retest keeps its online result; a local check after it would show 未实测.
    @Test func aRetestKeepsItsOnlineResult() async throws {
        let (model, server) = try model(provider: OnlineAwareReadiness())
        defer { server.stop() }
        await model.requestAction(ReadinessAction(.retest))
        await model.confirmPendingAction()
        #expect(model.readiness?.online.state == "done")
    }

    /// Review I4b: a check that cannot reach the daemon shows the fallback, not the last report's ✔.
    @Test func aFailedCheckShowsTheFallbackInsteadOfAnOldReport() async throws {
        let (model, server, _) = try model(running: 0)
        await model.runReadiness(localOnly: true, maxPolls: 0)
        #expect(model.readiness != nil)
        server.stop()
        await model.runReadiness(localOnly: true, maxPolls: 0)
        #expect(model.readiness == nil)
    }

    /// Review I4b: right after a restart the daemon needs a moment; the check waits for it instead of showing the
    /// fallback as if it were gone.
    @Test func afterARestartTheCheckWaitsForTheDaemonToAnswer() async throws {
        let provider = BusyReadiness(running: 0)
        let (model, server) = try model(provider: provider)
        let path = try #require(model.socketPathOverride)
        let box = ServerBox()
        box.set(server)
        defer { box.stop() }
        model.restartWaitNanoseconds = 100_000_000
        model.performOverride = { _ in
            box.stop()
            box.set(nil)
            Task.detached {
                try? await Task.sleep(nanoseconds: 300_000_000)
                box.set(try? Self.server(path: path, provider: provider))
            }
        }
        await model.requestAction(ReadinessAction(.restartDaemon))
        await model.confirmPendingAction()
        #expect(model.readiness != nil)
    }

    /// Live gate 2026-10-13: right after a bootout the fallback still said 后台常驻：已加载 and imctld：在运行 (pid …) —
    /// the launchd status from the last 60-second refresh. A failed check reads launchd again.
    @Test func aFailedCheckRereadsLaunchdForTheFallback() async {
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        model.agent = DaemonControl.AgentStatus(loaded: true, state: "running", pid: 17524, plistPresent: true)
        model.readAgentStatus = { DaemonControl.AgentStatus(loaded: false, state: nil, pid: nil, plistPresent: true) }
        await model.runReadiness(localOnly: true, maxPolls: 0)
        #expect(model.readiness == nil && model.agent?.loaded == false && model.agent?.pid == nil)
    }

    @Test func settingsPanesMapFromTargets() {
        #expect(SettingsPane(target: "mqtt") == .mqtt && SettingsPane(target: "proxy") == .proxy)
        #expect(SettingsPane(target: "oss") == .oss && SettingsPane(target: "vision") == .vision && SettingsPane(target: "x") == nil)
    }
}

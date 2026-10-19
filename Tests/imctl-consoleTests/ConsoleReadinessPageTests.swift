import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

/// A report that is not ready, with these capability statuses.
final class CapabilityReadiness: ReadinessProviding, @unchecked Sendable {
    let statuses: [String: ReadinessStatus]
    init(statuses: [String: ReadinessStatus]) { self.statuses = statuses }
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        ReadinessReport(ready: false, nextStep: nil, nextStepCapability: nil,
                        capabilities: statuses.map { ReadinessCapability(id: $0.key, title: $0.key, required: false, status: $0.value, checks: []) },
                        online: ReadinessOnlineInfo(state: "skipped"), version: "t", generatedMs: 1)
    }
}

@Suite("Console readiness page", .serialized)
@MainActor
struct ConsoleReadinessPageTests {
    func defaults() -> UserDefaults {
        let name = "imctl-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func theSidebarStartsWithReadinessAndHasNoDiagnosticsPage() {
        #expect(ConsoleSection.groups.first?.1 == [.readiness, .status])
        #expect(!ConsoleSection.allCases.map(\.rawValue).contains("诊断"))
    }

    /// Review I6: B53 removed 状态 › 授权与本机 (with 一次性初始化授权 and 检查授权) and the 体检 panel on 状态; nothing a
    /// person reads — CLI output, docs, the installer's pages — still sends them there.
    @Test func nothingPointsAtRemovedConsolePlaces() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for root in ["Sources", "docs/ops", "docs/protocol", "docs/agents", "packaging", "README.md", "AGENTS.md"].map({ repo.appendingPathComponent($0) }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                files += (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { ["swift", "md", "txt", "html", "command", "sh"].contains($0.pathExtension) }
            } else {
                files.append(root)
            }
        }
        #expect(files.count > 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for phrase in ["授权与本机", "一次性初始化授权", "检查授权", "状态页「体检」"] {
                #expect(!text.contains(phrase), "\(file.lastPathComponent): \(phrase)")
            }
        }
    }

    @Test func startupWithoutADaemonOpensTheWizard() async {
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        await model.startupReadiness(defaults: defaults())
        #expect(model.wizardPresented && model.readiness == nil)
    }

    @Test func afterTheWizardALaunchThatIsNotReadyOpensOnTheReadinessPage() async throws {
        let scripted = ScriptedReadiness(states: ["skipped"])
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: try ControlStore(path: ":memory:"), handler: SwitchingFakeHandler()))
        dispatcher.readiness = scripted
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        defer { server.stop() }
        let d = defaults()
        d.set(true, forKey: SetupWizard.flagKey)
        let model = ConsoleModel()
        model.socketPathOverride = path
        model.section = .status
        await model.startupReadiness(defaults: d)
        #expect(!model.wizardPresented && model.section == .readiness)
        #expect(scripted.calls.allSatisfy { !$0.online })
    }

    /// Review (minor, re-graded): the first automatic opening ticks configured features too, as reopening does.
    @Test func theFirstAutomaticOpeningTicksConfiguredFeatures() async throws {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let server = try ConsoleActionTests.server(path: path, provider: CapabilityReadiness(statuses: ["mqtt": .fail, "agents": .ok, "vision": .disabled]))
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.startupReadiness(defaults: defaults())
        #expect(model.wizardPresented && model.wizard.selected == [.mqtt, .agents])
    }

    @Test func clientLinesCoverTrustBuildAndPath() {
        let lines = ReadinessText.clientLines(consoleTrusted: false, consoleBuild: "270", daemonBuild: "269", cliLinked: false,
                                              cliPath: "/Apps/imctl.app/Contents/MacOS/imctl")
        #expect(lines[0].symbol == "✘" && lines[0].action == ReadinessAction(.openSystemSettings, target: "accessibility"))
        #expect(lines[1].text.contains("控制台是 build 270，守护进程在跑 build 269") && lines[1].action == ReadinessAction(.restartDaemon))
        // a new Mac may have no /usr/local/bin (the pkg creates it only for a system install)
        #expect(lines[2].copy == #"sudo mkdir -p /usr/local/bin && sudo ln -sf "/Apps/imctl.app/Contents/MacOS/imctl" /usr/local/bin/imctl"#)
        let fine = ReadinessText.clientLines(consoleTrusted: true, consoleBuild: "269", daemonBuild: "269", cliLinked: true, cliPath: "x")
        #expect(fine.allSatisfy { $0.symbol == "✔" && $0.action == nil })
    }

    @Test func fallbackLinesOfferSetup() {
        let lines = ReadinessText.fallbackLines(agent: DaemonControl.AgentStatus(loaded: false, state: nil, pid: nil, plistPresent: true), clientRunning: true)
        #expect(lines.contains("后台常驻：文件在但没加载") && lines.contains("imctld：没在运行") && lines.contains("企业微信：在运行"))
        #expect(ReadinessText.fallbackLines(agent: nil, clientRunning: false).contains("后台常驻：读不到状态"))
    }
}

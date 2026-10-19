import ControlCore
import Foundation
import MCPTransport
import Testing
@testable import imctl

@Suite("imctl doctor")
struct DoctorTests {
    static func report(_ state: String, ready: Bool = true, next: ReadinessFix? = nil) -> ReadinessReport {
        ReadinessReport(ready: ready, nextStep: next, nextStepCapability: next == nil ? nil : "read",
                        capabilities: [
                            ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: ready ? .ok : .fail,
                                                checks: [ReadinessCheck(id: "accessibility", status: ready ? .ok : .fail, detail: "d")],
                                                fix: next),
                            ReadinessCapability(id: "vision", title: "视觉兜底", required: false, status: .disabled,
                                                checks: [ReadinessCheck(id: "config", status: .disabled, detail: "未配置")],
                                                fix: ReadinessFix(text: "enable", command: "pbpaste | imctl vision set --provider qwen --secret-stdin")),
                        ],
                        online: ReadinessOnlineInfo(state: state), version: "v", generatedMs: 1)
    }

    static func json(_ r: ReadinessReport) throws -> JSONValue {
        try JSONValue.parse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self))
    }

    @Test func fetchPollsWhileRunningAndOnlyTheFirstCallRefreshes() throws {
        var answers = [Self.report("running"), Self.report("running"), Self.report("done")]
        var params: [[String: JSONValue]] = []
        var slept = 0
        let r = try Doctor.fetch(call: { method, p in
            #expect(method == "controller.readiness")
            params.append(p)
            return try Self.json(answers.removeFirst())
        }, sleep: { _ in slept += 1 }, online: true, refresh: true, wait: 45)
        #expect(r.online.state == "done" && slept == 2)
        #expect(params[0]["refresh"]?.boolValue == true && params[1]["refresh"]?.boolValue == false)
    }

    @Test func fetchGivesUpAfterTheWait() throws {
        var calls = 0
        let r = try Doctor.fetch(call: { _, _ in calls += 1; return try Self.json(Self.report("running")) },
                                 sleep: { _ in }, online: true, refresh: false, wait: 3)
        #expect(r.online.state == "running" && calls == 4)
    }

    @Test func renderLeadsWithTheVerdictAndTheNextStep() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        let ready = Doctor.render(Self.report("done"), cli: cli)
        #expect(ready.hasPrefix("✔ 就绪"))
        #expect(ready.contains("○ 视觉兜底（可选）") && ready.contains("$ pbpaste | \(cli) vision set"))
        let broken = Doctor.render(Self.report("done", ready: false, next: ReadinessFix(text: "授权辅助功能", command: "imctl setup")), cli: cli)
        #expect(broken.hasPrefix("✘ 未就绪。下一步：授权辅助功能") && broken.contains("$ \(cli) setup"))
        let unsure = Doctor.render(Self.report("done", ready: false), cli: "imctl")
        #expect(unsure.hasPrefix("? "))
        #expect(Doctor.render(Self.report("skipped"), cli: "imctl").contains("只做了本机检查"))
    }

    /// Review I1: say when the live tests ran, and when a refresh inside the 60 s floor reused that round.
    @Test func renderShowsWhenTheLiveTestsRanAndWhyARefreshWasNotRetested() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        var r = Self.report("done")
        r.online = ReadinessOnlineInfo(state: "done", testedMs: 3_723_000, nextRefreshAllowedMs: 3_780_000)
        let plain = Doctor.render(r, cli: "imctl", timeZone: utc)
        #expect(plain.contains("联网实测时间：01:02:03") && !plain.contains("沿用上一轮"))
        #expect(!Doctor.render(r, cli: "imctl", refreshAskedMs: 3_700_000, timeZone: utc).contains("沿用上一轮"))
        let throttled = Doctor.render(r, cli: "imctl", refreshAskedMs: 3_750_000, timeZone: utc)
        #expect(throttled.contains("60 秒内已实测过，这次沿用上一轮结果；01:03:00 后才能再重测"))
        r.online.state = "running"
        #expect(!Doctor.render(r, cli: "imctl", refreshAskedMs: 3_750_000, timeZone: utc).contains("联网实测时间"))
    }

    /// Live gate 2026-10-11: a LaunchAgent file that is present but not loaded is a problem, not a tick.
    @Test func anAgentFileThatIsNotLoadedIsNotTicked() {
        var f = Doctor.Fallback(appPresent: true, plistPresent: true, loaded: false, daemonPid: nil, clientRunning: true,
                                clientVersion: nil, reason: "unreachable")
        #expect(Doctor.renderFallback(f, cli: "imctl").contains("✘ 后台常驻 文件在但没加载"))
        f.loaded = true
        #expect(Doctor.renderFallback(f, cli: "imctl").contains("✔ 后台常驻 已加载"))
    }

    @Test func cliPathIsImctlOnlyWhenPathRunsThisBinary() {
        let me = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(Doctor.cliPath(environment: ["PATH": "/usr/bin:/usr/local/bin"], me: me, resolve: { $0 == "/usr/local/bin/imctl" ? me : nil }) == "imctl")
        #expect(Doctor.cliPath(environment: ["PATH": "/usr/bin"], me: me, resolve: { _ in nil }) == me)
        #expect(Doctor.cliPath(environment: ["PATH": "/opt/bin"], me: me, resolve: { $0 == "/opt/bin/imctl" ? "/old/imctl" : nil }) == me)
    }

    @Test func anOldDaemonIsReportedAsTooOld() {
        #expect(Doctor.fallbackReason(for: UnixSocketClient.RPCError(code: -32601, message: "method not found", data: nil)) == "tooOld")
        #expect(Doctor.fallbackReason(for: UnixSocketClient.TransportError.connect("refused")) == "unreachable")
        #expect(Doctor.fallbackReason(for: UnixSocketClient.RPCError(code: -32000, message: "x", data: nil)) == nil)
        let text = Doctor.renderFallback(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: 42,
                                               clientRunning: true, clientVersion: "5.0.11", reason: "tooOld"), cli: "imctl")
        #expect(text.contains("版本早于 B52") && text.contains("$ imctl setup"))
    }

    /// Review C1: a daemon that is alive but slow to answer (a long command) must not be told to restart.
    @Test func aTimeoutIsBusyAndNeverSuggestsARestart() {
        #expect(Doctor.fallbackReason(for: UnixSocketClient.TransportError.timeout) == "busy")
        let text = Doctor.renderFallback(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: 7,
                                               clientRunning: true, clientVersion: nil, reason: "busy"), cli: "imctl")
        #expect(text.contains("没有应答") && !text.contains("kickstart") && text.contains("$ imctl status"))
    }

    @Test func aPollThatTimesOutKeepsTheLastReport() throws {
        var calls = 0
        let r = try Doctor.fetch(call: { _, _ in
            calls += 1
            if calls == 1 { return try Self.json(Self.report("running")) }
            throw UnixSocketClient.TransportError.timeout
        }, sleep: { _ in }, online: true, refresh: false, wait: 45)
        #expect(r.online.state == "running" && calls == 2)
    }

    @Test func fallbackNextStepFollowsWhatIsMissing() {
        func next(_ f: Doctor.Fallback) -> String { Doctor.renderFallback(f, cli: "imctl") }
        #expect(next(.init(appPresent: true, plistPresent: false, loaded: false, daemonPid: nil, clientRunning: false, clientVersion: nil, reason: "unreachable")).contains("$ imctl setup"))
        #expect(next(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: nil, clientRunning: true, clientVersion: nil, reason: "unreachable")).contains("imctld.log"))
        #expect(next(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: 7, clientRunning: true, clientVersion: nil, reason: "unreachable")).contains("kickstart"))
    }

    @Test func defaultsAreOnlineWithAFortyFiveSecondWait() throws {
        let cmd = try DoctorCommand.parse([])
        #expect(!cmd.json && !cmd.offline && !cmd.refresh && cmd.wait == 45)
    }

    /// B52 deferred minors: --offline says so in the headline; "未实测" is not printed twice.
    @Test func anOfflineRunSaysSoAndUntestedIsNotRepeated() {
        var r = Self.report("skipped")
        r.capabilities[0].checks = [ReadinessCheck(id: "publish", status: .ok, detail: "未实测", tested: false)]
        let text = Doctor.render(r, cli: "imctl")
        #expect(text.hasPrefix("✔ 就绪：必需项都可用（只做了本机检查）"))
        #expect(!text.contains("未实测（未实测）"))
    }

    @Test func aFixIsShownForWarningsToo() {
        let health = ReadinessCapability(id: "health", title: "运行健康", required: false, status: .ok, checks: [],
                                         fix: ReadinessFix(text: "看守护进程日志找原因", action: ReadinessAction(.openLogs)), warnings: ["最近一小时有 1 条命令失败"])
        #expect(Doctor.showsFix(health))
        var quiet = health; quiet.warnings = []
        #expect(!Doctor.showsFix(quiet))
    }

    @Test func theClientGroupComparesBuildsAndPath() {
        var r = Self.report("done"); r.build = "268"
        let text = Doctor.render(r, cli: "imctl", client: Doctor.ClientFacts(cliBuild: "269", onPath: false, cliPath: "/Apps/imctl.app/Contents/MacOS/imctl"))
        #expect(text.contains("本机客户端") && text.contains("命令行是 build 269，守护进程在跑 build 268"))
        // a new Mac may have no /usr/local/bin (the pkg creates it only for a system install)
        #expect(text.contains(#"sudo mkdir -p /usr/local/bin && sudo ln -sf "/Apps/imctl.app/Contents/MacOS/imctl" /usr/local/bin/imctl"#))
        let same = Doctor.render(r, cli: "imctl", client: Doctor.ClientFacts(cliBuild: "268", onPath: true, cliPath: "imctl"))
        #expect(same.contains("✔ 命令行与守护进程同为 build 268") && same.contains("✔ 终端里可以直接用 imctl"))
    }
}

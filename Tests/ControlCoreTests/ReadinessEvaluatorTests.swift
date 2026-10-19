import Foundation
import Testing
@testable import ControlCore

@Suite("ReadinessEvaluator")
struct ReadinessEvaluatorTests {
    static let done = ReadinessOnlineInfo(state: "done", testedMs: 1_000)

    static func healthy() -> ReadinessFacts {
        ReadinessFacts(version: "1.0.15-dev",
                       watch: .init(lastPollAgeMs: 800, lastPollOK: true, clientAvailable: true, conversationCount: 7, railRead: true))
    }

    static func visionOn() -> ReadinessFacts.Vision {
        .init(config: .init(present: true, valid: true), cloudEnabled: true, keyPresent: true, provider: "qwen", model: "qwen3.7-plus", fullWindowEnabled: true)
    }

    func evaluate(_ f: ReadinessFacts, _ online: [ReadinessProbeKind: ReadinessProbeResult] = [:],
                  info: ReadinessOnlineInfo = Self.done) -> ReadinessReport {
        ReadinessEvaluator.evaluate(f, online: online, info: info, nowMs: 2_000)
    }

    func cap(_ r: ReadinessReport, _ id: String) throws -> ReadinessCapability {
        try #require(r.capabilities.first { $0.id == id })
    }

    @Test func capabilitiesComeInFixOrder() {
        #expect(evaluate(Self.healthy()).capabilities.map(\.id)
                == ["daemon", "wecom", "read", "send", "media", "contactAdd", "autoAccept", "vision", "mqtt", "oss", "agents", "wecomApi", "health"])
    }

    @Test func healthyCoreWithNothingOptionalIsReady() throws {
        let r = evaluate(Self.healthy())
        #expect(r.ready && r.nextStep == nil && r.nextStepCapability == nil && r.generatedMs == 2_000)
        // Adding by phone needs no setup since 2026-10-13 (user decision: no list of numbers).
        for id in ["daemon", "wecom", "read", "send", "media", "contactAdd"] { #expect(try cap(r, id).status == .ok) }
        for id in ["autoAccept", "vision", "mqtt", "oss", "agents", "wecomApi"] {
            let c = try cap(r, id)
            #expect(c.status == .disabled && !c.required && c.fix != nil)
        }
    }

    @Test func clientNotRunningFailsWecomAndLeavesDownstreamUnknown() throws {
        var f = Self.healthy(); f.clientRunning = false
        let r = evaluate(f)
        #expect(!r.ready && r.nextStepCapability == "wecom" && r.nextStep?.command == "open -b com.tencent.WeWorkMac")
        #expect(try cap(r, "read").status == .unknown)
        #expect(try cap(r, "send").status == .unknown)
    }

    @Test func missingAccessibilityPointsAtSetup() throws {
        var f = Self.healthy(); f.accessibilityTrusted = false
        let r = evaluate(f)
        #expect(try cap(r, "wecom").status == .unknown)
        #expect(try cap(r, "read").status == .fail)
        #expect(r.nextStepCapability == "read" && r.nextStep?.command == "imctl setup")
    }

    @Test func contactsPaneIsReachableWithAWarning() throws {
        var f = Self.healthy(); f.watch.lastPollOK = false; f.watch.clientAvailable = true
        let wecom = try cap(evaluate(f), "wecom")
        #expect(wecom.status == .ok && wecom.warnings.contains { $0.contains("「消息」") })
    }

    @Test func lostWindowFailsWecomButASystemPauseLeavesTheDaemonOK() throws {
        var f = Self.healthy(); f.watch.clientAvailable = false; f.pauseReasons = ["system"]
        let r = evaluate(f)
        #expect(try cap(r, "daemon").status == .ok)
        #expect(try cap(r, "wecom").status == .fail && r.nextStepCapability == "wecom")
    }

    @Test func aFreshDaemonIsNotReadyButHasNoNextStep() throws {
        var f = Self.healthy(); f.watch = .init()
        let r = evaluate(f)
        #expect(!r.ready && r.nextStep == nil)
        #expect(try cap(r, "wecom").status == .unknown)
    }

    @Test func anUncalibratedClientVersionOnlyWarns() throws {
        var f = Self.healthy(); f.clientVersion = "5.0.12"
        let wecom = try cap(evaluate(f), "wecom")
        #expect(wecom.status == .ok && wecom.warnings.contains { $0.contains("5.0.12") })
        f.clientVersion = nil
        #expect(try cap(evaluate(f), "wecom").status == .ok)
    }

    @Test func withoutFullDiskAccessMediaPointsAtThatPane() throws {
        var f = Self.healthy(); f.fullDiskAccess = false
        f.wecomData = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        let r = evaluate(f)
        let media = try cap(r, "media")
        #expect(media.status == .fail && media.fix?.command?.contains("Privacy_AllFiles") == true && !r.ready)
    }

    /// Live gate 2026-10-11: after a certificate change the old switches stay on but no longer apply, and the Screen
    /// Recording list may have no imctl row at all; each grant fix says what to do then.
    @Test func grantFixesCoverAStaleEntryAndAMissingRow() throws {
        var f = Self.healthy(); f.accessibilityTrusted = false
        #expect(try cap(evaluate(f), "read").fix?.text.contains("旧条目") == true)
        f = Self.healthy(); f.screenRecordingGranted = false
        let screen = try #require(try cap(evaluate(f), "media").fix?.text)
        #expect(screen.contains("从访达") && screen.contains("旧条目"))
        f = Self.healthy(); f.fullDiskAccess = false
        f.wecomData = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        #expect(try cap(evaluate(f), "media").fix?.text.contains("旧条目") == true)
    }

    @Test func screenRecordingIsFixedBeforeClientData() throws {
        var f = Self.healthy(); f.screenRecordingGranted = false; f.wecomData = "denied"
        #expect(try cap(evaluate(f), "media").fix?.command?.contains("Privacy_ScreenCapture") == true)
    }

    @Test func manualPauseAndManualRunFailTheDaemon() {
        var f = Self.healthy(); f.pauseReasons = ["api"]
        #expect(evaluate(f).nextStep?.command == "imctl call controller.resume")
        f.pauseReasons = []; f.launchedByLaunchd = false
        #expect(evaluate(f).nextStep?.command == "imctl setup")
    }

    @Test func allowAllAndAnUnreadablePolicyOnlyWarn() throws {
        var f = Self.healthy(); f.policy.allowAll = true; f.policy.readable = false
        let send = try cap(evaluate(f), "send")
        #expect(send.status == .ok && send.warnings.count == 2)
    }

    /// User decision 2026-10-13: adding by phone needs no list of numbers; the hourly caps are what is shown.
    @Test func contactAddNeedsNoPhoneList() throws {
        let c = try cap(evaluate(Self.healthy()), "contactAdd")
        #expect(c.status == .ok && c.fix == nil && c.checks.first?.detail == "号码不限，每小时最多添加 20 次、搜索 60 次")
    }

    /// A policy file that does not parse, or both caps at 0, turn adding by phone off — never the default caps.
    @Test func contactAddIsOffWhileThePolicyIsUnreadableOrBothCapsAreZero() throws {
        var f = Self.healthy(); f.policy.readable = false
        #expect(try cap(evaluate(f), "contactAdd").status == .disabled)
        f = Self.healthy(); f.policy.maxAddsPerHour = 0; f.policy.maxSearchesPerHour = 0
        let off = try cap(evaluate(f), "contactAdd")
        #expect(off.status == .disabled && off.fix?.command?.contains("--max-per-hour") == true)
        f = Self.healthy(); f.policy.maxAddsPerHour = 0
        #expect(try cap(evaluate(f), "contactAdd").status == .ok)
    }

    @Test func autoAcceptWithAnUnattributedRailFails() throws {
        var f = Self.healthy(); f.policy.autoAccept = "all"; f.watch.railProblem = "通讯录 pair at rail slot 1, expected 9"
        let r = evaluate(f)
        let auto = try cap(r, "autoAccept")
        #expect(auto.status == .fail && auto.fix?.command == "imctl probe rail" && !r.ready)
        f.watch.railProblem = nil
        #expect(try cap(evaluate(f), "autoAccept").status == .ok)
    }

    @Test func visionUsesTheLiveResultOnlyWhenDone() throws {
        var f = Self.healthy(); f.vision = Self.visionOn()
        #expect(try cap(evaluate(f, [.vision: .success(latencyMs: 900)]), "vision").status == .ok)
        let failed = try cap(evaluate(f, [.vision: .failure("http", latencyMs: 300)]), "vision")
        #expect(failed.status == .fail && failed.fix?.command?.contains("vision set") == true)
        let running = try cap(evaluate(f, [.vision: .failure("http", latencyMs: 300)], info: .init(state: "running")), "vision")
        #expect(running.status == .ok && running.checks.last?.tested == false)
    }

    @Test func visionWithoutAKeyOrScreenRecordingFails() throws {
        var f = Self.healthy(); f.vision = Self.visionOn(); f.vision.keyPresent = false
        #expect(try cap(evaluate(f), "vision").fix?.command == "pbpaste | imctl vision set --provider qwen --secret-stdin")
        f.vision.keyPresent = true; f.screenRecordingGranted = false
        #expect(try cap(evaluate(f), "vision").fix?.command?.contains("Privacy_ScreenCapture") == true)
    }

    /// B52 addendum: the controller id defaults to the host name, so enrolling needs only the broker.
    @Test func unconfiguredMQTTAsksOnlyForTheBroker() throws {
        let mqtt = try cap(evaluate(Self.healthy()), "mqtt")
        #expect(mqtt.fix?.command == "imctl enroll --broker <主机[:端口]>")
        #expect(mqtt.fix?.text.contains("默认取本机名") == true)
    }

    /// Review I1: an unreadable mqtt.json is re-enrolled with the id the Java side already uses, never a new default.
    @Test func anUnreadableMQTTConfigAsksForTheOriginalID() throws {
        var f = Self.healthy(); f.mqtt = .init(config: .init(present: true, valid: false))
        let fix = try #require(try cap(evaluate(f), "mqtt").fix)
        #expect(fix.command == "imctl enroll --broker <主机[:端口]> --controller-id <原来的 id>")
        #expect(fix.text.contains("原来的 controller id"))
    }

    @Test func mqttNeedsTheDaemonInMQTTModeAndAConnection() throws {
        var f = Self.healthy(); f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: false, connected: false)
        #expect(try cap(evaluate(f), "mqtt").fix?.command == "imctl agent install --mqtt")
        f.mqtt.daemonMode = true
        #expect(try cap(evaluate(f), "mqtt").status == .fail)
        f.mqtt.connected = true
        #expect(try cap(evaluate(f, [.mqtt: .success(latencyMs: 20)]), "mqtt").status == .ok)
        let rejected = try cap(evaluate(f, [.mqtt: .failure("rejected", latencyMs: 20)]), "mqtt")
        #expect(rejected.status == .fail && rejected.fix?.text.contains("授权") == true)
    }

    @Test func agentsCheckEachRegisteredSideOnly() throws {
        var f = Self.healthy()
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), codex: .init(), cliPresent: true)
        let ok = try cap(evaluate(f, [.agents: .success(latencyMs: 80)]), "agents")
        #expect(ok.status == .ok && ok.warnings.contains { $0.contains("Codex") })
        f.agents.claude.skill = .stale
        #expect(try cap(evaluate(f), "agents").fix?.command == "imctl mcp install --skills")
        f.agents.claude.skill = .current; f.agents.claude.commandMatches = false
        #expect(try cap(evaluate(f), "agents").fix?.command == "imctl mcp install --claude-code --skills")
    }

    @Test func ossAndProxyFollowTheirLiveTests() throws {
        var f = Self.healthy(); f.oss = .init(present: true, valid: true); f.wecomApi = .init(present: true, valid: true)
        let r = evaluate(f, [.oss: .failure("auth", latencyMs: 50), .wecomApi: .success(latencyMs: 40)])
        #expect(try cap(r, "oss").status == .fail)
        #expect(try cap(r, "wecomApi").status == .ok)
        f.oss.valid = false
        #expect(try cap(evaluate(f), "oss").checks.first?.detail.contains("oss.json") == true)
    }

    /// Review I2: a settings file written after the daemon started is valid on disk but not loaded.
    @Test func aModuleConfiguredAfterStartFailsUntilTheDaemonRestarts() throws {
        var f = Self.healthy()
        f.oss = .init(present: true, valid: true, loaded: false)
        f.wecomApi = .init(present: true, valid: true, loaded: false)
        let r = evaluate(f, [.oss: .success(latencyMs: 5), .wecomApi: .success(latencyMs: 5)])
        for id in ["oss", "wecomApi"] {
            let c = try cap(r, id)
            #expect(c.status == .fail && c.fix?.command?.contains("kickstart") == true)
        }
        f.oss.loaded = true; f.wecomApi.loaded = true
        let loaded = evaluate(f, [.oss: .success(latencyMs: 5), .wecomApi: .success(latencyMs: 5)])
        #expect(try cap(loaded, "oss").status == .ok)
        #expect(try cap(loaded, "wecomApi").status == .ok)
    }

    @Test func visionEnabledAfterStartOnlyWarns() throws {
        var f = Self.healthy(); f.vision = Self.visionOn(); f.vision.loadedAtStart = false
        let vision = try cap(evaluate(f, [.vision: .success(latencyMs: 5)]), "vision")
        #expect(vision.status == .ok && vision.warnings.contains { $0.contains("重启") })
    }

    @Test func categoriesHaveChineseLabels() {
        #expect(ReadinessEvaluator.categoryLabel("timeout") == "超时")
        #expect(ReadinessEvaluator.categoryLabel("brand-new") == "brand-new")
        #expect(ReadinessEvaluator.categoryLabel(nil) == "未知")
    }

    func action(_ r: ReadinessReport, _ id: String) throws -> ReadinessAction? { try cap(r, id).fix?.action }

    @Test func aBuildTheDaemonIsNotRunningFailsItWithARestart() throws {
        var f = Self.healthy(); f.runningBuild = "268"; f.installedBuild = "269"
        let daemon = try cap(evaluate(f), "daemon")
        #expect(daemon.status == .fail && daemon.fix?.action == ReadinessAction(.restartDaemon))
        #expect(daemon.checks.contains { $0.id == "build" && $0.status == .fail && $0.detail.contains("268") && $0.detail.contains("269") })
        f.installedBuild = "268"
        #expect(try cap(evaluate(f), "daemon").checks.contains { $0.id == "build" && $0.status == .ok })
        f.runningBuild = nil; f.installedBuild = nil
        #expect(try !cap(evaluate(f), "daemon").checks.contains { $0.id == "build" })
    }

    /// B52 deferred minor: a manually run daemon must be stopped before `setup` installs the agent.
    @Test func aManualRunSaysToStopItFirst() throws {
        var f = Self.healthy(); f.launchedByLaunchd = false
        let fix = try #require(try cap(evaluate(f), "daemon").fix)
        #expect(fix.text.contains("先停掉手动运行的那个") && fix.action == ReadinessAction(.setup))
    }

    @Test func everyFixCarriesTheAgreedAction() throws {
        var f = Self.healthy(); f.pauseReasons = ["api"]
        #expect(try action(evaluate(f), "daemon") == ReadinessAction(.resumeDaemon))
        f = Self.healthy(); f.pauseReasons = ["local_guard"]
        #expect(try action(evaluate(f), "daemon") == ReadinessAction(.openLogs))
        f = Self.healthy(); f.clientRunning = false
        #expect(try action(evaluate(f), "wecom") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.watch.clientAvailable = false
        #expect(try action(evaluate(f), "wecom") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.accessibilityTrusted = false
        #expect(try action(evaluate(f), "read") == ReadinessAction(.setup))
        f = Self.healthy(); f.screenRecordingGranted = false
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openSystemSettings, target: "screenRecording"))
        f = Self.healthy(); f.wecomData = "absent"
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.wecomData = "pending"
        #expect(try action(evaluate(f), "media") == nil)
        f = Self.healthy(); f.fullDiskAccess = false; f.wecomData = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openSystemSettings, target: "fullDiskAccess"))
        f = Self.healthy()
        #expect(try action(evaluate(f), "contactAdd") == nil)
        #expect(try action(evaluate(f), "autoAccept") == ReadinessAction(.openPolicy, target: "autoAccept"))
        f.policy.autoAccept = "all"; f.watch.railProblem = "slot"
        #expect(try action(evaluate(f), "autoAccept") == nil)
        f = Self.healthy()
        #expect(try action(evaluate(f), "vision") == ReadinessAction(.openSettings, target: "vision"))
        f.vision = Self.visionOn(); f.vision.keyPresent = false
        #expect(try action(evaluate(f), "vision") == ReadinessAction(.openSettings, target: "vision"))
        f.vision = Self.visionOn()
        #expect(try action(evaluate(f, [.vision: .failure("auth", latencyMs: 9)]), "vision") == ReadinessAction(.openSettings, target: "vision"))
        #expect(try action(evaluate(f, [.vision: .failure("timeout", latencyMs: 9)]), "vision") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt = .init(config: .init(present: true, valid: false))
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: false, connected: false)
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.reinstallDaemon))
        f.mqtt.daemonMode = true
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt.connected = true
        #expect(try action(evaluate(f, [.mqtt: .failure("rejected", latencyMs: 9)]), "mqtt") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "oss") == ReadinessAction(.openSettings, target: "oss"))
        f.oss = .init(present: true, valid: true, loaded: false)
        #expect(try action(evaluate(f), "oss") == ReadinessAction(.restartDaemon))
        f.oss = .init(present: true, valid: true)
        #expect(try action(evaluate(f, [.oss: .failure("auth", latencyMs: 9)]), "oss") == ReadinessAction(.openSettings, target: "oss"))
        #expect(try action(evaluate(f, [.oss: .failure("cleanup", latencyMs: 9)]), "oss") == nil)
        f = Self.healthy()
        #expect(try action(evaluate(f), "agents") == ReadinessAction(.registerAgents))
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .stale), cliPresent: true)
        #expect(try action(evaluate(f), "agents") == ReadinessAction(.installSkills))
        f.agents = .init(claude: .init(registered: true, commandMatches: false, skill: .current), cliPresent: true)
        #expect(try action(evaluate(f), "agents") == nil)
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), cliPresent: true)
        #expect(try action(evaluate(f, [.agents: .failure("launch", latencyMs: 9)]), "agents") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "wecomApi") == ReadinessAction(.openSettings, target: "proxy"))
        f.wecomApi = .init(present: true, valid: true, loaded: false)
        #expect(try action(evaluate(f), "wecomApi") == ReadinessAction(.restartDaemon))
        f.wecomApi = .init(present: true, valid: true)
        #expect(try action(evaluate(f, [.wecomApi: .failure("network", latencyMs: 9)]), "wecomApi") == ReadinessAction(.retest))
    }

    @Test func runtimeHealthWarnsWithoutBlockingReady() throws {
        var f = Self.healthy(); f.health = .init(failedLastHour: 2, unknownLastHour: 1); f.watch.errorsLastHour = 4
        let r = evaluate(f)
        let health = try cap(r, "health")
        #expect(health.status == .ok && !health.required && health.warnings.count == 3)
        #expect(health.fix?.action == ReadinessAction(.openLogs) && r.ready)
        #expect(try cap(evaluate(Self.healthy()), "health").fix == nil)
    }

    @Test func mqttShowsWhenTheLastCommandArrived() throws {
        var f = Self.healthy(); f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true, lastCommandMs: 2_000 - 180_000)
        #expect(try cap(evaluate(f), "mqtt").checks.contains { $0.id == "lastCommand" && $0.detail == "最近一次收到命令：3 分钟前" })
        f.mqtt.lastCommandMs = nil
        #expect(try cap(evaluate(f), "mqtt").checks.contains { $0.id == "lastCommand" && $0.detail == "守护进程启动后还没收到过命令" })
    }

    @Test func theReportCarriesTheBuildAndRunningCommands() {
        var f = Self.healthy(); f.runningBuild = "269"; f.installedBuild = "269"; f.runningCommands = 2
        let r = evaluate(f)
        #expect(r.build == "269" && r.runningCommands == 2)
    }
}

import ControlCore
import Foundation
import MQTTTransport
import OSSClient
import Testing
import WeComAPI
import WeComAdapter
@testable import imctld

@Suite("Daemon readiness", .serialized)
struct DaemonReadinessTests {
    static func sources(vision: ReadinessFacts.Vision = .init()) -> DaemonReadiness.Sources {
        DaemonReadiness.Sources(
            permissions: { ["accessibility": "trusted", "screenRecording": "granted", "wecomData": "granted",
                            "fullDiskAccess": "yes", "clientRunning": "true", "launchAgent": "true"] },
            watch: { _ in .init(lastPollAgeMs: 500, lastPollOK: true, clientAvailable: true, conversationCount: 3, railRead: true) },
            pauseReasons: { [] }, policy: { .init() }, clientVersion: { "5.0.11" }, vision: { vision },
            mqtt: { .init() }, oss: { .init() }, wecomApi: { .init() }, agents: { .init() })
    }

    static let visionOn = ReadinessFacts.Vision(config: .init(present: true, valid: true), cloudEnabled: true, keyPresent: true,
                                                provider: "qwen", model: "qwen3.7-plus")

    func waitUntilDone(_ readiness: DaemonReadiness) -> ReadinessReport? {
        for _ in 0..<40 {
            let r = readiness.readiness(online: true, refresh: false)
            if r.online.state == "done" { return r }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    @Test func offlineNeverRunsAProbe() {
        var calls = 0
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { calls += 1; return .success(latencyMs: 1) }))
        let report = readiness.readiness(online: false, refresh: false)
        #expect(report.online.state == "skipped" && report.ready && calls == 0)
    }

    @Test func answersImmediatelyWhileTheLiveTestsRun() throws {
        let gate = DispatchSemaphore(value: 0)
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { gate.wait(); return .success(latencyMs: 7) }))
        let started = Date()
        let first = readiness.readiness(online: true, refresh: false)
        #expect(first.online.state == "running" && Date().timeIntervalSince(started) < 0.5)
        gate.signal()
        let done = try #require(waitUntilDone(readiness))
        #expect(done.capabilities.first { $0.id == "vision" }?.checks.last?.tested == true)
    }

    @Test func concurrentCallersStartOneRound() throws {
        let lock = NSLock()
        var calls = 0
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { lock.lock(); calls += 1; lock.unlock(); Thread.sleep(forTimeInterval: 0.2); return .success(latencyMs: 200) }))
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = readiness.readiness(online: true, refresh: true) }
        _ = try #require(waitUntilDone(readiness))
        #expect(calls == 1)
    }

    @Test func aStuckProbeEndsTheRoundAtTheDeadline() throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { gate.wait(); return .success(latencyMs: 1) }))
        readiness.runner = { ReadinessProbeRunner.run($0, deadline: 0.2) }
        let done = try #require(waitUntilDone(readiness))
        let vision = try #require(done.capabilities.first { $0.id == "vision" })
        #expect(vision.status == .fail && vision.checks.last?.detail.contains("超时") == true)
    }

    @Test func onlyConfiguredModulesAreProbed() {
        let probes = DaemonReadiness.Probes(vision: { .success(latencyMs: 1) }, mqtt: { .success(latencyMs: 1) },
                                            oss: { .success(latencyMs: 1) }, agents: { .success(latencyMs: 1) },
                                            wecomApi: { .success(latencyMs: 1) })
        var f = ReadinessFacts(version: "v")
        #expect(DaemonReadiness.selected(probes, facts: f).isEmpty)
        f.vision = Self.visionOn
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true)
        f.oss = .init(present: true, valid: true)
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), cliPresent: true)
        f.wecomApi = .init(present: true, valid: true)
        #expect(Set(DaemonReadiness.selected(probes, facts: f).keys) == Set(ReadinessProbeKind.allCases))
        f.mqtt.connected = false
        #expect(DaemonReadiness.selected(probes, facts: f)[.mqtt] == nil)
    }

    /// Review I2: a module the running daemon did not load is reported, not live-tested.
    @Test func aModuleTheDaemonDidNotLoadIsNotProbed() throws {
        let probes = DaemonReadiness.Probes(oss: { .success(latencyMs: 1) }, wecomApi: { .success(latencyMs: 1) })
        var f = ReadinessFacts(version: "v")
        f.oss = .init(present: true, valid: true, loaded: false)
        f.wecomApi = .init(present: true, valid: true, loaded: false)
        #expect(DaemonReadiness.selected(probes, facts: f).isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-loaded-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: file)
        #expect(DaemonReadiness.configFacts(url: file, loaded: false) { _ in true } == ReadinessFacts.Config(present: true, valid: true, loaded: false))
    }

    /// Review I1: a finished round is not reused once a settings file changed (a new key, another endpoint).
    @Test func aChangedSettingsFileStartsANewRound() throws {
        let lock = NSLock()
        var calls = 0
        var stamp = "a"
        var sources = Self.sources(vision: Self.visionOn)
        sources.configStamp = { lock.lock(); defer { lock.unlock() }; return stamp }
        let readiness = DaemonReadiness(sources: sources,
                                        probes: .init(vision: { lock.lock(); calls += 1; lock.unlock(); return .success(latencyMs: 1) }))
        _ = try #require(waitUntilDone(readiness))
        #expect(readiness.readiness(online: true, refresh: false).online.state == "done")
        #expect(calls == 1)
        lock.lock(); stamp = "b"; lock.unlock()
        _ = try #require(waitUntilDone(readiness))
        #expect(calls == 2)
    }

    /// What decides and shapes the probes is in the fingerprint; the MQTT connection is not, so a flapping link
    /// never restarts rounds.
    @Test func theFingerprintCoversTheProbedSettingsButNotTheMQTTConnection() {
        var f = ReadinessFacts(version: "v")
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true)
        let base = DaemonReadiness.fingerprint(f, stamp: "s")
        f.mqtt.connected = false
        #expect(DaemonReadiness.fingerprint(f, stamp: "s") == base)
        #expect(DaemonReadiness.fingerprint(f, stamp: "t") != base)
        f.agents.claude.registered = true
        #expect(DaemonReadiness.fingerprint(f, stamp: "s") != base)
    }

    @Test func aRewrittenSettingsFileChangesTheStamp() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-stamp-\(UUID().uuidString).json")
        let absent = DaemonReadiness.stamp([file])
        try Data("{\"a\":1}".utf8).write(to: file)
        let first = DaemonReadiness.stamp([file])
        try Data("{\"a\":22}".utf8).write(to: file)
        #expect(absent != first && DaemonReadiness.stamp([file]) != first)
    }

    /// oss.json and wecom-proxy.json are read only at start: one edited since then is not the one in use.
    @Test func aSettingsFileEditedAfterTheDaemonLoadedItIsNotLoaded() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-edited-\(UUID().uuidString).json")
        try Data("{\"a\":1}".utf8).write(to: file)
        let atStart = DaemonReadiness.stamp([file])
        #expect(DaemonReadiness.loaded(true, stampAtStart: atStart, url: file))
        #expect(!DaemonReadiness.loaded(false, stampAtStart: atStart, url: file))
        try Data("{\"a\":22}".utf8).write(to: file)
        #expect(!DaemonReadiness.loaded(true, stampAtStart: atStart, url: file))
    }

    @Test func reportCarriesNoSecretsFromRealConfigFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-ready-\(UUID().uuidString)", isDirectory: true)
        let visionDir = dir.appendingPathComponent("vision", isDirectory: true)
        try FileManager.default.createDirectory(at: visionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var vision = CloudVisionSettings()
        try vision.setAPIKey("sk-B52-SECRET-VISION", for: .qwen)
        try vision.enable()
        try vision.save(to: visionDir.appendingPathComponent("cloud-vision.json"))
        try OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "secret-bucket-b52", baseDir: "imctl",
                        accessKeyId: "LTAIB52SECRETID", accessKeySecret: "B52-OSS-SECRET").save(to: dir.appendingPathComponent("oss.json"))
        try MQTTSettings(host: "broker-b52.example.invalid", controllerID: "mac-secret-b52", username: "b52-user", password: "B52-MQTT-SECRET")
            .save(to: dir.appendingPathComponent("mqtt.json"))
        try WeComProxySettings(baseURL: "https://proxy-b52.example.invalid", token: "B52-PROXY-TOKEN", corpId: "wwB52SECRETCORP")
            .save(to: dir.appendingPathComponent("wecom-proxy.json"))
        var policy = SendPolicy()
        policy.allowedTitles = ["真实客户群B52"]

        var sources = Self.sources()
        sources.vision = { DaemonReadiness.visionFacts(url: visionDir.appendingPathComponent("cloud-vision.json")) }
        sources.oss = { DaemonReadiness.configFacts(url: dir.appendingPathComponent("oss.json")) { try OSSSettings.load(from: $0) } }
        sources.mqtt = { DaemonReadiness.mqttFacts(url: dir.appendingPathComponent("mqtt.json"), link: nil) }
        sources.wecomApi = { DaemonReadiness.configFacts(url: dir.appendingPathComponent("wecom-proxy.json")) { try WeComProxySettings.load(from: $0) } }
        sources.policy = { DaemonReadiness.policyFacts(policy, readable: true) }
        let report = DaemonReadiness(sources: sources).readiness(online: false, refresh: false)
        #expect(report.capabilities.first { $0.id == "vision" }?.status == .ok)
        #expect(report.capabilities.first { $0.id == "mqtt" }?.status == .fail)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in ["sk-B52-SECRET-VISION", "secret-bucket-b52", "LTAIB52SECRETID", "B52-OSS-SECRET", "broker-b52.example.invalid",
                       "mac-secret-b52", "b52-user", "B52-MQTT-SECRET", "proxy-b52", "B52-PROXY-TOKEN", "wwB52SECRETCORP",
                       "真实客户群B52", "13800000000"] {
            #expect(!text.contains(secret), "leaked \(secret)")
        }
    }

    @Test func buildsAndCountsReachTheReport() throws {
        var sources = Self.sources()
        sources.builds = { ("268", "269") }
        sources.commands = { _ in (running: 2, failedLastHour: 1, unknownLastHour: 0) }
        let report = DaemonReadiness(sources: sources).readiness(online: false, refresh: false)
        #expect(report.build == "268" && report.runningCommands == 2)
        #expect(report.capabilities.first { $0.id == "daemon" }?.fix?.action == ReadinessAction(.restartDaemon))
        #expect(report.capabilities.first { $0.id == "health" }?.warnings.count == 1)
    }

    @Test func commandCountsComeFromTheStore() throws {
        let store = try ControlStore(path: ":memory:")
        var record = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 9_999_000)
        record.state = .failed; record.updatedMs = 9_999_000
        _ = try store.insertCommand(record)
        let counts = DaemonReadiness.commandCounts(store: store, nowMs: 10_000_000, startedMs: 0)
        #expect(counts.running == 0 && counts.failedLastHour == 1 && counts.unknownLastHour == 0)
    }

    /// Review I3a: rows an earlier process left accepted / running (killed mid-command; only running rows with a
    /// checkpoint are recovered) are not running now. Counting them would refuse every restart for good.
    @Test func onlyThisProcesssCommandsCountAsRunning() throws {
        let store = try ControlStore(path: ":memory:")
        for (key, state, ms) in [("a", CommandStateV1.accepted, Int64(1_000)), ("b", .running, 2_000), ("c", .running, 6_000)] {
            var record = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: key, nowMs: ms)
            record.state = state; record.updatedMs = ms
            _ = try store.insertCommand(record)
        }
        #expect(DaemonReadiness.commandCounts(store: store, nowMs: 10_000, startedMs: 5_000).running == 1)
    }

    /// Review C2: the last MQTT command time changes with every MQTT call; in the fingerprint it would start a
    /// paid round for every readiness call that arrives over MQTT.
    @Test func theLastMQTTCommandTimeIsNotInTheFingerprint() {
        var f = ReadinessFacts(version: "v")
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true, lastCommandMs: 1_000)
        let base = DaemonReadiness.fingerprint(f, stamp: "s")
        f.mqtt.lastCommandMs = 2_000
        #expect(DaemonReadiness.fingerprint(f, stamp: "s") == base)
    }
}

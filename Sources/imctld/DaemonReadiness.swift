import AXKit
import ControlCore
import Foundation
import MQTTTransport
import WeComAdapter

/// `controller.readiness` for this daemon (B52): facts from the daemon's own state, the evaluator's verdict,
/// and at most one background round of live tests at a time. Called on the socket / MQTT queue: everything
/// here returns quickly — no AX tree reads, no dialogs, no network on the caller's thread.
final class DaemonReadiness: ReadinessProviding, @unchecked Sendable {
    struct Sources {
        var permissions: () -> [String: String]
        var watch: (Int64) -> ReadinessFacts.Watch
        var pauseReasons: () -> [String]
        var policy: () -> ReadinessFacts.Policy
        var clientVersion: () -> String?
        var vision: () -> ReadinessFacts.Vision
        var mqtt: () -> ReadinessFacts.MQTT
        var oss: () -> ReadinessFacts.Config
        var wecomApi: () -> ReadinessFacts.Config
        var agents: () -> ReadinessFacts.Agents
        /// `stamp(_:)` of the settings files the probes read; a finished round is reused only while it is unchanged.
        var configStamp: () -> String = { "" }
        /// (running at start, installed on disk now).
        var builds: () -> (running: String?, installed: String?) = { (nil, nil) }
        var commands: (Int64) -> (running: Int, failedLastHour: Int, unknownLastHour: Int) = { _ in (0, 0, 0) }
    }

    struct Probes {
        var vision: (() -> ReadinessProbeResult)?
        var mqtt: (() -> ReadinessProbeResult)?
        var oss: (() -> ReadinessProbeResult)?
        var agents: (() -> ReadinessProbeResult)?
        var wecomApi: (() -> ReadinessProbeResult)?
        init(vision: (() -> ReadinessProbeResult)? = nil, mqtt: (() -> ReadinessProbeResult)? = nil,
             oss: (() -> ReadinessProbeResult)? = nil, agents: (() -> ReadinessProbeResult)? = nil,
             wecomApi: (() -> ReadinessProbeResult)? = nil) {
            self.vision = vision; self.mqtt = mqtt; self.oss = oss; self.agents = agents; self.wecomApi = wecomApi
        }
    }

    private let sources: Sources
    private let now: () -> Int64
    private let lock = NSLock()
    private var probesValue: Probes
    private var state = ReadinessOnlineState()
    private let queue = DispatchQueue(label: "com.sunkailun.imctl.readiness")
    /// Tests shorten the deadline.
    var runner: ([ReadinessProbeKind: () -> ReadinessProbeResult]) -> [ReadinessProbeKind: ReadinessProbeResult] = { ReadinessProbeRunner.run($0) }

    init(sources: Sources, probes: Probes = Probes(), now: @escaping () -> Int64 = Clock.nowMs) {
        self.sources = sources; self.probesValue = probes; self.now = now
    }

    /// main.swift adds the MQTT probe once the link exists.
    var probes: Probes {
        get { lock.lock(); defer { lock.unlock() }; return probesValue }
        set { lock.lock(); probesValue = newValue; lock.unlock() }
    }

    func facts(nowMs: Int64) -> ReadinessFacts {
        let p = sources.permissions()
        let builds = sources.builds()
        let counts = sources.commands(nowMs)
        return ReadinessFacts(
            version: IMCTLVersion.string,
            launchedByLaunchd: p["launchAgent"] == "true",
            pauseReasons: sources.pauseReasons(),
            accessibilityTrusted: p["accessibility"] == "trusted",
            screenRecordingGranted: p["screenRecording"] == "granted",
            wecomData: p["wecomData"] ?? "unknown",
            fullDiskAccess: p["fullDiskAccess"] == "yes",
            clientRunning: p["clientRunning"] == "true",
            clientVersion: sources.clientVersion(),
            watch: sources.watch(nowMs),
            policy: sources.policy(),
            vision: sources.vision(),
            mqtt: sources.mqtt(),
            oss: sources.oss(),
            agents: sources.agents(),
            wecomApi: sources.wecomApi(),
            runningBuild: builds.running, installedBuild: builds.installed, runningCommands: counts.running,
            health: .init(failedLastHour: counts.failedLastHour, unknownLastHour: counts.unknownLastHour))
    }

    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        let nowMs = now()
        let current = self.facts(nowMs: nowMs)
        let fingerprint = Self.fingerprint(current, stamp: sources.configStamp())
        lock.lock()
        let decision = state.request(online: online, refresh: refresh, nowMs: nowMs, fingerprint: fingerprint)
        let selected = decision == .start ? Self.selected(probesValue, facts: current) : [:]
        let run = runner
        lock.unlock()
        if decision == .start {
            queue.async { [self] in
                let results = run(selected)
                lock.lock(); state.finish(results, nowMs: now()); lock.unlock()
            }
        }
        lock.lock()
        let info = state.info(online: online, nowMs: nowMs)
        let results = state.results ?? [:]
        lock.unlock()
        return ReadinessEvaluator.evaluate(current, online: results, info: info, nowMs: nowMs)
    }

    /// Only modules that are configured and reachable get a live test.
    static func selected(_ probes: Probes, facts f: ReadinessFacts) -> [ReadinessProbeKind: () -> ReadinessProbeResult] {
        var out: [ReadinessProbeKind: () -> ReadinessProbeResult] = [:]
        if f.vision.config.valid, f.vision.cloudEnabled, f.vision.keyPresent, let p = probes.vision { out[.vision] = p }
        if f.mqtt.daemonMode, f.mqtt.connected, let p = probes.mqtt { out[.mqtt] = p }
        if f.oss.present, f.oss.valid, f.oss.loaded != false, let p = probes.oss { out[.oss] = p }
        if f.agents.claude.registered || f.agents.codex.registered, f.agents.cliPresent, let p = probes.agents { out[.agents] = p }
        if f.wecomApi.present, f.wecomApi.valid, f.wecomApi.loaded != false, let p = probes.wecomApi { out[.wecomApi] = p }
        return out
    }

    /// What a round of live tests depends on (review I1): the settings files on disk and the facts that pick and
    /// shape the probes. The MQTT connection is left out, so a flapping link never restarts a round, and so is the
    /// last MQTT command time (B53 review C2), which every readiness call over MQTT moves.
    static func fingerprint(_ f: ReadinessFacts, stamp: String) -> String {
        var mqtt = f.mqtt
        mqtt.connected = false
        mqtt.lastCommandMs = nil
        return "\(stamp)|\(f.vision)|\(mqtt)|\(f.oss)|\(f.agents)|\(f.wecomApi)"
    }

    /// Inode, modification time and size of each file ("-" when absent). Settings are saved atomically, so every
    /// save, even with the same size, gives a new inode.
    static func stamp(_ urls: [URL]) -> String {
        urls.map { url in
            var s = stat()
            guard stat(url.path, &s) == 0 else { return "-" }
            return "\(s.st_ino):\(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec):\(s.st_size)"
        }.joined(separator: ",")
    }

    /// oss.json and wecom-proxy.json are read only at start: the module is loaded when the daemon took the file then
    /// and the file on disk is still that one (an edit takes effect only after a restart).
    static func loaded(_ tookIt: Bool, stampAtStart: String, url: URL) -> Bool {
        tookIt && stamp([url]) == stampAtStart
    }

    // MARK: Live facts (counts and states only)

    static func policyFacts(_ p: SendPolicy, readable: Bool) -> ReadinessFacts.Policy {
        ReadinessFacts.Policy(readable: readable, titleCount: p.allowedTitles.count, typesEnabled: !p.allowedTypes.enabledNames.isEmpty,
                              chatIdCount: p.allowedChatIds.count, externalUserIdCount: p.allowedExternalUserIds.count,
                              allowAll: p.allowAll,
                              maxAddsPerHour: p.contactAdd.maxAddsPerHour, maxSearchesPerHour: p.contactAdd.maxSearchesPerHour,
                              autoAccept: p.contactRequests.autoAccept.rawValue)
    }

    static func clientVersion(bundleID: String) -> String? {
        AXApp.runningApplication(bundleID: bundleID)?.bundleURL.flatMap(Bundle.init(url:))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func visionFacts(url: URL, loadedAtStart: Bool? = nil) -> ReadinessFacts.Vision {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadinessFacts.Vision(loadedAtStart: loadedAtStart) }
        guard let s = try? CloudVisionSettings.load(from: url) else {
            return ReadinessFacts.Vision(config: .init(present: true, valid: false), loadedAtStart: loadedAtStart)
        }
        return ReadinessFacts.Vision(config: .init(present: true, valid: true), cloudEnabled: s.cloudEnabled, keyPresent: s.keyPresent,
                                     provider: s.provider.rawValue, model: s.model, fullWindowEnabled: s.fullWindowEnabled,
                                     loadedAtStart: loadedAtStart)
    }

    /// `running` counts only rows this process touched (B53 review I3a): a row an earlier process left accepted or
    /// running (killed mid-command; restart recovery only settles running rows with a checkpoint) is not running now.
    static func commandCounts(store: ControlStore, nowMs: Int64, startedMs: Int64) -> (running: Int, failedLastHour: Int, unknownLastHour: Int) {
        let hour = nowMs - 3_600_000
        return ((try? store.countCommands(states: [.accepted, .running], sinceMs: startedMs)) ?? 0,
                (try? store.countCommands(states: [.failed], sinceMs: hour)) ?? 0,
                (try? store.countCommands(states: [.unknown], sinceMs: hour)) ?? 0)
    }

    static func mqttFacts(url: URL, link: MQTTNIOLink?, lastCommandMs: Int64? = nil) -> ReadinessFacts.MQTT {
        let present = FileManager.default.fileExists(atPath: url.path)
        return ReadinessFacts.MQTT(config: .init(present: present, valid: present && (try? MQTTSettings.load(from: url)) != nil),
                                   daemonMode: link != nil, connected: link?.isConnected ?? false, lastCommandMs: lastCommandMs)
    }

    /// `loaded`: what the running daemon took at start (oss.json, wecom-proxy.json are read only then).
    static func configFacts(url: URL, loaded: Bool? = nil, load: (URL) throws -> Any) -> ReadinessFacts.Config {
        let present = FileManager.default.fileExists(atPath: url.path)
        return ReadinessFacts.Config(present: present, valid: present && (try? load(url)) != nil, loaded: loaded)
    }
}

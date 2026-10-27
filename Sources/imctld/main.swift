import ArgumentParser
import AXKit
import ControlCore
import Foundation
import MCPTransport
import MQTTTransport
import OSSClient
import WeComAPI
import WeComAdapter

struct Imctld: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imctld",
        abstract: "imctl daemon: executor + watcher (AX notifications + fallback polling) + transports (stdio JSON-RPC/MCP, Unix socket, MQTT).",
        version: IMCTLVersion.string,
        subcommands: [RunCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run the daemon in the foreground.")

    @Option(help: "SQLite path for commands/events.") var db: String = DaemonPaths.db.path
    @Option(help: "State file rewritten every few seconds.") var state: String = DaemonPaths.state.path
    @Flag(help: "Serve newline-delimited JSON-RPC (MCP compatible) on stdin/stdout.") var stdio = false
    @Option(help: "Serve newline-delimited JSON-RPC on this Unix socket path.") var socket: String?
    @Option(name: .customLong("watch-interval"), help: "Seconds between fallback client polls (0 disables the timer; AX notifications still poll).") var watchInterval: Double = 1.0
    @Flag(name: .customLong("no-observe"), help: "Do not subscribe to AX notifications; rely on the poll timer only.") var noObserve = false
    @Option(help: "Seconds to coalesce a burst of AX notifications before polling.") var debounce: Double = 0.15
    @Flag(name: .customLong("prompt-accessibility"), help: "If not trusted for Accessibility, ask macOS to show the grant dialog (adds this binary to the Accessibility list). Automatic under launchd (IMCTL_LAUNCHD=1).") var promptAccessibility = false
    @Option(name: .customLong("submit-timeout"), help: "Seconds to wait for the outbound bubble.") var submitTimeout: Double = 10
    @Option(help: "Client bundle identifier.") var bundle: String = WeComClient.bundleID
    @Flag(help: "Connect to the broker in mqtt.json (written by `imctl enroll`).") var mqtt = false
    @Option(name: .customLong("mqtt-config"), help: "MQTT settings file.") var mqttConfig: String = MQTTSettings.defaultURL.path
    @Option(name: .customLong("policy"), help: "Policy file widening the compiled allowlist (edit with `imctl policy`; hot-reloaded).") var policyFile: String = SendPolicy.defaultURL.path
    @Option(name: .customLong("wecom-config"), help: "WeCom proxy settings (imctl wecom enroll); when the file exists, group.*/contact.*/broadcast.* are served through the proxy.") var wecomConfig: String = WeComProxySettings.defaultURL.path
    @Option(name: .customLong("oss-config"), help: "OSS settings (imctl oss set); when the file exists, message.media uploads there and message.sendFile accepts ossKey.") var ossConfig: String = OSSSettings.defaultURL.path

    func run() throws {
        let log = DaemonLog()
        // B53: commands updated before this moment belong to an earlier process (readiness `runningCommands`).
        let startedMs = Clock.nowMs()
        let store = try ControlStore(path: db)
        let checkpoints = try FileCheckpointStore(directory: DaemonPaths.checkpoints)
        let policyProvider = PolicyProvider(url: URL(fileURLWithPath: policyFile))
        // B61: every AX call the handler and the watcher make is timed; outputs carry names and numbers only.
        let axTimings = AXCallTimings()
        let axReporter = AXTimingReporter(timings: axTimings, reportURL: DaemonPaths.axTimings, log: log.info)
        let liveBackend = LiveAXBackend()
        let backend = MeasuredAXBackend(base: liveBackend, timings: axTimings)
        backend.onSlowCall = axReporter.noteSlowCall
        axReporter.batchFallbacks = { liveBackend.batchFallbacks }
        axReporter.batchingDisabled = { liveBackend.batchingDisabled }
        liveBackend.onBatchingDisabled = {
            log.info("ax: batched reads switched off after \(liveBackend.batchFallbacks) fallbacks without a success; attributes are read on access")
        }
        let bundleID = bundle
        let handler = WeComCommandHandler(
            rootProvider: { try AXApp.byBundleID(bundleID, backend: backend) },
            policy: ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle],
                                 enabled: [.selectConversation, .composeText, .clearComposer, .scrollHistory, .submit, .confirmBroadcast, .navigate, .openContacts, .acceptRequest, .openGroupPicker, .createGroup, .renameGroup, .addContact, .sendFile, .addGroupMembers], phase: .phase1),
            checkpoints: checkpoints, strategy: .enterKey, submitTimeout: submitTimeout, identities: store
        )
        handler.sendPolicyProvider = { policyProvider.current() }
        handler.mediaIndex = MediaIndex(fileURL: IMCTLPaths.dataDirectory.appendingPathComponent("media-index.json"))
        handler.sentAttachmentSource = { try store.sentAttachmentSource(forMessageKey: $0) }
        // Cloud vision is loaded once at daemon startup. Routine MQTT reads and the watcher pay
        // no settings I/O or model cost; only an authorized ambiguous group-header action invokes it.
        let visionSettings = try? CloudVisionSettings.loadOrDefault()
        let visionConfigUnreadable = FileManager.default.fileExists(atPath: CloudVisionSettings.defaultURL.path)
            && visionSettings == nil
        handler.configureActions = { actions in
            actions.trace = { line in log.info(line) }
            if visionConfigUnreadable {
                actions.selectAddMembersHeaderButton = { _, _, _ in throw CloudVisionError.requestFailed }
            } else if visionSettings?.cloudEnabled == true {
                actions.selectAddMembersHeaderButton = { reader, candidates, expectedTitle in
                    // Re-read only on an explicit ambiguous action. A local disable/key deletion
                    // takes effect before the next upload without slowing MQTT reads or the watcher.
                    let current = try CloudVisionSettings.loadOrDefault()
                    return try CloudHeaderButtonTargeting.select(
                        reader: reader, candidates: candidates, expectedTitle: expectedTitle, settings: current
                    )
                }
            }
        }
        handler.visualEnabled = { (try? CloudVisionSettings.loadOrDefault().fullWindowEnabled) == true }
        handler.visualCommandGate = {
            let reasons = try store.pauseReasons()
            if !reasons.isEmpty { throw ControlError.paused(reasons) }
        }
        handler.visualRoundLog = log.info
        handler.visualSelect = { [weak handler] window, goal, kinds, expectedTitle, eligible, gate in
            guard let handler, let method = handler.desktopCommandMethod else {
                throw AIPlannerVisionError.disabled
            }
            var selector = AIPlannerRoundSelector(
                maxRounds: handler.maxVisualRounds,
                maxDuration: handler.maxVisualDuration,
                beforeRound: { try handler.beginVisualRound() }
            )
            selector.roundSink = { handler.noteVisualRound($0) }
            return try selector.select(window: window, method: method, goal: goal,
                                       allowedKinds: kinds, expectedTitle: expectedTitle,
                                       eligible: eligible, gate: gate)
        }
        if let visionSettings, visionSettings.cloudEnabled {
            log.info("cloud vision: enabled provider=\(visionSettings.provider.rawValue) model=\(visionSettings.model)")
        }
        log.info("policy: \(policyProvider.current().summary) (\(policyFile))")
        if let problem = policyProvider.lastError { log.info("WARNING: policy file unreadable, using the compiled allowlist only (contact.add is off until it parses): \(problem)") }
        let crash = ProcessInfo.processInfo.environment["IMCTL_CRASH_AFTER"] == "submit"
        let executor = CommandExecutor(store: store, handler: handler, crashAfterSubmit: crash)
        executor.acceptsPerHour = { policyProvider.current().contactRequests.maxAcceptsPerHour }
        executor.contactAddsPerHour = { policyProvider.contactAddCaps().adds }
        executor.contactSearchesPerHour = { policyProvider.contactAddCaps().searches }
        executor.log = log.info
        executor.policyEditor = FilePolicyEditor(provider: policyProvider)
        let logFile = IMCTLPaths.logDirectory.appendingPathComponent("imctld.log")
        executor.logReader = { lines in
            guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { throw ControlError.unsupported("no daemon log at \(logFile.lastPathComponent)") }
            return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
        }
        // B52: taken before each load, so readiness can tell a file edited since then (it needs a restart).
        let wecomStampAtStart = DaemonReadiness.stamp([URL(fileURLWithPath: wecomConfig)])
        if FileManager.default.fileExists(atPath: wecomConfig) {
            let proxy = try WeComProxySettings.load(from: URL(fileURLWithPath: wecomConfig))
            let api = WeComAPIHandler(client: WeComAPIClient(transport: URLSessionWeComTransport(settings: proxy)), identities: store)
            api.confirmBroadcast = { msgid in try handler.confirmBroadcast(msgid: msgid) }
            api.confirmBroadcastWithHooks = { msgid, checkpoint, afterSubmit in
                try handler.confirmBroadcast(msgid: msgid, checkpoint: checkpoint, afterSubmit: afterSubmit)
            }
            executor.apiHandler = api
            log.info("wecom api: enabled via proxy \(proxy.summary)")
        } else {
            log.info("wecom api: disabled (no \(wecomConfig)); group.*/contact.*/broadcast.* answer UNSUPPORTED")
        }
        handler.fileFetcher.sweep()
        // loadIfConfigured never throws: an invalid oss.json must leave OSS disabled, not exit imctld — this
        // runs under a KeepAlive LaunchAgent, so a thrown error here would crash-loop it.
        let ossStampAtStart = DaemonReadiness.stamp([URL(fileURLWithPath: ossConfig)])
        handler.objectStore = OSSObjectStore.loadIfConfigured(at: URL(fileURLWithPath: ossConfig), log: log.info)
        executor.ossEnabled = { handler.objectStore != nil }
        let recovered = try executor.recoverAfterRestart()
        for r in recovered { log.info("recovered command \(r.id) -> unknown (checkpoint without evidence)") }
        for cp in try checkpoints.pending() {
            var cp = cp; cp.state = .unknown; cp.reason = "pending at daemon start"; try checkpoints.write(cp)
        }
        if !backend.isProcessTrusted(prompt: false) {
            // Under launchd there is no trusted parent to inherit from: the daemon
            // itself must be listed. Ask once so the entry appears; a human enables it.
            if promptAccessibility || ProcessInfo.processInfo.environment["IMCTL_LAUNCHD"] == "1" {
                log.info("WARNING: not trusted for Accessibility; requesting the system prompt (enable imctld under System Settings › Privacy & Security › Accessibility)")
                _ = backend.isProcessTrusted(prompt: true)
            } else {
                log.info("WARNING: not trusted for Accessibility; commands will fail")
            }
        }

        let dispatcher = RPCDispatcher(executor: executor)
        // Servers and the watcher must outlive `run()`: they are driven by the
        // main run loop, so a local-only reference would be deallocated and the
        // socket would accept nothing.
        let daemon = DaemonRuntime(log: log)
        // B52: controller.readiness — facts from this daemon's own state, live tests in the background.
        let watchHealth = WatchHealth()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cli = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("imctl")
        let bundledSkill = Bundle.main.resourceURL.map { $0.appendingPathComponent(AgentPaths.skillRelativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let mqttURL = URL(fileURLWithPath: mqttConfig)
        let ossURL = URL(fileURLWithPath: ossConfig)
        let wecomURL = URL(fileURLWithPath: wecomConfig)
        let appURL = Bundle.main.bundleURL
        let runningBuild = ReadinessClient.bundleBuild(at: appURL)
        let readiness = DaemonReadiness(sources: DaemonReadiness.Sources(
            permissions: { (try? handler.permissions(prompt: false, probe: false)) ?? [:] },
            watch: { watchHealth.facts(nowMs: $0) },
            pauseReasons: { (try? store.pauseReasons().map(\.rawValue)) ?? [] },
            policy: { let s = policyProvider.snapshot(); return DaemonReadiness.policyFacts(s.policy, readable: s.readable) },
            clientVersion: { DaemonReadiness.clientVersion(bundleID: bundleID) },
            vision: { DaemonReadiness.visionFacts(url: CloudVisionSettings.defaultURL, loadedAtStart: visionSettings?.cloudEnabled == true) },
            mqtt: { DaemonReadiness.mqttFacts(url: mqttURL, link: daemon.mqttLink, lastCommandMs: daemon.mqttBinding?.lastCommandMs) },
            oss: { DaemonReadiness.configFacts(url: ossURL, loaded: DaemonReadiness.loaded(handler.objectStore != nil, stampAtStart: ossStampAtStart, url: ossURL)) { try OSSSettings.load(from: $0) } },
            wecomApi: { DaemonReadiness.configFacts(url: wecomURL, loaded: DaemonReadiness.loaded(executor.apiHandler != nil, stampAtStart: wecomStampAtStart, url: wecomURL)) { try WeComProxySettings.load(from: $0) } },
            agents: { AgentRegistrationInspector(home: home, cliPath: cli.path, bundledSkill: bundledSkill).inspect() },
            configStamp: { DaemonReadiness.stamp([CloudVisionSettings.defaultURL, mqttURL, ossURL, wecomURL]) },
            builds: { (runningBuild, ReadinessClient.bundleBuild(at: appURL)) },
            commands: { DaemonReadiness.commandCounts(store: store, nowMs: $0, startedMs: startedMs) }))
        readiness.probes = DaemonReadiness.Probes(
            vision: { (try? CloudVisionSettings.loadOrDefault()).map { ReadinessVisionProbe.probe(settings: $0) } ?? .failure("config", latencyMs: 0) },
            oss: { OSSRoundTrip.probe(settingsURL: ossURL) },
            agents: { MCPHandshakeProbe.run(executable: cli) },
            wecomApi: { WeComProxyHealth.probe(settingsURL: wecomURL) })
        dispatcher.readiness = readiness
        if let socket {
            let server = UnixSocketServer(dispatcher: dispatcher, path: socket)
            server.log = log.info
            try server.start()
            daemon.socketServer = server
            log.info("socket: listening on \(socket)")
        }
        if stdio {
            let server = StdioServer(dispatcher: dispatcher)
            server.log = log.info
            daemon.stdioServer = server
            Thread { server.serve(); log.info("stdio closed; exiting"); daemon.shutdown(exitCode: 0) }.start()
            log.info("stdio: serving JSON-RPC on stdin/stdout")
        }

        if mqtt {
            let settings = try MQTTSettings.load(from: URL(fileURLWithPath: mqttConfig))
            let link = MQTTNIOLink(settings: settings, log: log.info)
            let binding = MQTTBinding(settings: settings, dispatcher: dispatcher, store: store, link: link)
            link.start(binding: binding)
            daemon.mqttBinding = binding
            daemon.mqttLink = link
            readiness.probes.mqtt = { link.probePublish() }
            log.info("mqtt: enabled (\(settings.host):\(settings.port), controller \(settings.controllerID))")
        }

        let watcher = DaemonWatcher(store: store, bundleID: bundleID, backend: backend, interval: watchInterval,
                                    observe: !noObserve, debounce: debounce, policyProvider: policyProvider,
                                    statePath: URL(fileURLWithPath: state), log: log, health: watchHealth)
        watcher.socketPath = socket
        watcher.axReporter = axReporter
        watcher.mediaIndex = handler.mediaIndex
        watcher.automation = RequestAutomation(executor: executor, policyProvider: policyProvider, store: store, log: log)
        watcher.start()
        daemon.watcher = watcher
        daemon.statePath = URL(fileURLWithPath: state)
        daemon.installSignalHandlers()
        DaemonRuntime.shared = daemon
        log.info("imctld \(IMCTLVersion.string) running (db: \(db), observe: \(!noObserve), watchInterval: \(watchInterval), crashAfterSubmit: \(crash))")
        RunLoop.main.run()
    }
}

/// `policy.set` over the wire edits the same file `imctl policy` does, only after a human enabled it here.
final class FilePolicyEditor: PolicyEditing {
    let provider: PolicyProvider
    init(provider: PolicyProvider) { self.provider = provider }
    func current() throws -> SendPolicy { try SendPolicy.load(from: provider.url) }
    func apply(allow: [String], deny: [String], contactRequests: ContactRequestPolicy?, gateReads: Bool?, allowHosts: [String], denyHosts: [String]) throws -> SendPolicy {
        var policy = try SendPolicy.load(from: provider.url)
        guard policy.remoteEdits else {
            throw ControlError.localGuard("remote policy edits are off on this Mac; run `imctl policy remote --enable` here first")
        }
        for title in allow { policy.allow(.title(title)) }
        for title in deny { policy.deny(.title(title)) }
        if let r = contactRequests { policy.contactRequests = r }
        if let g = gateReads { policy.gateReads = g }
        for h in allowHosts { policy.sendFile.allow(h) }
        for h in denyHosts { policy.sendFile.deny(h) }
        try policy.save(to: provider.url)
        _ = provider.reloadIfChanged()
        return policy
    }
}

Imctld.main()

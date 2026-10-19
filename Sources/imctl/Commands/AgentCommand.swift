import ArgumentParser
import ControlCore
import Foundation
import MQTTTransport

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage the imctld LaunchAgent (login-session job that keeps the daemon running). Nothing is installed unless you run `agent install`.",
        subcommands: [AgentInstallCommand.self, AgentUninstallCommand.self, AgentStatusCommand.self]
    )
}

struct AgentInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Write ~/Library/LaunchAgents/<label>.plist and bootstrap it into the GUI session (RunAtLoad + restart on crash)."
    )

    @Option(help: "Path to imctld (default: next to this imctl binary; must be the signed build TCC already trusts).")
    var daemon: String = LaunchAgentSpec.defaultDaemonPath
    @Flag(help: "Pass --mqtt to imctld (requires the settings file written by `imctl enroll`).") var mqtt = false
    @Option(help: "Serve newline-delimited JSON-RPC on this Unix socket path (the console and `imctl call` use it).")
    var socket: String = IMCTLPaths.socket.path
    @Flag(name: .customLong("no-socket"), help: "Do not pass --socket to imctld.") var noSocket = false
    @Option(name: .customLong("watch-interval"), help: "Fallback poll interval passed to imctld.") var watchInterval: Double = 1.0
    @Flag(name: .customLong("no-observe"), help: "Pass --no-observe to imctld (poll only).") var noObserve = false
    @Option(help: "launchd label.") var label: String = LaunchAgentSpec.defaultLabel
    @Option(help: "Where to write the plist.") var plist: String = LaunchAgentSpec.defaultPlistPath().path
    @Option(name: .customLong("log-dir"), help: "Directory for imctld.log / imctld.out.log.") var logDir: String = LaunchAgentSpec.defaultLogDirectory.path
    @Option(name: .customLong("mqtt-config"), help: "MQTT settings file checked when --mqtt is given.") var mqttConfig: String = MQTTSettings.defaultURL.path
    @Flag(name: .customLong("dry-run"), help: "Print the plist; write nothing and call no launchctl.") var dryRun = false
    @Flag(name: .customLong("no-load"), help: "Write the plist but do not bootstrap it.") var noLoad = false

    func spec() -> LaunchAgentSpec {
        var arguments = ["run", "--watch-interval", String(watchInterval)]
        if mqtt { arguments.append("--mqtt") }
        if !noSocket { arguments += ["--socket", socket] }
        if noObserve { arguments.append("--no-observe") }
        return LaunchAgentSpec(label: label, daemonPath: daemon, arguments: arguments, logDirectory: logDir)
    }

    func render() throws -> String { try spec().plistXML() }

    func validate() throws {
        guard !dryRun else { return }
        guard FileManager.default.isExecutableFile(atPath: daemon) else {
            throw ValidationError("imctld is not an executable at \(daemon) (build with scripts/build-signed.sh or pass --daemon)")
        }
        if mqtt, !FileManager.default.fileExists(atPath: mqttConfig) {
            throw ValidationError("--mqtt needs \(mqttConfig); run `imctl enroll` first")
        }
    }

    func run() throws {
        let xml = try render()
        if dryRun {
            print(xml)
            FileHandle.standardError.write(Data("dry run: nothing written, launchctl not called\n".utf8))
            return
        }
        let plistURL = URL(fileURLWithPath: plist)
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: plistURL, options: .atomic)
        print("wrote \(plist)")
        if noLoad {
            print("not loaded (--no-load); load later with: launchctl bootstrap \(Launchctl.domain) \(plist)")
            return
        }
        _ = try? Launchctl.run(["bootout", Launchctl.serviceTarget(label)])
        // launchd tears the old job down asynchronously: a bootstrap issued right
        // after the bootout fails with "5: Input/output error" while the label is
        // still being removed (2026-09-15, from the console). Wait for the label
        // to disappear, retry a few times, and judge by the final state — launchd
        // has been seen loading the job even while printing that error.
        var teardownPolls = 0
        while teardownPolls < 10, Launchctl.isLoaded(label) { teardownPolls += 1; Launchctl.sleep(0.3) }
        var last = (status: Int32(1), output: "")
        for attempt in 0..<4 {
            if attempt > 0 { Launchctl.sleep(0.5) }
            last = try Launchctl.run(["bootstrap", Launchctl.domain, plist])
            if last.status == 0 || Launchctl.isLoaded(label) { last.status = 0; break }
        }
        guard last.status == 0 else {
            throw ValidationError("launchctl bootstrap failed (\(last.status)): \(last.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        print("loaded \(Launchctl.serviceTarget(label)); logs in \(logDir)")
    }
}

struct AgentUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Boot the job out of the GUI session and delete its plist.")

    @Option(help: "launchd label.") var label: String = LaunchAgentSpec.defaultLabel
    @Option(help: "Plist path to remove.") var plist: String = LaunchAgentSpec.defaultPlistPath().path

    func run() throws {
        let result = try Launchctl.run(["bootout", Launchctl.serviceTarget(label)])
        print(result.status == 0 ? "booted out \(Launchctl.serviceTarget(label))" : "not loaded: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        if FileManager.default.fileExists(atPath: plist) {
            try FileManager.default.removeItem(atPath: plist)
            print("removed \(plist)")
        } else {
            print("no plist at \(plist)")
        }
    }
}

struct AgentStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the LaunchAgent is installed and what launchd reports.")

    @Option(help: "launchd label.") var label: String = LaunchAgentSpec.defaultLabel
    @Option(help: "Plist path to check.") var plist: String = LaunchAgentSpec.defaultPlistPath().path
    @Flag var json = false

    func collect() throws -> [String: Any] {
        let result = try Launchctl.run(["print", Launchctl.serviceTarget(label)])
        let status = LaunchctlStatus.parse(result.output)
        var out: [String: Any] = [
            "label": label, "plist": plist, "plistPresent": FileManager.default.fileExists(atPath: plist),
            "loaded": status.loaded, "state": status.state ?? "", "pid": status.pid ?? 0, "lastExitCode": status.lastExitCode ?? "",
            "logDirectory": LaunchAgentSpec.defaultLogDirectory.path,
        ]
        if !status.loaded { out["launchctl"] = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    func run() throws {
        let out = try collect()
        if json {
            print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
        }
    }
}

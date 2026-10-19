import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("imctl agent (LaunchAgent)", .serialized)
struct AgentCommandTests {
    @Test func specRendersLaunchdKeys() throws {
        let spec = LaunchAgentSpec(daemonPath: "/x/imctld", arguments: ["run", "--mqtt", "--watch-interval", "1"], logDirectory: "/y/logs")
        let o = spec.plistObject()
        #expect(o["Label"] as? String == "com.sunkailun.imctl")
        #expect(o["ProgramArguments"] as? [String] == ["/x/imctld", "run", "--mqtt", "--watch-interval", "1"])
        #expect(o["RunAtLoad"] as? Bool == true)
        #expect((o["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(o["LimitLoadToSessionType"] as? String == "Aqua" && o["ProcessType"] as? String == "Interactive")
        #expect(o["StandardErrorPath"] as? String == "/y/logs/imctld.log" && o["StandardOutPath"] as? String == "/y/logs/imctld.out.log")
        let xml = try spec.plistXML()
        #expect(xml.contains("<key>ProgramArguments</key>") && xml.contains("<string>/x/imctld</string>"))
        #expect(LaunchAgentSpec.defaultPlistPath().path.hasSuffix("/Library/LaunchAgents/com.sunkailun.imctl.plist"))
        #expect(LaunchAgentSpec.defaultDaemonPath.hasSuffix("/imctld"))
    }

    @Test func installDryRunWritesNothingAndRunsNoLaunchctl() throws {
        var calls: [[String]] = []
        Launchctl.run = { args in calls.append(args); return (0, "") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-agent-\(UUID().uuidString)")
        let plist = dir.appendingPathComponent("a.plist").path
        let cmd = try AgentInstallCommand.parse(["--dry-run", "--daemon", "/usr/bin/true", "--plist", plist, "--log-dir", dir.path, "--socket", "/tmp/s.sock"])
        let xml = try cmd.render()
        #expect(xml.contains("--socket") && xml.contains("/tmp/s.sock") && !xml.contains("--mqtt") && xml.contains("--watch-interval"))
        try cmd.run()
        #expect(calls.isEmpty && !FileManager.default.fileExists(atPath: plist))
        let withMQTT = try AgentInstallCommand.parse(["--dry-run", "--mqtt", "--no-observe", "--daemon", "/usr/bin/true"])
        #expect(withMQTT.spec().arguments == ["run", "--watch-interval", "1.0", "--mqtt", "--socket", IMCTLPaths.socket.path, "--no-observe"])
        let noSocket = try AgentInstallCommand.parse(["--dry-run", "--no-socket", "--daemon", "/usr/bin/true"])
        #expect(noSocket.spec().arguments == ["run", "--watch-interval", "1.0"])
    }

    @Test func installRefusesMissingDaemonUnlessDryRun() throws {
        #expect(throws: (any Error).self) { try AgentInstallCommand.parse(["--daemon", "/nonexistent/imctld"]).validate() }
        #expect(throws: Never.self) { try AgentInstallCommand.parse(["--dry-run", "--daemon", "/nonexistent/imctld"]).validate() }
    }

    @Test func launchctlPrintIsParsed() {
        let s = LaunchctlStatus.parse("gui/501/com.sunkailun.imctl = {\n\tactive count = 1\n\tpath = /x.plist\n\tstate = running\n\n\tpid = 4242\n\tlast exit code = 0\n}")
        #expect(s.loaded && s.state == "running" && s.pid == 4242 && s.lastExitCode == "0")
        #expect(!LaunchctlStatus.parse("Could not find service \"com.sunkailun.imctl\" in domain for user gui: 501").loaded)
    }

    @Test func agentIsRegisteredWithThreeSubcommands() {
        let sub = AgentCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["install", "uninstall", "status"])
    }

    @Test func installWaitsForTeardownAndRetriesBootstrap() throws {
        var calls: [[String]] = []
        var printsLeft = 2          // the old job is still listed for two polls after bootout
        var bootstrapFailures = 1   // the first bootstrap hits launchd's I/O error
        Launchctl.sleep = { _ in }
        Launchctl.run = { args in
            calls.append(args)
            switch args[0] {
            case "bootout": return (0, "")
            case "print":
                if printsLeft > 0 { printsLeft -= 1; return (0, "gui/501/com.sunkailun.imctl = {\n\tstate = running\n\tpid = 1\n}") }
                return (113, "Could not find service")
            case "bootstrap":
                if bootstrapFailures > 0 { bootstrapFailures -= 1; return (5, "Bootstrap failed: 5: Input/output error") }
                return (0, "")
            default: return (1, "unexpected \(args)")
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-agent-retry-\(UUID().uuidString)")
        let cmd = try AgentInstallCommand.parse(["--daemon", "/usr/bin/true", "--plist", dir.appendingPathComponent("a.plist").path, "--log-dir", dir.path])
        try cmd.run()
        #expect(calls.filter { $0[0] == "bootstrap" }.count == 2 && calls.first?[0] == "bootout")
        #expect(calls.filter { $0[0] == "print" }.count >= 3)   // two teardown polls + at least one after the failed bootstrap
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.plist").path))
        try? FileManager.default.removeItem(at: dir)
    }
}

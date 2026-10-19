import ArgumentParser
import ControlCore
import Foundation
import MCPTransport
import MQTTTransport

/// B52: which features work on this Mac, why the others do not, and the command that fixes each.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Readiness report: which features work on this Mac, why the others do not, and the command that fixes each. Read-only; the live tests run in the daemon."
    )

    @Flag(help: "Print the readiness JSON.") var json = false
    @Flag(help: "Local checks only: no live tests.") var offline = false
    @Flag(help: "Retest instead of reusing the last round (at most once per 60 s).") var refresh = false
    @Option(help: "Seconds to wait for the live tests.") var wait: Double = 45
    @Option(help: "Unix socket served by imctld.") var socket: String = IMCTLPaths.socket.path
    @Flag(help: "After the report, offer each fix that has an action, one by one (y/N, default no). Terminal only.") var fix = false

    static func validateFix(isTerminal: Bool, json: Bool) throws {
        if json { throw ValidationError("--fix 不能和 --json 一起用") }
        if !isTerminal { throw ValidationError("--fix 需要在终端里逐项确认（stdin 不是终端）") }
    }

    func run() throws {
        if fix { try Self.validateFix(isTerminal: isatty(STDIN_FILENO) == 1, json: json) }
        let cli = Doctor.cliPath()
        let client = UnixSocketClient(path: socket, timeout: 15)
        let askedMs = Clock.nowMs()
        do {
            let report = try Doctor.fetch(call: { try client.call($0, params: $1) }, sleep: { Thread.sleep(forTimeInterval: $0) },
                                          online: !offline, refresh: refresh, wait: wait)
            let me = AgentIntegration.executable()
            let clientFacts = Doctor.ClientFacts(
                cliBuild: ReadinessClient.bundleBuild(at: URL(fileURLWithPath: me).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
                onPath: cli == "imctl", cliPath: me)
            print(try json ? Doctor.json(report) : Doctor.render(report, cli: cli, refreshAskedMs: refresh ? askedMs : nil, client: clientFacts))
            if fix {
                let fixer = DoctorFix(
                    cli: cli, mqttEnrolled: FileManager.default.fileExists(atPath: MQTTSettings.defaultURL.path),
                    ask: { prompt in print(prompt, terminator: ""); return readLine() }, say: { print($0) },
                    executor: DoctorFix.LiveExecutor(me: AgentIntegration.executable(), socket: socket),
                    localReport: {
                        try? Doctor.fetch(call: { try client.call($0, params: $1) }, sleep: { _ in }, online: false, refresh: false, wait: 0)
                    },
                    restartAnswer: {
                        ReadinessRestartAnswer.asking { try client.call(RPCDispatcher.readinessMethod, params: ["online": .bool(false)]) }
                    })
                fixer.run(report: report)
            }
            if !report.ready { throw ExitCode(2) }
        } catch let error where Doctor.fallbackReason(for: error) != nil {
            let fallback = Doctor.collectFallback(reason: Doctor.fallbackReason(for: error) ?? "unreachable")
            print(try json ? Doctor.json(fallback) : Doctor.renderFallback(fallback, cli: cli))
            throw ExitCode(3)
        }
    }
}

import ControlCore
import Foundation
import MCPTransport

/// `imctl doctor --fix` (B53): offer each failing capability's typed action in fix order and ask y/N (default no).
/// Daemon restarts are skipped while a command runs; navigation kinds only print their command; the fix's
/// command text is never executed.
/// What `--fix` actually does to this Mac; tests record the calls instead.
protocol DoctorFixExecutor {
    func open(url: URL) throws
    func openApp(bundleID: String) throws
    func runCLI(_ arguments: [String]) throws -> Int32
    func kickstart() throws -> Int32
    func call(_ method: String) throws
}

struct DoctorFix {
    enum FixError: Error, CustomStringConvertible {
        case unsupported, exit(Int32)
        var description: String {
            switch self {
            case .unsupported: return "这个动作不能在命令行执行"
            case .exit(let code): return "退出码 \(code)"
            }
        }
    }

    var cli: String
    var mqttEnrolled: Bool
    var ask: (String) -> String?
    var say: (String) -> Void
    var executor: DoctorFixExecutor
    /// A fresh local report (`online:false`); nil when the daemon cannot answer.
    var localReport: () -> ReadinessReport?
    /// What the daemon says right before a restart (B53 review I3b): asked before the question and after a yes.
    var restartAnswer: () -> ReadinessRestartAnswer

    func run(report: ReadinessReport) {
        let items: [(ReadinessCapability, ReadinessFix, ReadinessAction)] = report.capabilities.compactMap { capability in
            guard capability.status == .fail, let fix = capability.fix, let action = fix.action, action.known != nil else { return nil }
            return (capability, fix, action)
        }
        guard !items.isEmpty else { say("没有可以自动处理的项目。"); return }
        for (index, item) in items.enumerated() {
            let (capability, fix, action) = item
            say("")
            say("[\(index + 1)/\(items.count)] \(capability.title)：\(fix.text)")
            if action.navigatesOnly {
                if action.known == .openLogs { say("    日志在 ~/Library/Logs/imctl/imctld.log") }
                if let command = fix.command { say("    需要填写，命令行不代为执行。请运行：\n    $ \(ReadinessCommandText.substitute(command, cli: cli))") }
                continue
            }
            if action.restartsDaemon, let refusal = restartAnswer().refusal {
                say("    跳过：\(refusal)")
                continue
            }
            let question = ReadinessActionText.confirmation(action) ?? ""
            let answer = ask("    \(question)执行吗？[y/N] ")?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else { say("    未执行"); continue }
            // Review I3c: the yes may come long after the question; check again at this moment.
            if action.restartsDaemon, let refusal = restartAnswer().refusal {
                say("    跳过：\(refusal)")
                continue
            }
            do { try perform(action); say("    已执行") } catch { say("    执行失败：\(error)") }
        }
        if let after = localReport() {
            say("")
            say("处理后本机检查：" + (after.ready ? "✔ 就绪" : "✘ 未就绪" + (after.nextStep.map { "。下一步：\($0.text)" } ?? "")))
        }
    }

    func perform(_ action: ReadinessAction) throws {
        func check(_ status: Int32) throws { if status != 0 { throw FixError.exit(status) } }
        switch action.known {
        case .openSystemSettings?:
            guard let url = ReadinessActionText.systemSettingsURL(action.target) else { throw FixError.unsupported }
            try executor.open(url: url)
        case .openWeCom?: try executor.openApp(bundleID: "com.tencent.WeWorkMac")
        case .setup?: try check(executor.runCLI(["setup"]))
        case .reinstallDaemon?: try check(executor.runCLI(["agent", "install"] + (mqttEnrolled ? ["--mqtt"] : [])))
        case .restartDaemon?: try check(executor.kickstart())
        case .resumeDaemon?: try executor.call("controller.resume")
        case .registerAgents?: try check(executor.runCLI(["mcp", "install", "--claude-code", "--codex", "--skills"]))
        case .installSkills?: try check(executor.runCLI(["mcp", "install", "--skills"]))
        case .retest?: try check(executor.runCLI(["doctor", "--refresh"]))
        case .openSettings?, .openPolicy?, .openLogs?, nil: throw FixError.unsupported
        }
    }

    /// Real effects: `/usr/bin/open`, this binary, `launchctl`, the daemon socket. Child output goes to this terminal.
    struct LiveExecutor: DoctorFixExecutor {
        var me: String
        var socket: String

        func open(url: URL) throws { _ = try Self.status("/usr/bin/open", [url.absoluteString]) }
        func openApp(bundleID: String) throws { _ = try Self.status("/usr/bin/open", ["-b", bundleID]) }
        func runCLI(_ arguments: [String]) throws -> Int32 { try Self.status(me, arguments) }
        func kickstart() throws -> Int32 {
            try Self.status("/bin/launchctl", ["kickstart", "-k", Launchctl.serviceTarget(LaunchAgentSpec.defaultLabel)])
        }
        func call(_ method: String) throws { _ = try UnixSocketClient(path: socket, timeout: 15).call(method) }

        static func status(_ executable: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }
}

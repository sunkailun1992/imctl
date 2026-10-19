import ControlCore
import Foundation
import MCPTransport

/// `imctl doctor` (B52): fetch `controller.readiness`, poll while the live tests run, render in Chinese;
/// when the daemon cannot answer, say what this Mac shows directly and the one next step.
enum Doctor {
    static func fetch(call: (String, [String: JSONValue]) throws -> JSONValue, sleep: (TimeInterval) -> Void,
                      online: Bool, refresh: Bool, wait: TimeInterval) throws -> ReadinessReport {
        var params: [String: JSONValue] = ["online": .bool(online), "refresh": .bool(refresh)]
        var waited: TimeInterval = 0
        var last: ReadinessReport?
        while true {
            let report: ReadinessReport
            do {
                report = try decode(try call(RPCDispatcher.readinessMethod, params))
            } catch let error as UnixSocketClient.TransportError {
                // A later poll that gets no answer keeps the report already in hand (review C1).
                guard let last else { throw error }
                return last
            }
            last = report
            guard report.online.state == "running", waited < wait else { return report }
            params["refresh"] = .bool(false)
            sleep(1)
            waited += 1
        }
    }

    static func decode(_ value: JSONValue) throws -> ReadinessReport {
        try JSONDecoder().decode(ReadinessReport.self, from: Data(try value.serialized().utf8))
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func symbol(_ status: ReadinessStatus) -> String {
        switch status { case .ok: "✔"; case .fail: "✘"; case .disabled: "○"; case .unknown: "?" }
    }

    /// B53: what this CLI knows about itself.
    struct ClientFacts: Equatable {
        var cliBuild: String?
        var onPath: Bool
        var cliPath: String
    }

    /// A fix is shown for `fail` and `disabled`, and for an ok capability that has warnings (runtime health).
    static func showsFix(_ capability: ReadinessCapability) -> Bool {
        guard capability.fix != nil else { return false }
        return capability.status == .fail || capability.status == .disabled || !capability.warnings.isEmpty
    }

    /// `refreshAskedMs`: when this run asked for `--refresh`, so a round finished before then was reused (60 s floor).
    static func render(_ report: ReadinessReport, cli: String, refreshAskedMs: Int64? = nil, timeZone: TimeZone = .current,
                       client: ClientFacts? = nil) -> String {
        var lines: [String] = []
        if report.ready {
            let suffix = report.online.state == "skipped" ? "（只做了本机检查）" : (report.online.state == "done" ? "" : "（联网实测未完成）")
            lines.append("✔ 就绪：必需项都可用" + suffix)
        } else if let next = report.nextStep {
            lines.append("✘ 未就绪。下一步：\(next.text)")
            if let command = next.command { lines.append("    $ \(ReadinessCommandText.substitute(command, cli: cli))") }
        } else {
            lines.append("? 还有项目暂时无法判断（例如守护进程刚启动），几秒后再运行一次")
        }
        switch report.online.state {
        case "running": lines.append("联网实测在等待时间内没有完成，实测项标为「未实测」；稍后再运行一次")
        case "skipped": lines.append("只做了本机检查（--offline）")
        default: break
        }
        if report.online.state == "done", let tested = report.online.testedMs {
            lines.append("联网实测时间：\(clock(tested, timeZone: timeZone))")
            if let asked = refreshAskedMs, tested < asked {
                let next = report.online.nextRefreshAllowedMs.map { "；\(clock($0, timeZone: timeZone)) 后才能再重测" } ?? ""
                lines.append("60 秒内已实测过，这次沿用上一轮结果\(next)")
            }
        }
        lines.append("")
        for capability in report.capabilities {
            lines.append("\(symbol(capability.status)) \(capability.title)\(capability.required ? "" : "（可选）")")
            for check in capability.checks {
                let untested = check.tested == false && !check.detail.contains("未实测") ? "（未实测）" : ""
                lines.append("    \(symbol(check.status)) \(check.detail)\(untested)")
            }
            for warning in capability.warnings { lines.append("    ! \(warning)") }
            if let fix = capability.fix, showsFix(capability) {
                lines.append("    → \(fix.text)")
                if let command = fix.command { lines.append("      $ \(ReadinessCommandText.substitute(command, cli: cli))") }
            }
        }
        if let client {
            lines.append("")
            lines.append("本机客户端")
            if let mine = client.cliBuild, let daemon = report.build {
                lines.append(mine == daemon ? "    ✔ 命令行与守护进程同为 build \(mine)"
                                            : "    ! 命令行是 build \(mine)，守护进程在跑 build \(daemon)（可能开的是另一份 app，或守护进程还没重启）")
            }
            if client.onPath {
                lines.append("    ✔ 终端里可以直接用 imctl")
            } else {
                lines.append("    ○ 终端里要用完整路径；想直接打 imctl（需要管理员密码）：")
                lines.append("      $ \(ReadinessClient.linkCommand(cliPath: client.cliPath))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ ms: Int64, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "imctl" when the first `imctl` on the user's PATH is this binary; this binary's absolute path otherwise.
    static func cliPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                        me: String = AgentIntegration.executable(),
                        resolve: (String) -> String? = { path in
                            FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
                        }) -> String {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            if let found = resolve(String(dir) + "/imctl") { return found == me ? "imctl" : me }
        }
        return me
    }

    // MARK: Fallback

    struct Fallback: Codable, Equatable {
        var appPresent: Bool
        var plistPresent: Bool
        var loaded: Bool
        var daemonPid: Int?
        var clientRunning: Bool
        var clientVersion: String?
        /// `unreachable` | `busy` (alive but no answer in time) | `tooOld`
        var reason: String
    }

    /// Which failures get the fallback report: an old daemon (`method not found`) or no answer at all.
    static func fallbackReason(for error: Error) -> String? {
        if let rpc = error as? UnixSocketClient.RPCError { return rpc.code == -32601 ? "tooOld" : nil }
        if let transport = error as? UnixSocketClient.TransportError {
            // No answer in time means a daemon that is alive but busy (e.g. a long command): never "restart it".
            if case .timeout = transport { return "busy" }
            return "unreachable"
        }
        return nil
    }

    static func collectFallback(reason: String) -> Fallback {
        let fm = FileManager.default
        let appPresent = fm.fileExists(atPath: NSHomeDirectory() + "/Applications/imctl.app") || fm.fileExists(atPath: "/Applications/imctl.app")
        let plistPresent = fm.fileExists(atPath: LaunchAgentSpec.defaultPlistPath().path)
        let status = (try? Launchctl.run(["print", Launchctl.serviceTarget(LaunchAgentSpec.defaultLabel)])).map { LaunchctlStatus.parse($0.output) }
        let client = HostProbe.client(bundleID: "com.tencent.WeWorkMac")
        return Fallback(appPresent: appPresent, plistPresent: plistPresent, loaded: status?.loaded ?? false, daemonPid: status?.pid,
                        clientRunning: client != nil, clientVersion: client?.version, reason: reason)
    }

    static func renderFallback(_ f: Fallback, cli: String) -> String {
        let header: String
        switch f.reason {
        case "tooOld": header = "✘ 正在运行的守护进程版本早于 B52（没有 controller.readiness）。本机能直接看到的情况："
        case "busy": header = "? 守护进程在运行，但 15 秒内没有应答（可能正在执行一条长命令）。本机能直接看到的情况："
        default: header = "✘ 连不上守护进程。本机能直接看到的情况："
        }
        var lines = [header]
        lines.append("    \(f.appPresent ? "✔" : "✘") imctl.app \(f.appPresent ? "已安装" : "没找到")")
        lines.append("    \(f.plistPresent && f.loaded ? "✔" : "✘") 后台常驻 \(f.plistPresent ? (f.loaded ? "已加载" : "文件在但没加载") : "没安装")")
        lines.append("    \(f.daemonPid != nil ? "✔" : "✘") imctld \(f.daemonPid.map { "在运行（pid \($0)）" } ?? "没在运行")")
        lines.append("    \(f.clientRunning ? "✔" : "✘") 企业微信 \(f.clientRunning ? "在运行" + (f.clientVersion.map { "（\($0)）" } ?? "") : "没有运行")")
        let next: (text: String, command: String)
        if f.reason == "tooOld" {
            next = ("装好新版 imctl.app 后重装后台常驻", "\(cli) setup")
        } else if f.reason == "busy" {
            next = ("稍后再运行一次体检；命令执行中不要重启守护进程。先看它在做什么", "\(cli) status")
        } else if !f.plistPresent || !f.loaded {
            next = ("安装后台常驻并请求系统授权", "\(cli) setup")
        } else if f.daemonPid == nil {
            next = ("守护进程起不来：看最近的日志", "tail -n 50 ~/Library/Logs/imctl/imctld.log")
        } else {
            next = ("守护进程在运行但连不上 socket：重启它", "launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl")
        }
        lines.append("")
        lines.append("下一步：\(next.text)")
        lines.append("    $ \(next.command)")
        return lines.joined(separator: "\n")
    }
}

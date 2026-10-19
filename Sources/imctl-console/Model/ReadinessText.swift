import ControlCore
import Foundation

/// Words for the 体检 panel (B52), kept out of the view so they are testable.
enum ReadinessText {
    static func symbol(_ status: ReadinessStatus) -> String {
        switch status { case .ok: "✔"; case .fail: "✘"; case .disabled: "○"; case .unknown: "?" }
    }

    static func headline(_ report: ReadinessReport) -> String {
        if report.ready { return report.online.state == "done" ? "✔ 就绪" : "✔ 就绪（联网实测未完成）" }
        if let next = report.nextStep { return "✘ 未就绪 · 下一步：\(next.text)" }
        return "? 还有项目暂时无法判断，几秒后再体检一次"
    }

    struct ClientLine: Equatable {
        var symbol: String
        var text: String
        var action: ReadinessAction?
        var copy: String?
    }

    /// B53: what only this console knows — its own Accessibility grant, its build against the daemon's, the terminal link.
    static func clientLines(consoleTrusted: Bool, consoleBuild: String?, daemonBuild: String?, cliLinked: Bool, cliPath: String) -> [ClientLine] {
        var lines = [consoleTrusted
            ? ClientLine(symbol: "✔", text: "控制台自己的辅助功能已授权（界面诊断要用）")
            : ClientLine(symbol: "✘", text: "控制台自己的辅助功能未授权：只影响界面诊断，不影响就绪",
                         action: ReadinessAction(.openSystemSettings, target: "accessibility"))]
        if let mine = consoleBuild, let daemon = daemonBuild {
            lines.append(mine == daemon
                ? ClientLine(symbol: "✔", text: "控制台与守护进程同为 build \(mine)")
                : ClientLine(symbol: "!", text: "控制台是 build \(mine)，守护进程在跑 build \(daemon)",
                             action: ReadinessClient.isOlder(daemon, than: mine) ? ReadinessAction(.restartDaemon) : nil))
        }
        lines.append(cliLinked
            ? ClientLine(symbol: "✔", text: "终端里可以直接用 imctl")
            : ClientLine(symbol: "○", text: "终端里要用完整路径；想直接打 imctl，复制下面的命令（需要管理员密码）",
                         copy: ReadinessClient.linkCommand(cliPath: cliPath)))
        return lines
    }

    /// B53: when the daemon cannot answer — what this Mac shows directly (same facts as `imctl doctor`'s fallback).
    static func fallbackLines(agent: DaemonControl.AgentStatus?, clientRunning: Bool) -> [String] {
        var lines: [String] = []
        if let agent {
            lines.append(agent.plistPresent == false ? "后台常驻：没安装" : (agent.loaded ? "后台常驻：已加载" : "后台常驻：文件在但没加载"))
            lines.append(agent.pid.map { "imctld：在运行（pid \($0)）" } ?? "imctld：没在运行")
        } else {
            lines.append("后台常驻：读不到状态")
        }
        lines.append(clientRunning ? "企业微信：在运行" : "企业微信：没有运行")
        return lines
    }
}

import Foundation

/// B53: what a fix button does. Typed — clients run only these kinds and never execute a fix's command text.
/// `kind` stays a string on the wire, so a client that does not know a newer kind shows the fix without a button.
public struct ReadinessAction: Codable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case openSystemSettings, openWeCom, setup, reinstallDaemon, restartDaemon, resumeDaemon,
             registerAgents, installSkills, retest, openSettings, openPolicy, openLogs
    }

    public var kind: String
    public var target: String?

    public init(_ kind: Kind, target: String? = nil) { self.kind = kind.rawValue; self.target = target }
    /// A kind by name, as it arrives on the wire (forward compatibility and tests).
    public init(kind: String, target: String? = nil) { self.kind = kind; self.target = target }

    /// nil for a kind this build does not know: show the fix text only.
    public var known: Kind? { Kind(rawValue: kind) }

    /// Restarts the daemon: refused while a command is running, then confirmed.
    public var restartsDaemon: Bool {
        guard let known else { return false }
        return [.setup, .reinstallDaemon, .restartDaemon].contains(known)
    }

    /// Changes nothing by itself (another page or the log): no confirmation.
    public var navigatesOnly: Bool {
        guard let known else { return false }
        return [.openSettings, .openPolicy, .openLogs].contains(known)
    }
}

/// Words for actions, shared by the console and `imctl doctor --fix` so both ask the same question.
public enum ReadinessActionText {
    public static let busy = "有命令正在执行，现在不能重启守护进程；稍后再试"
    /// Review I3b: alive but silent may mean a long command (the doctor fallback calls it busy): never restart then.
    public static let noAnswer = "守护进程在运行但没有应答（可能正在执行一条长命令），现在不能重启；稍后再试"

    public static func button(_ action: ReadinessAction) -> String? {
        switch action.known {
        case .openSystemSettings?: return "打开系统设置"
        case .openWeCom?: return "打开企业微信"
        case .setup?: return "安装并请求授权"
        case .reinstallDaemon?: return "重装守护进程"
        case .restartDaemon?: return "重启守护进程"
        case .resumeDaemon?: return "解除暂停"
        case .registerAgents?: return "注册并安装技能"
        case .installSkills?: return "更新技能文件"
        case .retest?: return "重新实测"
        case .openSettings?: return "去配置"
        case .openPolicy?: return "去策略页"
        case .openLogs?: return "看日志"
        case nil: return nil
        }
    }

    /// The question asked before an action runs; nil for navigation and unknown kinds.
    public static func confirmation(_ action: ReadinessAction) -> String? {
        guard let kind = action.known, !action.navigatesOnly else { return nil }
        let restart = "守护进程会重启，几秒内不可用。"
        switch kind {
        case .openSystemSettings: return "将打开系统设置的「\(paneName(action.target))」页。"
        case .openWeCom: return "将打开企业微信。"
        case .setup: return "将安装或更新后台常驻，并请求系统授权（会弹出系统对话框）。" + restart
        case .reinstallDaemon: return "将按当前配置重装后台常驻（已配置 MQTT 就以 MQTT 模式运行）。" + restart
        case .restartDaemon: return "将重启守护进程。" + restart
        case .resumeDaemon: return "将解除手动（api）暂停，守护进程恢复执行命令。"
        case .registerAgents: return "将在 Claude Code 和 Codex 里注册 imctl，并安装技能文件。"
        case .installSkills: return "将用应用里的版本覆盖两边的技能文件。"
        case .retest: return "将重新联网实测，可能包含一次视觉模型调用。"
        case .openSettings, .openPolicy, .openLogs: return nil
        }
    }

    /// The three System Settings pages a fix may open. Fixed here, never taken from a report.
    public static func systemSettingsURL(_ target: String?) -> URL? {
        let anchor: String
        switch target {
        case "accessibility": anchor = "Privacy_Accessibility"
        case "screenRecording": anchor = "Privacy_ScreenCapture"
        case "fullDiskAccess": anchor = "Privacy_AllFiles"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    static func paneName(_ target: String?) -> String {
        switch target {
        case "accessibility": return "辅助功能"
        case "screenRecording": return "屏幕与系统录音"
        case "fullDiskAccess": return "完全磁盘访问权限"
        default: return "隐私与安全性"
        }
    }
}

/// B53: what a client learned right before restarting the daemon — asked when the button is pressed and again at
/// the moment of confirmation.
public enum ReadinessRestartAnswer: Equatable, Sendable {
    /// A fresh local report; `nil` = a B52 daemon, which does not count (taken as 0).
    case report(runningCommands: Int?)
    /// Nothing listens on the socket: nothing to protect.
    case notRunning
    /// Older than B52 (no `controller.readiness`): nothing to ask.
    case oldDaemon
    /// Running but no answer in time, or an error: it may be in the middle of a command.
    case noAnswer

    /// nil = go ahead; otherwise why not, as shown to the person.
    public var refusal: String? {
        switch self {
        case .report(let running): return (running ?? 0) > 0 ? ReadinessActionText.busy : nil
        case .notRunning, .oldDaemon: return nil
        case .noAnswer: return ReadinessActionText.noAnswer
        }
    }
}

import AppKit
import ArgumentParser
import AXKit
import ControlCore
import Foundation
import MCPTransport

/// B11 (user 2026-09-16): grant everything once, at install time, instead of meeting each system dialog
/// later. Installs / restarts the LaunchAgent, asks the daemon to trigger the dialogs it can trigger
/// (Accessibility, Screen Recording, the client's container), opens System Settings for manual grants,
/// and reports.
struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "One-time initialisation: install the daemon, trigger permission dialogs, open System Settings for manual grants, then report what is granted. `--check` only reports."
    )

    @Flag(help: "Report the daemon's grants without prompting or changing anything.") var check = false
    @Flag(name: .customLong("no-install"), help: "Do not install / restart the LaunchAgent (it must already be running).") var noInstall = false
    @Flag(name: .customLong("no-open"), help: "Do not open System Settings for Screen Recording or Full Disk Access.") var noOpen = false
    @Option(help: "Seconds to wait for the grants to land after the dialogs.") var wait: Double = 90
    @Option(help: "Unix socket served by imctld.") var socket: String = IMCTLPaths.socket.path

    static let permissionRows: [(key: String, label: String, ok: (String) -> Bool)] = [
        ("accessibility", "辅助功能（守护进程读写企微界面）", { $0 == "trusted" }),
        ("screenRecording", "屏幕录制（本机图片判向；显式命令可在独立授权后裁剪歧义按钮或企微窗口）", { $0 == "granted" }),
        ("wecomData", "访问企微数据（图片来自它的缓存）", { $0 == "granted" }),
        ("fullDiskAccess", "完全磁盘访问权限（更新后不再弹「访问其他 App 的数据」）", { $0 == "yes" }),
        ("clientRunning", "企业微信正在运行", { $0 == "true" }),
        ("launchAgent", "守护进程由 launchd 常驻", { $0 == "true" }),
    ]

    static func render(_ p: [String: String]) -> String {
        permissionRows.map { row in
            let value = p[row.key] ?? "-"
            return "\(row.ok(value) ? "✔" : "✘") \(row.label): \(value)"
        }.joined(separator: "\n")
    }

    func run() throws {
        let client = UnixSocketClient(path: socket, timeout: 20)
        if check {
            let p = try permissions(client, prompt: false)
            print(Self.render(p))
            throw ExitCode(Self.permissionRows.allSatisfy { $0.ok(p[$0.key] ?? "") || $0.key == "fullDiskAccess" } ? 0 : 2)
        }
        if !noInstall {
            let control = DaemonControl(executable: AgentIntegration.executable())
            print("1/4 守护进程：\(try control.ensureRunning())")
        }
        print("2/4 触发授权对话框（辅助功能、屏幕录制、访问企微数据）……")
        var p = try permissions(client, prompt: true)
        print(Self.render(p))
        print("3/4 等待系统授权结果……")
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let pending = Self.permissionRows.filter { !$0.ok(p[$0.key] ?? "") && $0.key != "fullDiskAccess" && $0.key != "clientRunning" }
            if pending.isEmpty { break }
            Thread.sleep(forTimeInterval: 3)
            p = (try? permissions(client, prompt: false, probe: true)) ?? p
        }
        // Open a manual grant page only after the native dialogs have had time to finish.
        // Opening two Settings pages back-to-back would hide the first one.
        if !noOpen, p["screenRecording"] != "granted",
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            print("打开 系统设置 › 隐私与安全性 › 屏幕录制：请允许 imctl.app；macOS 要求时重启应用及守护进程")
            NSWorkspace.shared.open(url)
            if p["fullDiskAccess"] != "yes" {
                print("完全磁盘访问权限也未授权；控制台「体检」页这一项有「打开系统设置」按钮")
            }
        } else if !noOpen, p["fullDiskAccess"] != "yes", let url = AXPermission.fullDiskAccessSettingsURL {
            print("打开 系统设置 › 隐私与安全性 › 完全磁盘访问权限：请把 imctl.app 加进去并打开（一次性，更新后不再弹窗）")
            NSWorkspace.shared.open(url)
        }
        print("4/4 结果：")
        print(Self.render(p))
        let missing = Self.permissionRows.filter { !$0.ok(p[$0.key] ?? "") && $0.key != "fullDiskAccess" }
        if missing.isEmpty {
            print("完成。控制台「体检」页或 imctl setup --check 可随时复查。")
            print("完整体检：imctl doctor（每项功能能不能用、怎么修）")
        } else {
            print("仍缺：\(missing.map(\.label).joined(separator: "、"))——在系统提示里点「允许」后重跑 imctl setup --check")
            print("完整体检：imctl doctor（每项功能能不能用、怎么修）")
            throw ExitCode(2)
        }
    }

    func permissions(_ client: UnixSocketClient, prompt: Bool, probe: Bool = false) throws -> [String: String] {
        let r = try client.call("controller.permissions", params: ["prompt": .bool(prompt), "probe": .bool(probe)])
        return r.objectValue?["result"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }
}

/// The few launchctl steps `imctl setup` needs, reusing the agent commands.
struct DaemonControl {
    var executable: String

    /// Installs the LaunchAgent when it is not loaded, otherwise restarts it so the newest binary runs.
    func ensureRunning() throws -> String {
        let label = LaunchAgentSpec.defaultLabel
        if Launchctl.isLoaded(label) {
            _ = try Launchctl.run(["kickstart", "-k", Launchctl.serviceTarget(label)])
            Thread.sleep(forTimeInterval: 2)
            return "已在 launchd，已重启（\(label)）"
        }
        var install = try AgentInstallCommand.parse([])
        install.mqtt = FileManager.default.fileExists(atPath: IMCTLPaths.dataDirectory.appendingPathComponent("mqtt.json").path)
        try install.run()
        Thread.sleep(forTimeInterval: 2)
        return "已安装并启动（\(label)）"
    }
}

import ControlCore
import SwiftUI

struct MenuBarMenu: View {
    @Environment(ConsoleModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button("打开控制台") {
            if !AppDelegate.showConsole() { openWindow(id: "console") }
        }
        Button("体检…") {
            model.section = .readiness
            if !AppDelegate.showConsole() { openWindow(id: "console") }
        }
        Button("初始化向导…") {
            if !AppDelegate.showConsole() { openWindow(id: "console") }
            Task { await model.openWizard() }
        }
        Toggle("在程序坞显示图标", isOn: Binding(get: { DockPresence.enabled }, set: { DockPresence.enabled = $0 }))
        Button("刷新状态") { Task { await model.refresh() } }
        if model.state?.pausedReasons.contains("api") == true {
            Button("恢复（去掉 api 暂停）") { Task { await model.resume() } }
        } else {
            Button("暂停（api）") { Task { await model.pause() } }
        }
        Button("重启守护进程…") {
            // B53 review I3d: confirmed in the console window, and refused while a command runs
            if !AppDelegate.showConsole() { openWindow(id: "console") }
            Task { await model.requestAction(ReadinessAction(.restartDaemon)) }
        }
        Divider()
        Button("退出 imctl 控制台") { NSApp.terminate(nil) }
    }
}

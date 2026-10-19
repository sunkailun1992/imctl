import ControlCore
import SwiftUI

struct StatusView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var confirmingUninstall = false

    private var daemonRunning: Bool { model.state?.isAlive == true }
    private var daemonPaused: Bool { !(model.state?.pausedReasons.isEmpty ?? true) }
    private var apiPaused: Bool { model.state?.pausedReasons.contains("api") == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    summaryCard(
                        "守护进程", value: model.state == nil ? "待读取" : (daemonRunning ? (daemonPaused ? "已暂停" : "运行中") : "未运行"),
                        detail: model.state?.uptimeSeconds.map { "已运行 \($0 / 60) 分钟" } ?? "等待状态读回",
                        symbol: "server.rack", color: daemonRunning ? (daemonPaused ? .orange : .green) : .red
                    )
                    summaryCard(
                        "企业微信", value: model.clientRunning ? "已打开" : "未打开",
                        detail: model.socketReachable ? "本地连接可用" : "本地连接不可用",
                        symbol: "bubble.left.and.bubble.right", color: model.clientRunning && model.socketReachable ? .green : .orange
                    )
                    summaryCard(
                        "辅助功能", value: model.state?.trusted.map { $0 ? "已授权" : "未授权" } ?? "待检查",
                        detail: "以守护进程读回为准",
                        symbol: "hand.raised", color: model.state?.trusted == true ? .green : .orange
                    )
                    summaryCard(
                        "发送范围", value: model.policyState.isEmpty ? "待读取" : (model.allowAll ? "全部放开" : "按规则放行"),
                        detail: model.allowAll ? "任何会话均可发送" : "在策略页查看允许目标",
                        symbol: "checkmark.shield", color: model.allowAll ? .orange : .blue
                    )
                }

                if model.allowAll {
                    Label("当前策略允许向任何会话发送。需要调整发送范围时，请打开左侧“策略”。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                if let hint = model.daemonHint {
                    Label(hint, systemImage: "info.circle")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("常用操作") {
                    HStack(spacing: 10) {
                        Button(apiPaused ? "恢复执行" : "暂停执行") {
                            Task { if apiPaused { await model.resume() } else { await model.pause() } }
                        }
                        .disabled(!daemonRunning || model.busy)
                        Button("打开日志目录") { model.openLogs() }
                        Button("刷新状态") { Task { await model.refresh() } }
                        Toggle("在程序坞显示图标", isOn: Binding(get: { DockPresence.enabled }, set: { DockPresence.enabled = $0 }))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                DisclosureGroup("运行详情") {
                    VStack(spacing: 0) {
                        if let s = model.state {
                            detail("版本", s.version ?? "-")
                            detail("进程", "pid \(s.pid)")
                            detail("暂停原因", s.pausedReasons.isEmpty ? "无" : s.pausedReasons.joined(separator: ", "))
                            detail("观察者 / 轮询 / 错误", "\(s.observer == true ? "AX 通知" : "仅轮询") / \(s.polls ?? 0) / \(s.errors ?? 0)")
                            detail("活动会话 / 数量", "\(s.active.flatMap { $0.isEmpty ? nil : $0 } ?? "-") / \(s.conversations ?? 0)")
                            detail("最新事件", String(s.lastEventId ?? 0))
                            detail("本地套接字", s.socket.flatMap { $0.isEmpty ? nil : $0 } ?? "未开启")
                            detail("套接字可达", model.socketReachable ? "是" : "否")
                            detail("策略摘要", s.policy ?? "-")
                        } else {
                            Text(model.stateError ?? "未读到守护进程状态").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                }

                DisclosureGroup("守护进程维护") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let a = model.agent {
                            detail("已装入", a.loaded ? "是" : "否")
                            detail("运行状态", "\(a.state ?? "-") / pid \(a.pid ?? 0)")
                            detail("上次退出码", a.lastExitCode ?? "-")
                        } else {
                            Text(model.agentError ?? "未读到后台常驻状态").foregroundStyle(.secondary)
                        }
                        HStack {
                            // B53 review I3d: confirmed, and refused while a command runs
                            Button("安装 / 更新…") { Task { await model.requestAction(ReadinessAction(.reinstallDaemon)) } }
                            Button("重启…") { Task { await model.requestAction(ReadinessAction(.restartDaemon)) } }
                            Button("卸载", role: .destructive) { confirmingUninstall = true }
                        }
                        if let a = model.lastAgentAction {
                            Text("\(a.title)：\(a.output)")
                                .font(.caption.monospaced())
                                .foregroundStyle(a.failed ? .red : .green)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 10)
                }
                .confirmationDialog("卸载本机守护进程？", isPresented: $confirmingUninstall) {
                    Button("卸载守护进程", role: .destructive) { Task { await model.uninstallDaemon() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("控制台仍会保留，但后台控制与事件观察将停止。")
                }

                DisclosureGroup("控制器原始信息") {
                    VStack(spacing: 0) {
                        ForEach(model.describe.keys.sorted(), id: \.self) { key in
                            detail(key, model.describe[key] ?? "")
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.loadPolicy() }
    }

    private func summaryCard(_ title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.title2.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(title).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            Divider()
        }
    }
}

import ControlCore
import SwiftUI

enum ConsoleSection: String, CaseIterable, Identifiable {
    case readiness = "体检", status = "状态", conversations = "会话", send = "发送", contacts = "通讯录", events = "事件", policy = "策略", settings = "设置", log = "日志", docs = "对接文档"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .readiness: return "checklist.checked"
        case .status: return "heart.text.square"
        case .conversations: return "bubble.left.and.bubble.right"
        case .send: return "paperplane"
        case .contacts: return "person.crop.circle.badge.plus"
        case .events: return "list.bullet.rectangle"
        case .policy: return "checklist"
        case .settings: return "gearshape"
        case .log: return "doc.text.magnifyingglass"
        case .docs: return "book"
        }
    }
    /// One line under the page title, written for the person using the console.
    var subtitle: String {
        switch self {
        case .readiness: return "逐项检查这台 Mac 能不能用，点按钮修复"
        case .status: return "运行情况、授权与常用控制"
        case .conversations: return "查看会话与消息，处理测试群"
        case .send: return "向已授权的目标发送文字或文件"
        case .contacts: return "处理新客户、好友与群成员"
        case .events: return "查看控制器记录的事件"
        case .policy: return "管理发送范围与新客户自动处理"
        case .settings: return "配置 MQTT、企微代理和对象存储"
        case .log: return "查看这次打开控制台后的操作记录"
        case .docs: return "阅读随应用附带的对接文档"
        }
    }
    /// Keep everyday tasks above monitoring and configuration.
    static let groups: [(String, [ConsoleSection])] = [
        ("概览", [.readiness, .status]),
        ("日常操作", [.conversations, .contacts, .send]),
        ("监控", [.events, .log]),
        ("配置", [.policy, .settings]),
        ("参考", [.docs]),
    ]
}

struct ConsoleWindow: View {
    @Environment(ConsoleModel.self) private var model
    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(ConsoleSection.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { s in Label(s.rawValue, systemImage: s.symbol).tag(s) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            let current = model.section ?? .readiness
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(section: current)
                Divider()
                Group {
                    switch current {
                    case .readiness: ReadinessPageView()
                    case .status: StatusView()
                    case .conversations: ConversationsView()
                    case .send: SendView()
                    case .contacts: ContactsView()
                    case .events: EventsView()
                    case .policy: PolicyView()
                    case .settings: SettingsView()
                    case .log: LogView()
                    case .docs: DocsView()
                    }
                }
                .padding(current == .conversations || current == .contacts ? 12 : 0)
            }
            .navigationTitle("imctl")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .help("重新读取守护进程状态（state.json + controller.describe）")
                }
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task { await model.startupReadiness(); await model.refresh() }
        .readinessActionConfirmation(inWizard: false)
        .sheet(isPresented: $model.wizardPresented, onDismiss: { SetupWizard.markDone(.standard) }) {
            SetupWizardView().environment(model)
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                tick += 1
                // state file every 3 s; launchd + describe (a command) only every 60 s
                if tick % 20 == 0 { await model.refresh() } else { model.refreshLocal() }
                if model.tailing { await model.tailOnce() }
            }
        }
        .overlay(alignment: .bottomTrailing) { if model.busy { ProgressView().controlSize(.small).padding() } }
    }
}

/// Page title, symbol and a one-line purpose; the same on every page (1.0).
struct PageHeader: View {
    let section: ConsoleSection
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: section.symbol).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue).font(.title2.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Daemon state at a glance, always visible at the bottom of the sidebar.
struct SidebarFooter: View {
    @Environment(ConsoleModel.self) private var model
    var tone: Color {
        guard let s = model.state, s.isAlive else { return .red }
        return s.pausedReasons.isEmpty ? .green : .orange
    }
    var label: String {
        guard let s = model.state, s.isAlive else { return "守护进程未运行" }
        return s.pausedReasons.isEmpty ? "运行中" : "暂停 · \(s.pausedReasons.joined(separator: ","))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 8, height: 8)
                Text(label).font(.caption)
                Spacer()
            }
            Text("imctl \(IMCTLVersion.string) · build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

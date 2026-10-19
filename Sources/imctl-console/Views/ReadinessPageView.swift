import ControlCore
import SwiftUI

/// B53: every readiness check in one place, a button on each fix (confirmed by the console window's dialog),
/// what only this console knows, and the in-console UI diagnosis that used to be its own page.
struct ReadinessPageView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var localOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(model.readinessRunning ? "体检中…" : "运行体检") { Task { await model.runReadiness(localOnly: localOnly) } }
                        .disabled(model.readinessRunning)
                    ReadinessActionButton(action: ReadinessAction(.retest)).disabled(model.readinessRunning || localOnly)
                    Toggle("只做本机检查", isOn: $localOnly)
                    Spacer()
                    Button("重新运行向导") { Task { await model.openWizard() } }
                }
                if let report = model.readiness {
                    Text(ReadinessText.headline(report)).font(.title3.weight(.semibold))
                    if report.online.state == "done", let tested = report.online.testedMs {
                        Text("联网实测时间：\(Date(timeIntervalSince1970: Double(tested) / 1000).formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let next = report.nextStep?.action { ReadinessActionButton(action: next) }
                    ReadinessCapabilityList(report: report)
                } else {
                    Text("守护进程没有应答。本机能直接看到的情况：").font(.headline)
                    ForEach(ReadinessText.fallbackLines(agent: model.agent, clientRunning: model.clientRunning), id: \.self) { Text($0) }
                    ReadinessActionButton(action: ReadinessAction(.setup))
                }
                GroupBox("本机客户端") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ReadinessText.clientLines(consoleTrusted: model.consoleTrusted, consoleBuild: model.consoleBuild,
                                                          daemonBuild: model.readiness?.build,
                                                          cliLinked: ReadinessClient.cliLinked(cliPath: model.cli.executable.path),
                                                          cliPath: model.cli.executable.path), id: \.text) { line in
                            HStack {
                                Text("\(line.symbol) \(line.text)")
                                if let action = line.action { ReadinessActionButton(action: action) }
                                if let copy = line.copy { CopyButton(text: copy) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("界面诊断（控制台进程只读一次企业微信界面，不按任何东西）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("诊断界面") { Task { await model.runDiagnostics() } }
                        if let d = model.diagnostics {
                            LabeledContent("企业微信运行中", value: d.clientRunning ? "是" : "否")
                            LabeledContent("窗口", value: d.windowFrame ?? "-")
                            LabeledContent("会话表", value: d.conversationTable ?? "-")
                            LabeledContent("消息表", value: d.messageTable ?? "-")
                            LabeledContent("输入框", value: d.composerPresent.map { $0 ? "有" : "无（通知类会话）" } ?? "-")
                            LabeledContent("活动会话 / 类型", value: "\(d.activeTitle ?? "-") / \(d.activeType ?? "-")")
                            LabeledContent("会话行数 / 行高", value: "\(d.conversationCount ?? 0) / \(d.rowHeights?.map(String.init).joined(separator: ",") ?? "-")")
                            LabeledContent("窗口菜单", value: d.windowMenuItems?.joined(separator: " · ") ?? "-")
                            if let e = d.error { Text(e).foregroundStyle(.red) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 1400, alignment: .leading)
        }
        .task { await model.runReadiness(localOnly: true, maxPolls: 0) }
    }
}

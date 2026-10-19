import AppKit
import ControlCore
import SwiftUI

/// B53 first-run wizard. Every step reads the last local readiness report; actions go through the model's
/// confirmed entry; the configure steps embed the settings page's own forms and only save.
struct SetupWizardView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(Array(model.wizard.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1) \(step.title)")
                        .font(.caption.weight(index == model.wizard.index ? .bold : .regular))
                        .foregroundStyle(index == model.wizard.index ? .primary : .secondary)
                }
            }
            Divider()
            ScrollView { stepBody.frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            HStack {
                Button("上一步") { model.wizard.back() }.disabled(model.wizard.index == 0)
                Button("重新检查") { Task { await model.runReadiness(localOnly: true, maxPolls: 0) } }
                Spacer()
                if model.wizard.current == .finish {
                    Button("完成") { model.finishWizard() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("跳过") { model.wizard.skip() }
                    Button("下一步") { model.wizard.next() }.keyboardShortcut(.defaultAction)
                }
                Button("关闭") { model.closeWizard() }
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .readinessActionConfirmation(inWizard: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.runReadiness(localOnly: true, maxPolls: 0) }
        }
    }

    @ViewBuilder private var stepBody: some View {
        let report = model.readiness
        let step = model.wizard.current
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title).font(.title2.weight(.semibold))
            Text(SetupWizard.isDone(step, report: report) ? "✔ 这一步已完成" : (step.required ? "这一步是必需的" : ""))
                .foregroundStyle(.secondary)
            switch step {
            case .install:
                if let report {
                    ReadinessCapabilityList(report: filtered(report, ["daemon", "read", "media"]))
                } else {
                    Text("守护进程还没装好。本机能直接看到的情况：")
                    ForEach(ReadinessText.fallbackLines(agent: model.agent, clientRunning: model.clientRunning), id: \.self) { Text($0) }
                    ReadinessActionButton(action: ReadinessAction(.setup))
                }
            case .wecom:
                if let report { ReadinessCapabilityList(report: filtered(report, ["wecom"])) }
            case .sendScope:
                if let report { ReadinessCapabilityList(report: filtered(report, ["send"])) }
                Text("默认只能发给文件传输助手。要放开别的会话，完成向导后到「策略」页设置。").foregroundStyle(.secondary)
            case .features:
                ForEach(SetupWizard.Feature.allCases, id: \.self) { feature in
                    Toggle(feature.title, isOn: Binding(
                        get: { model.wizard.selected.contains(feature) },
                        set: { on in if on { model.wizard.selected.insert(feature) } else { model.wizard.selected.remove(feature) } }))
                }
                Text("自动接受好友申请属于策略，完成后在「策略」页按需开启；按手机号加人不用开启，任何号码都可以加（每小时有上限）。").foregroundStyle(.secondary)
            case .configure(let feature):
                configure(feature, report: report)
            case .apply:
                Text("刚才保存的配置要重启守护进程才生效（已配置 MQTT 会以 MQTT 模式重装）。")
                ReadinessActionButton(action: ReadinessAction(.reinstallDaemon))
            case .finish:
                Button(model.readinessRunning ? "体检中…" : "运行完整体检（联网实测，含一次视觉模型调用）") {
                    Task { await model.runReadiness() }
                }
                .disabled(model.readinessRunning)
                if !model.wizard.skipped.isEmpty {
                    Text("跳过的必需步骤：\(model.wizard.skipped.map(\.title).joined(separator: "、"))").foregroundStyle(.orange)
                }
                if let report {
                    Text(ReadinessText.headline(report)).font(.headline)
                    ReadinessCapabilityList(report: report)
                }
            }
        }
    }

    @ViewBuilder private func configure(_ feature: SetupWizard.Feature, report: ReadinessReport?) -> some View {
        switch feature {
        case .agents:
            if let report { ReadinessCapabilityList(report: filtered(report, ["agents"])) }
        case .mqtt: Form { MQTTSettingsForm(onSaved: { model.wizard.featureSaved(.mqtt) }) }.formStyle(.grouped)
        case .vision: Form { VisionSettingsForm(onSaved: { model.wizard.featureSaved(.vision) }) }.formStyle(.grouped)
        case .oss: Form { OSSSettingsForm(onSaved: { model.wizard.featureSaved(.oss) }) }.formStyle(.grouped)
        case .proxy: Form { ProxySettingsForm(onSaved: { model.wizard.featureSaved(.proxy) }) }.formStyle(.grouped)
        }
    }

    private func filtered(_ report: ReadinessReport, _ ids: [String]) -> ReadinessReport {
        var r = report
        r.capabilities = report.capabilities.filter { ids.contains($0.id) }
        return r
    }
}

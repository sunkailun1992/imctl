import ControlCore
import SwiftUI

/// A fix's button: the label comes from the action's kind; tapping goes through the model's single action entry.
struct ReadinessActionButton: View {
    @Environment(ConsoleModel.self) private var model
    let action: ReadinessAction
    var body: some View {
        if let title = ReadinessActionText.button(action) {
            Button(title) { Task { await model.requestAction(action) } }
        }
    }
}

/// Capabilities with checks, warnings, fix text, action button and copyable command (readiness page, wizard finish).
struct ReadinessCapabilityList: View {
    @Environment(ConsoleModel.self) private var model
    let report: ReadinessReport
    var body: some View {
        ForEach(report.capabilities, id: \.id) { capability in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ReadinessText.symbol(capability.status)) \(capability.title)\(capability.required ? "" : "（可选）")").font(.headline)
                ForEach(capability.checks, id: \.id) { check in
                    Text("\(ReadinessText.symbol(check.status)) \(check.detail)\(check.tested == false && !check.detail.contains("未实测") ? "（未实测）" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(capability.warnings, id: \.self) { Text("! \($0)").font(.caption).foregroundStyle(.orange) }
                if let fix = capability.fix, capability.status == .fail || capability.status == .disabled || !capability.warnings.isEmpty {
                    Text(fix.text).font(.caption)
                    HStack {
                        if let action = fix.action { ReadinessActionButton(action: action) }
                        if let command = fix.command {
                            Text(model.cliCommand(command)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            CopyButton(text: model.cliCommand(command))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The confirmation dialog for the model's pending action, plus the busy notice. Attached to the console window and
/// to the wizard sheet; `ConsoleModel.presentsConfirmation(inWizard:)` decides which one shows.
struct ReadinessActionConfirmation: ViewModifier {
    @Environment(ConsoleModel.self) private var model
    let inWizard: Bool
    func body(content: Content) -> some View {
        content
            .confirmationDialog(model.pendingAction.flatMap { ReadinessActionText.button($0) } ?? "确认",
                                isPresented: Binding(get: { model.presentsConfirmation(inWizard: inWizard) },
                                                     set: { if !$0 { model.cancelPendingAction() } }),
                                presenting: model.pendingAction) { action in
                // Review C1: dismissing the dialog clears pendingAction, maybe before this runs; pass what was shown.
                Button("确认执行") { Task { await model.confirm(action) } }
                Button("取消", role: .cancel) { model.cancelPendingAction() }
            } message: { action in
                Text(ReadinessActionText.confirmation(action) ?? "")
            }
            .alert(model.actionNotice ?? "", isPresented: Binding(get: { model.presentsNotice(inWizard: inWizard) },
                                                                set: { if !$0 { model.actionNotice = nil } })) {
                Button("好") { model.actionNotice = nil }
            }
    }
}

extension View {
    func readinessActionConfirmation(inWizard: Bool) -> some View { modifier(ReadinessActionConfirmation(inWizard: inWizard)) }
}

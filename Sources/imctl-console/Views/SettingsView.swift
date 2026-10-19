import SwiftUI

enum SettingsPane: String, CaseIterable {
    case mqtt = "MQTT", proxy = "企微代理", oss = "对象存储", vision = "视觉识别"

    /// The `openSettings` action's target.
    init?(target: String?) {
        switch target {
        case "mqtt": self = .mqtt
        case "proxy": self = .proxy
        case "oss": self = .oss
        case "vision": self = .vision
        default: return nil
        }
    }
}

struct SettingsView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Picker("设置类别", selection: $model.settingsPane) {
                ForEach(SettingsPane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 580)
            .padding(16)
            Divider()
            Form {
                switch model.settingsPane {
                case .mqtt: MQTTSettingsForm()
                case .proxy: ProxySettingsForm()
                case .oss: OSSSettingsForm()
                case .vision: VisionSettingsForm()
                }
                Section {
                    Text("设置保存在本机。保存后请到“状态”页重启守护进程，使新配置生效；第一次配置 MQTT 要点“守护进程维护”里的“安装 / 更新”，以 MQTT 模式重装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

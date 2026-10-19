import SwiftUI
import WeComAdapter

/// Destinations come from the daemon's conversation or contact list; platform IDs
/// remain available in the manual field for callers who already know one.
struct SendView: View {
    private enum Pane: String, CaseIterable {
        case text = "文字"
        case file = "文件"
        case broadcast = "群发"
    }

    static let manualChoice = "手动输入（chatId:<id> | externalUserId:<id> | 标题）"

    @Environment(ConsoleModel.self) private var model
    @State private var pane: Pane = .text
    @State private var choice = WeComClient.fileTransferAssistantTitle
    @State private var manual = ""
    @State private var text = ""
    @State private var result = ""
    @State private var broadcastTargets: Set<String> = []
    @State private var intervalMs = 3500
    @State private var fileURL = ""
    @State private var ossKey = ""
    @State private var fileName = ""
    @State private var fileResult = ""
    @State private var fileSourceError: String?

    var options: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        let titles = [WeComClient.fileTransferAssistantTitle] + model.conversations.compactMap { $0["title"] } + model.contacts.compactMap { $0["name"] }
        for title in titles where !title.isEmpty && seen.insert(title).inserted { out.append(title) }
        return out
    }

    var target: String { choice == Self.manualChoice ? manual.trimmingCharacters(in: .whitespaces) : choice }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("发送方式", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(16)
            Divider()
            Form {
                if model.allowAll {
                    Section {
                        Label("当前策略对任何会话放行。发送前请核对目标。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if pane != .broadcast {
                    Section("目标") {
                        Picker("发送到", selection: $choice) {
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                            Text(Self.manualChoice).tag(Self.manualChoice)
                        }
                        .pickerStyle(.menu)
                        if choice == Self.manualChoice {
                            TextField("chatId:<id> | externalUserId:<id> | 标题", text: $manual)
                        }
                        HStack {
                            Button("刷新会话") { Task { await model.loadConversations() } }
                            Button("读取好友") { Task { await model.loadContacts() } }
                            Text("\(model.conversations.count) 个会话 · \(model.contacts.count) 位好友")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                switch pane {
                case .text: textForm
                case .file: fileForm
                case .broadcast: broadcastForm
                }
                if let hint = model.daemonHint {
                    Section { Text(hint).font(.caption).foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
        }
        .task {
            if model.conversations.isEmpty { await model.loadConversations() }
            await model.loadPolicy()
        }
    }

    private var textForm: some View {
        Section("消息内容") {
            TextEditor(text: $text)
                .frame(minHeight: 150)
            HStack {
                Button("发送文字到 \(target.isEmpty ? "…" : target)") {
                    let destination = target, message = text
                    Task { result = await model.send(target: destination, text: message) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty || target.isEmpty || model.busy)
                Spacer()
                Text("经守护进程执行；保留幂等键与速率限制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.isEmpty { ResultPane(title: "发送结果", text: result, minHeight: 120) }
        }
    }

    private var fileForm: some View {
        Section("文件来源") {
            Text("填写 HTTPS 地址或已配置对象存储的对象键，两者只选其一。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("HTTPS 地址", text: $fileURL)
            TextField("或对象键（ossKey）", text: $ossKey)
            TextField("文件名（可选）", text: $fileName)
            if let fileSourceError {
                Text(fileSourceError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("发送文件到 \(target.isEmpty ? "…" : target)") {
                    let destination = target
                    let url = fileURL.trimmingCharacters(in: .whitespaces)
                    let key = ossKey.trimmingCharacters(in: .whitespaces)
                    let name = fileName
                    guard url.isEmpty || key.isEmpty else {
                        fileSourceError = "只能填写一个来源：HTTPS 地址或对象键。"
                        return
                    }
                    fileSourceError = nil
                    Task { fileResult = await model.sendFile(target: destination, url: url, ossKey: key, fileName: name) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.isEmpty || (fileURL.isEmpty && ossKey.isEmpty) || model.busy)
            }
            DisclosureGroup("来源限制与发送过程") {
                Text("允许的来源域名：\(model.allowedHosts.isEmpty ? "无（全部拒绝）" : model.allowedHosts.joined(separator: ", "))")
                Text("文件先下载到本机临时目录，再粘贴到客户端。粘贴期间剪贴板会短暂被覆盖并恢复。")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !fileResult.isEmpty { ResultPane(title: "文件发送结果", text: fileResult, minHeight: 120) }
        }
    }

    private var broadcastForm: some View {
        Section("群发目标与内容") {
            Text("已选 \(broadcastTargets.count) 个目标。每个目标独立经过策略与速率检查。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(options, id: \.self) { destination in
                        Toggle(destination, isOn: Binding(
                            get: { broadcastTargets.contains(destination) },
                            set: { selected in
                                if selected { broadcastTargets.insert(destination) }
                                else { broadcastTargets.remove(destination) }
                            }
                        ))
                    }
                }
            }
            .frame(height: 180)
            TextEditor(text: $text).frame(minHeight: 120)
            Stepper("目标间隔 \(intervalMs) ms", value: $intervalMs, in: 0...30000, step: 500)
            Button("向 \(broadcastTargets.count) 个目标群发") {
                let destinations = options.filter { broadcastTargets.contains($0) }
                let message = text, spacing = intervalMs
                Task { result = await model.broadcast(targets: destinations, text: message, intervalMs: spacing) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty || broadcastTargets.isEmpty || model.busy)
            Text("全局上限为每分钟 20 条；不在允许范围内的目标会单独失败。")
                .font(.caption).foregroundStyle(.secondary)
            if !result.isEmpty { ResultPane(title: "群发结果", text: result, minHeight: 120) }
        }
    }
}

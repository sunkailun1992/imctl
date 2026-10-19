import ControlCore
import SwiftUI

struct PolicyView: View {
    private enum Pane: String, CaseIterable {
        case sending = "发送权限"
        case requests = "新客户自动化"
        case files = "文件来源"
    }

    @Environment(ConsoleModel.self) private var model
    @State private var pane: Pane = .sending
    @State private var title = ""
    @State private var host = ""
    @State private var allowChoice = ""
    @State private var autoAccept = "off"
    @State private var autoGroup = "off"
    @State private var allowNames = ""
    @State private var keywords = ""
    @State private var defaultMembers = ""
    @State private var template = ContactRequestPolicy.defaultTemplate
    @State private var maxAccepts = "20"
    /// B14: 全部放开 asks before it flips on — the switch itself stays off until the dialog is confirmed.
    @State private var pendingAllowAll = false
    /// B14: which title row (if any) is showing its inline 修改 editor, and the field's current text.
    @State private var editingTitle: String?
    @State private var editTitleText = ""
    @State private var chatId = ""
    @State private var externalUserId = ""

    func loadRequests() {
        let policy = model.currentPolicy()
        let r = policy.contactRequests
        autoAccept = r.autoAccept.rawValue; autoGroup = r.autoGroup.rawValue
        allowNames = r.allowNames.joined(separator: ", "); keywords = r.greetingContains.joined(separator: ", ")
        defaultMembers = r.groupDefaultMembers.joined(separator: ", "); template = r.groupNameTemplate; maxAccepts = String(r.maxAcceptsPerHour)
    }

    func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Names are kept in the comma list; the pickers only add / remove entries (user request 2026-09-16: choose, don't type).
    func toggle(_ name: String, in list: Binding<String>) {
        var names = split(list.wrappedValue)
        if let i = names.firstIndex(of: name) { names.remove(at: i) } else { names.append(name) }
        list.wrappedValue = names.joined(separator: ", ")
    }

    @ViewBuilder
    func picker(_ rows: [[String: String]], list: Binding<String>, empty: String) -> some View {
        if rows.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            let chosen = Set(split(list.wrappedValue))
            ScrollView(.horizontal) {
                HStack {
                    ForEach(rows, id: \.["name"]) { row in
                        let name = row["name"] ?? ""
                        Toggle(isOn: Binding(get: { chosen.contains(name) }, set: { _ in toggle(name, in: list) })) {
                            Text(name + (row["section"].map { " · \($0)" } ?? ""))
                        }
                        .toggleStyle(.button)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("策略类别", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .padding(16)
            Divider()
            Form {
            if pane == .sending {
            Section("发送范围") {
                Toggle("全部放开（任何会话都可发送，含类型 unknown）", isOn: Binding(
                    get: { model.allowAll },
                    set: { on in if on { pendingAllowAll = true } else { Task { await model.policyAllowAll(false) } } }
                ))
                .confirmationDialog(
                    "开启后任何会话（包括未放行的联系人 / 群、类型 unknown）都可以发送消息，风险自负；随时可以关闭（imctl policy all --disable）。确定开启全部放开？",
                    isPresented: $pendingAllowAll, titleVisibility: .visible
                ) {
                    Button("开启全部放开", role: .destructive) { Task { await model.policyAllowAll(true) } }
                    Button("取消", role: .cancel) {}
                }
                if model.allowAll {
                    Text("全部放开：任何会话都可发送（含类型 unknown）。").font(.caption).foregroundStyle(.red)
                }
                Text("按会话类型放行").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("群", isOn: Binding(get: { model.allowedTypes.group }, set: { on in Task { await model.policyType("group", allow: on) } }))
                    Toggle("客户", isOn: Binding(get: { model.allowedTypes.customer }, set: { on in Task { await model.policyType("customer", allow: on) } }))
                    Toggle("内部", isOn: Binding(get: { model.allowedTypes.internal }, set: { on in Task { await model.policyType("internal", allow: on) } }))
                }
            }
            Section("按会话名称放行") {
                ForEach(model.effectiveTitles, id: \.self) { t in
                    if editingTitle == t {
                        HStack {
                            TextField("新标题（与客户端完全一致）", text: $editTitleText)
                            Button("保存") {
                                let old = t, new = editTitleText.trimmingCharacters(in: .whitespaces)
                                editingTitle = nil
                                guard !new.isEmpty, new != old else { return }
                                Task { await model.policyRename(oldTitle: old, newTitle: new) }
                            }
                            .disabled(editTitleText.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("取消") { editingTitle = nil }
                        }
                    } else {
                        HStack {
                            Text(t)
                            if t == model.compiledTitle { Text("内置").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if t != model.compiledTitle {
                                Button("修改") { editingTitle = t; editTitleText = t }
                                Button("收回", role: .destructive) { Task { await model.policy("deny", title: t) } }
                            }
                        }
                    }
                }
                HStack {
                    Picker("放行会话", selection: $allowChoice) {
                        Text("从会话列表选择…").tag("")
                        ForEach(model.conversations.compactMap { $0["title"] }.filter { !model.effectiveTitles.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Button("允许发送") { let t = allowChoice; allowChoice = ""; Task { await model.policy("allow", title: t) } }.disabled(allowChoice.isEmpty)
                    Button("刷新会话列表") { Task { await model.loadConversations() } }
                }
                HStack {
                    TextField("手动输入标题（与客户端完全一致）", text: $title)
                    Button("允许发送") { let t = title; title = ""; Task { await model.policy("allow", title: t) } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("放行一个真实客户或群，就是允许守护进程向它发消息——这是你在本机的决定（类型 / chatId / externalUserId 规则见下方两节）。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("按群 ID 放行") {
                ForEach(model.allowedChatIds, id: \.self) { id in
                    HStack { Text(id); Spacer(); Button("收回", role: .destructive) { Task { await model.policyId(kind: "chat-id", value: id, allow: false) } } }
                }
                HStack {
                    TextField("chatId", text: $chatId)
                    Button("允许") { let v = chatId; chatId = ""; Task { await model.policyId(kind: "chat-id", value: v, allow: true) } }
                        .disabled(chatId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("按客户 ID 放行") {
                ForEach(model.allowedExternalUserIds, id: \.self) { id in
                    HStack { Text(id); Spacer(); Button("收回", role: .destructive) { Task { await model.policyId(kind: "external-user-id", value: id, allow: false) } } }
                }
                HStack {
                    TextField("externalUserId", text: $externalUserId)
                    Button("允许") { let v = externalUserId; externalUserId = ""; Task { await model.policyId(kind: "external-user-id", value: v, allow: true) } }
                        .disabled(externalUserId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("高级选项") {
                Toggle("打开或读取会话也要经过白名单", isOn: Binding(
                    get: { model.gateReads }, set: { on in Task { await model.policyReads(gate: on) } }))
                Toggle("允许远程修改本机策略", isOn: Binding(
                    get: { model.remoteEdits }, set: { on in Task { await model.policyRemote(enable: on); loadRequests() } }))
                DisclosureGroup("查看原始策略") {
                    Text(model.policyText.isEmpty ? "点击刷新" : model.policyText)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("刷新原始策略") { Task { await model.loadPolicy() } }
                }
            }
            }
            if pane == .files {
            Section("允许下载的文件来源") {
                Text("发送文件只接受名单内的 HTTPS 域名；名单为空时全部拒绝。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.allowedHosts, id: \.self) { h in
                    HStack { Text(h); Spacer(); Button("收回", role: .destructive) { Task { await model.policyHosts(deny: h) } } }
                }
                HStack {
                    TextField("域名（精确 cdn.example，或后缀 .aliyuncs.com）", text: $host)
                    Button("允许") { let h = host; host = ""; Task { await model.policyHosts(allow: h) } }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            }
            if pane == .requests {
            Section("新客户请求自动化") {
                Picker("自动接受", selection: $autoAccept) {
                    Text("关（只上报角标数）").tag("off")
                    Text("全部接受").tag("all")
                    Text("按规则（下面的名单 / 关键词）").tag("rules")
                    Text("远程决定（只发事件，Java 逐条接受）").tag("remote")
                }
                Picker("接受后自动拉群", selection: $autoGroup) {
                    Text("关").tag("off")
                    Text("一人一群").tag("perPerson")
                }
                HStack {
                    Text("候选来自客户端：").font(.caption).foregroundStyle(.secondary)
                    Button("读取我的客户") { Task { await model.loadContacts() } }
                    Button("读取通讯录全部（含同事）") { Task { await model.loadContacts(scope: "all") } }
                    Text("读取时企微会打开选人面板再取消，前台会闪一下。").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("自动接受名单：按规则模式下只接受这些昵称（新的客户卡片上的名字；逗号分隔或点下方勾选）", text: $allowNames)
                    picker(model.contacts, list: $allowNames, empty: "先点「读取我的客户」，再勾选要自动接受的人；留空则只看打招呼语关键词。")
                }
                TextField("打招呼语关键词：打招呼语包含其一即接受（逗号分隔，可留空）", text: $keywords)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("拉群默认成员：每个自动群都拉进来的人（按选人面板里的名字；一人一群至少 1 个，否则客户端只开单聊）", text: $defaultMembers)
                    picker(model.pickerRows, list: $defaultMembers, empty: "先点「读取通讯录全部」，再勾选同事或客户作为默认成员。")
                }
                TextField("群名模板：{客户名} 会换成客户名；默认 {客户名}群聊（例：{客户名}-售后）", text: $template)
                TextField("每小时接受上限", text: $maxAccepts)
                HStack {
                    Button("保存自动化设置") {
                        var args = ["--auto-accept", autoAccept, "--auto-group", autoGroup, "--group-name-template", template.isEmpty ? ContactRequestPolicy.defaultTemplate : template,
                                    "--max-accepts-per-hour", maxAccepts, "--clear-lists"]
                        let names = split(allowNames), kws = split(keywords), members = split(defaultMembers)
                        if !names.isEmpty { args += ["--allow-name"] + names }
                        if !kws.isEmpty { args += ["--greeting-contains"] + kws }
                        if !members.isEmpty { args += ["--default-member"] + members }
                        Task { await model.policyRequests(args); loadRequests() }
                    }
                    Button("重新读取") { loadRequests() }
                }
                Text("接受与建群都影响真实客户：默认全关，开启是你在本机的决定。").font(.caption).foregroundStyle(.orange)
            }
            }
            }
            .formStyle(.grouped)
        }
        .task { await model.loadPolicy(); loadRequests(); if model.conversations.isEmpty { await model.loadConversations() } }
    }
}

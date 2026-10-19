import SwiftUI

struct ContactsView: View {
    private enum Pane: String, CaseIterable {
        case requests = "新客户"
        case add = "按手机号添加"
        case createGroup = "创建群聊"
        case addMembers = "添加群成员"
    }

    @Environment(ConsoleModel.self) private var model
    @State private var pane: Pane = .requests
    @State private var chosen: Set<String> = []
    @State private var groupName = ""
    @State private var phone = ""
    @State private var source = "wechat"
    @State private var greeting = ""
    /// Start with no target and a dry run so the user makes the final add decision.
    @State private var addTarget = ""
    @State private var addMembersText = ""
    @State private var addDryRun = true
    @State private var addMembersResult = ""

    /// Include policy-allowed titles when the client fails to tag a group row.
    var addMembersTargets: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for c in model.conversations {
            guard let t = c["title"], !t.isEmpty, c["conversationType"] == "group" || model.effectiveTitles.contains(t) else { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("通讯录任务", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 720)
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let hint = model.daemonHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                switch pane {
                case .requests: requestsPane
                case .add: addPane
                case .createGroup: createGroupPane
                case .addMembers: addMembersPane
                }
            }
            .frame(maxWidth: 1200, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await model.loadPolicy() }
    }

    private var requestsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新的客户").font(.title3.weight(.semibold))
                    Text("从企业微信“通讯录 › 新的客户”读取申请。读取时客户端会短暂切换视图。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("读取申请") { Task { await model.loadRequests() } }
                    .disabled(model.busy)
            }
            if model.requests.isEmpty {
                ContentUnavailableView("还没有读取到申请", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("点击“读取申请”查看客户端当前显示的新客户。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.requests, id: \.["name"]) { request in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request["name"] ?? "-").fontWeight(.medium)
                            Text(request["greeting"] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(request["source"] ?? "").font(.caption).foregroundStyle(.secondary)
                        if request["status"] == "pending" {
                            Button("接受") {
                                if let name = request["name"] { Task { await model.acceptRequest(name: name) } }
                            }
                            .disabled(model.busy)
                        } else {
                            Text("已添加").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var addPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("按手机号添加客户").font(.title3.weight(.semibold))
                Text("任何号码都可以搜索和发送添加申请；对方通不通过由对方决定。")
                    .font(.subheadline).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("手机号", text: $phone)
                        Picker("来源", selection: $source) {
                            Text("微信").tag("wechat")
                            Text("企业微信").tag("wecom")
                            Text("任一").tag("any")
                        }
                        TextField("验证消息（可留空）", text: $greeting)
                        HStack {
                            Button("只搜索") {
                                let p = phone, s = source, g = greeting
                                Task { await model.contactAdd(phone: p, source: s, greeting: g, dryRun: true) }
                            }
                            .disabled(phone.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                            Button("发送添加申请") {
                                model.requestContactAdd(phone: phone, source: source, greeting: greeting)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(phone.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                        }
                        Text("「发送添加申请」会以本企业微信账号向对方发好友申请，发出后收不回，发送前会再确认一次。每小时最多添加 \(model.maxAddsPerHour) 次、搜索 \(model.maxSearchesPerHour) 次。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                }
                if !model.addResult.isEmpty { ResultPane(title: "添加结果", text: model.addResult, minHeight: 80) }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .confirmationDialog("发送添加申请？",
                            isPresented: Binding(get: { model.pendingContactAdd != nil },
                                                 set: { if !$0 { model.pendingContactAdd = nil } }),
                            presenting: model.pendingContactAdd) { pending in
            // Dismissing the dialog clears pendingContactAdd, maybe before this runs: send what it showed.
            Button("发送", role: .destructive) { Task { await model.confirmContactAdd(pending) } }
            Button("取消", role: .cancel) { model.pendingContactAdd = nil }
        } message: { pending in
            Text("将以本企业微信账号向 \(pending.maskedPhone)（来源：\(Self.sourceName(pending.source))）发送好友申请，发出后收不回。")
        }
    }

    private static func sourceName(_ source: String) -> String {
        switch source {
        case "wechat": "微信"
        case "wecom": "企业微信"
        default: "任一"
        }
    }

    private var createGroupPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从好友列表创建群聊").font(.title3.weight(.semibold))
                    Text("至少选择两位成员。群名由客户端生成，填写的名称只写入命令记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("读取好友列表") { Task { await model.loadContacts() } }
                    .disabled(model.busy)
            }
            if model.contacts.isEmpty {
                ContentUnavailableView("还没有好友列表", systemImage: "person.2",
                                       description: Text("点击“读取好友列表”后再选择成员。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.contacts, id: \.["name"]) { contact in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { chosen.contains(contact["name"] ?? "") },
                            set: { on in
                                if let name = contact["name"] {
                                    if on { chosen.insert(name) } else { chosen.remove(name) }
                                }
                            }
                        )) { Text(contact["name"] ?? "-") }
                        Spacer()
                        Text(contact["tag"] ?? contact["source"] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
            HStack {
                TextField("群名备注（可留空）", text: $groupName)
                    .frame(maxWidth: 360)
                Button("用已选 \(chosen.count) 人建群") {
                    let members = model.contacts.compactMap { $0["name"] }.filter { chosen.contains($0) }
                    let name = groupName
                    Task { await model.createGroup(members: members, name: name.isEmpty ? nil : name) }
                }
                .disabled(chosen.count < 2 || model.busy)
            }
            if !model.groupResult.isEmpty { ResultPane(title: "建群结果", text: model.groupResult, minHeight: 80) }
        }
    }

    private var addMembersPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("添加到现有群").font(.title3.weight(.semibold))
                Text("选择目标群和成员。默认先试跑，试跑只选中候选并取消。")
                    .font(.subheadline).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Picker("目标群", selection: $addTarget) {
                                Text("从会话列表选择…").tag("")
                                ForEach(addMembersTargets, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            Button("刷新会话列表") { Task { await model.loadConversations() } }
                        }
                        TextField("成员姓名（逗号、，或、分隔）", text: $addMembersText)
                        Toggle("先试跑，不按客户端“确定”", isOn: $addDryRun)
                        Button(addDryRun ? "试跑添加" : "确认添加成员") {
                            let target = addTarget, members = addMembersText, dryRun = addDryRun
                            Task { addMembersResult = await model.addGroupMembers(target: target, members: members, dryRun: dryRun) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(addTarget.isEmpty || addMembersText.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                }
                Text("目标群须先在策略页放行。关闭试跑后，操作会真正向群里添加成员。")
                    .font(.caption).foregroundStyle(.orange)
                if !addMembersResult.isEmpty { ResultPane(title: "添加成员结果", text: addMembersResult, minHeight: 100) }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

import AppKit
import ControlCore
import SwiftUI
import WeComAdapter

struct ConversationsView: View {
    private static let newestMessageAnchor = "newest-message-anchor"
    @Environment(ConsoleModel.self) private var model
    @State private var selected: String?
    @State private var newName = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Button("读取列表") { Task { await model.loadConversations() } }
                    Menu("切换会话") {
                        Button("上一会话") { Task { await model.navigate(.previousConversation) } }
                        Button("下一会话") { Task { await model.navigate(.nextConversation) } }
                        Button("下一未读") { Task { await model.navigate(.nextUnreadConversation) } }
                    }
                }
                List(model.conversations, id: \.["index"], selection: $selected) { row in
                    HStack {
                        ConversationAvatarView(title: row["title"] ?? "", kind: row["conversationType"] ?? "", size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row["title"] ?? "-").bold(row["selected"] == "true").lineLimit(1)
                            if let preview = row["preview"], !preview.isEmpty {
                                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let time = row["timeLabel"] { Text(time).font(.caption2).foregroundStyle(.secondary) }
                        if let b = row["badge"], !b.isEmpty {
                            Text(b).padding(.horizontal, 6).background(.red.opacity(0.2)).clipShape(Capsule())
                        }
                    }
                    .tag(row["index"] ?? "")
                }
                Button("打开选中会话") {
                    if let title = model.conversations.first(where: { $0["index"] == selected })?["title"] { Task { await model.open(title) } }
                }
                .disabled(selected == nil || model.busy)
                Text("打开后才能读取消息。若策略限制读取，请在“策略”页查看。")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let hint = model.daemonHint { Text(hint).font(.caption).foregroundStyle(.orange) }
            }
            .frame(minWidth: 260, idealWidth: 310, maxWidth: 400)
            VStack(alignment: .leading) {
                HStack {
                    Text("活动会话：\(model.activeTitle.isEmpty ? "-" : model.activeTitle)").bold()
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("正在读取") }
                    Spacer()
                    Button("读 30 条") { Task { await model.loadHistory() } }
                        .disabled(model.busy)
                    Button("回滚读 60 条") { Task { await model.loadHistory(limit: 60, scrollback: true) } }
                        .disabled(model.busy)
                }
                if model.activeIsGroup { DisclosureGroup("重命名当前群聊") {
                    HStack {
                        TextField("新的群名", text: $newName)
                            .disabled(!model.activeIsGroup)
                        Button("改群名") { let n = newName; Task { await model.renameActiveGroup(to: n); newName = "" } }
                            .disabled(!model.activeIsGroup || newName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                    }
                    Text(model.activeIsGroup ? "群内所有人都会看到新名称；只对测试群操作。" : "请先打开群会话。")
                        .font(.caption).foregroundStyle(model.activeIsGroup ? .orange : .secondary)
                } }
                if !model.renameResult.isEmpty { ResultPane(title: "group.rename 结果", text: model.renameResult, minHeight: 60) }
                if let e = model.historyError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(model.messages, id: \.["index"]) { m in
                                ChatMessageRow(message: m, activeTitle: model.activeTitle)
                            }
                            Color.clear.frame(height: 1).id(Self.newestMessageAnchor)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 16)
                    }
                    .background(Color.primary.opacity(0.025))
                    .overlay {
                        if model.messages.isEmpty, let notice = model.historyNotice {
                            ContentUnavailableView("未读到消息行", systemImage: "bubble.left.and.bubble.right", description: Text(notice))
                        }
                    }
                    .task(id: model.latestHistoryRevision) {
                        // A sentinel remains addressable in the lazy stack
                        // before the newest row has been laid out. Scrollback
                        // does not advance the revision or move this view.
                        guard !model.messages.isEmpty else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(Self.newestMessageAnchor, anchor: .bottom)
                    }
                }
                .id(model.historyViewportID)
            }
            .frame(minWidth: 520)
        }
    }

    /// B13: the caption above a media / file / video row — file name and size, or duration, from message.history.
    static func label(for m: [String: String], resolvedMediaKind: String? = nil) -> String {
        switch m["kind"] {
        case "file":
            let type = switch m["fileType"]?.lowercased() {
            case "pdf": "PDF 文档"
            case "word", "doc", "docx": "Word 文档"
            case "excel", "xls", "xlsx": "Excel 表格"
            case "ppt", "pptx", "powerpoint": "演示文稿"
            default: "文件"
            }
            return "📎 \(type) · \(m["fileName"] ?? "未命名")\(m["fileSize"].map { " · \($0)" } ?? "")"
        case "video": return "🎬 视频\(m["duration"].map { " · \($0)" } ?? "")"
        case "media": return m["mediaType"] == "image" || resolvedMediaKind == "image" ? "图片" : "未识别媒体"
        default: return "消息"
        }
    }
}

/// The file transfer assistant is a self conversation, so even rows whose AX direction is unknown
/// appear on the sender side. Other conversations retain the observed direction.
struct ChatMessageRow: View {
    @Environment(ConsoleModel.self) private var model
    let message: [String: String]
    let activeTitle: String

    static func displayDirection(_ raw: String?, activeTitle: String) -> String {
        activeTitle == WeComClient.fileTransferAssistantTitle ? "outbound" : (raw ?? "unknown")
    }

    private var direction: String { Self.displayDirection(message["direction"], activeTitle: activeTitle) }
    private var outgoing: Bool { direction == "outbound" }
    private var incoming: Bool { direction == "inbound" }
    private var sender: String { outgoing ? "我" : (message["sender"] ?? (activeTitle.isEmpty ? "对方" : activeTitle)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if outgoing || (!outgoing && !incoming) { Spacer(minLength: 32) }
            if incoming { ConversationAvatarView(title: sender, kind: "person", size: 26) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if incoming || outgoing { Text(sender) }
                    else { Label("方向未确认", systemImage: "questionmark.circle") }
                    if let time = message["timeLabel"], !time.isEmpty { Text(time) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                    Group {
                        if ["media", "file", "video"].contains(message["kind"] ?? "") {
                            MediaRowView(messageKey: message["messageKey"] ?? "", kind: message["kind"] ?? "",
                                         label: ConversationsView.label(for: message,
                                            resolvedMediaKind: model.mediaLinks[message["messageKey"] ?? ""]?.kind))
                        } else {
                            Text(message["text"] ?? (message["readError"] == nil ? "" : "消息内容暂时无法读取"))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if message["readError"] != nil {
                        Text("客户端未返回完整内容，请稍后重试读取。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14).fill(outgoing ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08)))
            }
            .frame(maxWidth: 460, alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Show signed media addresses only when requested. Reading or scrolling history never downloads
/// pictures or video and never starts a player inside the diagnostic console.
struct MediaRowView: View {
    @Environment(ConsoleModel.self) private var model
    let messageKey: String
    /// message.history's row kind: `media` | `file` | `video`.
    let kind: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: kind == "file" ? "doc" : kind == "video" ? "film" : "photo")
                .font(.subheadline).lineLimit(2)
            if let link = model.mediaLinks[messageKey] {
                if let address = link.openURL ?? (kind == "video" ? link.url : nil) {
                    if kind == "video", link.bodyURL == nil {
                        Text("仅有封面地址，视频正片尚未缓存。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(address).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Button("复制地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }.font(.caption)
                }
                Button("刷新地址") { Task { await model.loadMedia(for: messageKey, force: true) } }
                    .font(.caption).disabled(model.isMediaLoading(messageKey))
            } else if let code = model.mediaErrors[messageKey] {
                Text(ConsoleModel.mediaReadMessage(code)).font(.caption).foregroundStyle(.orange)
                Button("重试取地址") { Task { await model.loadMedia(for: messageKey, force: true) } }
                    .font(.caption).disabled(model.isMediaLoading(messageKey))
            } else if model.isMediaLoading(messageKey) {
                ProgressView("正在获取地址…").controlSize(.small)
            } else if messageKey.isEmpty {
                Text("本次读取不完整，重试后可获取地址。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("获取地址") { Task { await model.loadMedia(for: messageKey) } }
                    .font(.caption)
            }
        }
    }
}

/// AX exposes an avatar element's position, but not its pixels or a stable image URL. Use a distinct,
/// deterministic identity tile until a real image is available; never substitute a guessed cache picture.
struct ConversationAvatarView: View {
    let title: String
    let kind: String
    let size: CGFloat

    private var symbol: String? {
        if kind == "group" { return "person.2.fill" }
        if title == "文件传输助手" { return "tray.full.fill" }
        if kind == "unknown" || title.isEmpty { return "person.fill" }
        return nil
    }

    private var color: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .orange, .green]
        let hash = title.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(color.gradient)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium))
            } else {
                Text(String(title.prefix(1))).font(.system(size: size * 0.47, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityLabel(title.isEmpty ? "头像" : "\(title) 的头像占位图")
    }
}

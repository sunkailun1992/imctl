import AppKit
import AXKit
import ControlCore
import Foundation
import MCPTransport
import MQTTTransport
import Observation
import OSSClient
import WeComAPI
import WeComAdapter

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    var time = Date()
    var title: String
    var body: String
    var isError = false
}

struct EventRow: Identifiable, Equatable {
    var id: Int64
    var tsMs: Int64
    var kind: String
    var payload: String
}

/// All console state. Commands run off the main actor; results land back here.
/// Anything that changes the client goes through `rpc` (the daemon socket);
/// launchd and policy edits go through the CLI; the rest is read-only.
@MainActor @Observable final class ConsoleModel {
    // status
    var state: DaemonState?
    var stateError: String?
    var agent: DaemonControl.AgentStatus?
    var agentError: String?
    var socketReachable = false
    var describe: [String: String] = [:]
    var consoleTrusted = false
    var clientRunning = false
    var mqttEnrolled = false
    var proxyEnrolled = false
    /// B13: whether `oss.json` exists on this Mac (whether the OSS section shows current values / the send-file and media tests are enabled).
    var ossEnrolled = false
    /// Cloud vision is opt-in and configured only on this Mac; this flag never carries a key.
    var visionEnrolled = false
    var visionEnabled = false
    var visionFullWindowEnabled = false
    var visionProvider = CloudVisionProvider.qwen.rawValue
    /// B13: output of the last `imctl oss test` probe.
    var ossTestResult = ""
    // conversations
    var conversations: [[String: String]] = []
    var activeTitle = ""
    var messages: [[String: String]] = []
    /// Advances after a normal history read so the conversation view can reveal the newest row.
    /// Explicit scrollback keeps the user's position in older history.
    var latestHistoryRevision = 0
    struct HistoryViewportID: Hashable {
        var title: String
        var latestRevision: Int
    }
    /// Recreate the SwiftUI viewport when the conversation changes or a new
    /// latest-page read arrives. A retained offset from a longer chat can hide
    /// every row of a shorter chat even when `messages` contains those rows.
    var historyViewportID: HistoryViewportID {
        HistoryViewportID(title: activeTitle, latestRevision: latestHistoryRevision)
    }
    /// A later selection/read wins even if an earlier socket call finishes last.
    private var conversationRevision = 0
    private var historyRequestRevision = 0
    /// Why the message list is empty after a failed read, shown in the message pane (user report 2026-09-15: the
    /// previous conversation's messages stayed on screen after switching).
    var historyError: String?
    /// A successful history call may still return no AX message rows while the
    /// client pane is loading. Keep that visible without claiming the chat is empty.
    var historyNotice: String?
    // events
    var events: [EventRow] = []
    var lastEventId: Int64 = 0
    var tailing = false
    // contacts (B7)
    var contacts: [[String: String]] = []
    /// Every picker row (B9, `contact.list scope:all`): colleagues too, for the default-member picker.
    var pickerRows: [[String: String]] = []
    /// Result of the last group.rename from the conversations page.
    var renameResult = ""
    /// B13: what message.media returned for a row: a signed URL requested explicitly from the console.
    struct MediaLink: Equatable {
        var kind: String; var fileName: String; var url: String; var expiresAtMs: Int64; var duration: String?
        var bytes: Int64 = 0
        var bodyURL: String? = nil
        var bodyStatus: String? = nil

        var openURL: String? { kind == "video" ? bodyURL : url }
        var openFileName: String {
            guard kind == "video" else { return fileName }
            let ext = bodyURL.flatMap { URL(string: $0)?.pathExtension.lowercased() } == "mov" ? "mov" : "mp4"
            return "video.\(ext)"
        }
    }
    var mediaLinks: [String: MediaLink] = [:]
    var mediaImages: [String: NSImage] = [:]
    /// Wire error code only. The daemon's message can contain a local path, message key or file name.
    var mediaErrors: [String: String] = [:]
    var mediaOpenErrors: [String: String] = [:]
    var mediaLocalFiles: [String: URL] = [:]
    private var mediaLoading: Set<String> = []
    private var mediaOpening: Set<String> = []
    func isMediaLoading(_ key: String) -> Bool { mediaLoading.contains(key) }
    func isMediaOpening(_ key: String) -> Bool { mediaOpening.contains(key) }
    var requests: [[String: String]] = []
    var groupResult = ""
    /// B12: result of the last contact.add from the 通讯录 page.
    var addResult = ""
    // policy / diagnostics / log
    var policyText = ""
    /// `policy.get` as the daemon sees it (B10): the send allowlist and switches the 策略 page edits.
    var policyState: [String: JSONValue] = [:]
    var diagnostics: DiagnosticsReport?
    var log: [LogEntry] = []
    var busy = false
    private var pendingRPCCount = 0
    /// Last failed call (method + error), shown inline on the page that issued it.
    var lastError: String?
    /// Output of the last launchd / CLI action (install, restart, uninstall), shown on the status page.
    var lastAgentAction: (title: String, output: String, failed: Bool)?

    let cli = CLIRunner.sibling()
    /// Tests point the model at a fake daemon socket.
    var socketPathOverride: String?
    var service: RPCService {
        let reported = state?.socket ?? ""
        return RPCService(socketPath: socketPathOverride ?? (reported.isEmpty ? ConsolePaths.socket : reported))
    }
    var control: DaemonControl { DaemonControl(cli: cli) }

    var menuBarSymbol: String {
        guard let state, state.isAlive else { return "exclamationmark.triangle" }
        return state.pausedReasons.isEmpty ? "message.badge.waveform" : "pause.circle"
    }

    /// Why the daemon cannot serve client reads right now, if the state file says so.
    var daemonHint: String? {
        guard let state else { return "没有 state.json：守护进程未运行（状态页 › 安装 / 更新守护进程）" }
        if !state.isAlive { return "守护进程不在运行（状态页 › 重启）" }
        if state.trusted == false { return "守护进程未获辅助功能授权：系统设置 › 隐私与安全性 › 辅助功能 勾选 imctld" }
        if state.pausedReasons.contains("system") { return "守护进程处于 system 暂停（客户端不可读：多半是未授权或客户端未运行）" }
        if state.trusted == nil { return "旧版守护进程（不上报授权状态）：请装包后在状态页「安装 / 更新守护进程」切换" }
        return nil
    }

    var statusLine: String {
        guard let state, state.isAlive else { return "守护进程未运行" }
        let paused = state.pausedReasons.isEmpty ? "运行中" : "暂停 [\(state.pausedReasons.joined(separator: ","))]"
        return "\(paused) · pid \(state.pid) · 事件 \(state.lastEventId ?? 0)" + (state.trusted == false ? " · 未授权辅助功能" : "")
    }

    // MARK: Refresh

    /// Local facts only: the state file and this Mac. No socket call, no
    /// subprocess — safe to run every few seconds (`controller.describe` is a
    /// command that leaves records and events; polling it every 3 s flooded the
    /// event stream with `command.state`, 2026-09-15).
    /// launchd's view of the daemon (`imctl agent status`); tests replace it.
    var readAgentStatus: (@Sendable () throws -> DaemonControl.AgentStatus)?

    func refreshAgent() async {
        let control = self.control
        let read = readAgentStatus ?? { try control.status() }
        do { agent = try await Task.detached { try read() }.value; agentError = nil }
        catch { agent = nil; agentError = String(describing: error) }
    }

    func refreshLocal() {
        do { state = try DaemonState.load(from: ConsolePaths.stateFile); stateError = nil }
        catch { state = nil; stateError = String(describing: error) }
        consoleTrusted = LiveAXBackend().isProcessTrusted(prompt: false)
        clientRunning = AXApp.runningApplication(bundleID: WeComClient.bundleID) != nil
        mqttEnrolled = FileManager.default.fileExists(atPath: MQTTSettings.defaultURL.path)
        proxyEnrolled = FileManager.default.fileExists(atPath: WeComProxySettings.defaultURL.path)
        ossEnrolled = FileManager.default.fileExists(atPath: OSSSettings.defaultURL.path)
        visionEnrolled = FileManager.default.fileExists(atPath: CloudVisionSettings.defaultURL.path)
        let vision = try? CloudVisionSettings.loadOrDefault()
        visionEnabled = vision?.cloudEnabled == true
        visionFullWindowEnabled = vision?.fullWindowEnabled == true
        visionProvider = vision?.provider.rawValue ?? CloudVisionProvider.qwen.rawValue
    }

    /// Full refresh: local facts plus launchd status and one `controller.describe`.
    func refresh() async {
        refreshLocal()
        await refreshAgent()
        if let result = await rpc("controller.describe", log: false) {
            socketReachable = true
            describe = result.objectValue?["result"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        } else {
            socketReachable = false
        }
    }

    /// One JSON-RPC call through the daemon socket, logged; nil on error (also logged).
    @discardableResult
    func rpc(_ method: String, _ params: [String: JSONValue] = [:], log shouldLog: Bool = true,
             timeout: TimeInterval? = nil) async -> JSONValue? {
        var service = self.service
        if let timeout { service.timeout = timeout }
        pendingRPCCount += 1
        busy = true
        defer {
            pendingRPCCount -= 1
            busy = pendingRPCCount > 0
        }
        do {
            let result = try await Task.detached { try service.call(method, params) }.value
            if shouldLog { append(method, RPCService.pretty(result)); lastError = nil }
            return result
        } catch {
            if shouldLog || !(error is UnixSocketClient.TransportError) { append(method, String(describing: error), error: true) }
            if shouldLog { lastError = "\(method): \(error)" }
            return nil
        }
    }

    func append(_ title: String, _ body: String, error: Bool = false) {
        log.append(LogEntry(title: title, body: body, isError: error))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Conversations

    func loadConversations() async {
        guard let r = await rpc("conversation.list") else { return }
        conversations = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
        if let current = conversations.first(where: { $0["selected"] == "true" })?["title"], current != activeTitle {
            conversationRevision += 1
            historyRequestRevision += 1
            activeTitle = current
            messages = []
            historyError = nil
            historyNotice = nil
        }
    }

    /// Switching drops the previous conversation's messages first; a refused switch explains the way around it.
    func open(_ target: String) async {
        let alreadyActive = activeTitle == target && conversations.contains {
            $0["title"] == target && $0["selected"] == "true"
        }
        conversationRevision += 1
        historyRequestRevision += 1
        let revision = conversationRevision
        messages = []; historyError = nil; historyNotice = nil
        // The selected row is already open in WeCom. Reading history directly avoids
        // a second full AX message walk in conversation.read before message.history.
        if alreadyActive { await loadHistory(); return }
        guard let r = await rpc("conversation.read", ["target": .string(target)], timeout: 90) else {
            guard revision == conversationRevision else { return }
            historyError = Self.readHint(for: lastError)
            return
        }
        guard revision == conversationRevision else { return }
        if let failed = Self.failure(of: r) {
            lastError = "conversation.read: \(failed)"
            if failed.contains("TARGET_NOT_ALLOWED"), await reach(target, expectedRevision: revision) {
                guard revision == conversationRevision else { return }
                lastError = nil; return
            }
            guard revision == conversationRevision else { return }
            historyError = Self.readHint(for: lastError)
            return
        }
        activeTitle = r.objectValue?["result"]?.objectValue?["active"]?.stringValue ?? target
        await loadHistory()
    }

    /// Methods that run through the executor answer with a command record: a
    /// failure is `state:"failed"` plus `error{code, message}` inside a normal
    /// response, not a transport error. nil when the record succeeded.
    static func failure(of response: JSONValue) -> String? {
        guard let err = response.objectValue?["error"]?.objectValue else { return nil }
        let code = err["code"]?.stringValue ?? "ERROR", message = err["message"]?.stringValue ?? ""
        return "\(code): \(message)"
    }

    /// Reading the active conversation is not gated; switching to one is (`selectConversation`).
    static func readHint(for error: String?) -> String? {
        guard let error else { return nil }
        if error.contains("TARGET_NOT_ALLOWED") {
            return error + "\n该会话不在白名单 / 策略内：用 上一 / 下一会话 切换到它再读，或在「策略」页放行标题。"
        }
        if error.contains("no response before the timeout") {
            return error + "\n企微辅助功能读取超时；守护进程可能仍在处理。稍后点「读 30 条」重试。"
        }
        return error
    }

    func loadHistory(limit: Int = 30, scrollback: Bool = false) async {
        historyRequestRevision += 1
        let requestRevision = historyRequestRevision
        let conversationAtStart = conversationRevision
        let titleAtStart = activeTitle
        guard let r = await rpc("message.history", ["limit": .number(Double(limit)), "scrollback": .bool(scrollback)], timeout: 60) else {
            guard requestRevision == historyRequestRevision, conversationAtStart == conversationRevision, titleAtStart == activeTitle else { return }
            messages = []; historyError = Self.readHint(for: lastError); historyNotice = nil
            return
        }
        guard requestRevision == historyRequestRevision, conversationAtStart == conversationRevision, titleAtStart == activeTitle else { return }
        if let failed = Self.failure(of: r) {
            messages = []; lastError = "message.history: \(failed)"; historyError = lastError; historyNotice = nil
            return
        }
        messages = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
        historyError = nil
        historyNotice = messages.isEmpty ? "这次没有读到消息行。客户端消息区可能仍在加载，或暂时没有向辅助功能提供内容；稍后可再点「读 30 条」。" : nil
        if !scrollback && !messages.isEmpty { latestHistoryRevision += 1 }
    }

    /// After a switch the message pane follows the new active conversation.
    func navigate(_ action: NavigateAction) async {
        conversationRevision += 1
        historyRequestRevision += 1
        let revision = conversationRevision
        messages = []
        historyError = nil
        historyNotice = nil
        guard let r = await rpc("client.navigate", RPCService.navigateParams(action)) else { return }
        guard revision == conversationRevision else { return }
        if let failed = Self.failure(of: r) { lastError = "client.navigate: \(failed)"; return }
        if let after = r.objectValue?["result"]?.objectValue?["after"]?.stringValue {
            if after != activeTitle { messages = [] }
            activeTitle = after
        }
        await loadConversations()
        await loadHistory()
    }

    func send(target: String, text: String) async -> String {
        guard let r = await rpc("message.send", RPCService.sendParams(target: target, text: text)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    /// B13: message.sendFile from the 发送 page (url or ossKey, optional name).
    func sendFile(target: String, url: String, ossKey: String, fileName: String) async -> String {
        guard let r = await rpc("message.sendFile", RPCService.sendFileParams(target: target, url: url, ossKey: ossKey, fileName: fileName)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    var allowedHosts: [String] { policyState["sendFile"]?.objectValue?["allowedHosts"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// B13: the file-source host allowlist (policy.json › sendFile.allowedHosts), edited via `imctl policy hosts`.
    func policyHosts(allow: String? = nil, deny: String? = nil) async {
        let cli = self.cli
        let args = Self.policyHostsArgs(allow: allow, deny: deny)
        let result = try? await Task.detached { try cli.run(args) }.value
        append("policy hosts", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    /// Pure argument builder for `policyHosts`, split out so the CLI flag wiring is testable without a subprocess.
    static func policyHostsArgs(allow: String? = nil, deny: String? = nil) -> [String] {
        var args = ["policy", "hosts"]
        if let allow { args += ["--allow", allow] }
        if let deny { args += ["--deny", deny] }
        return args
    }

    /// B13: round-trips a 1 KB probe through the configured bucket (`imctl oss test`).
    func ossTest() async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["oss", "test"]) }.value
        ossTestResult = result?.output ?? "imctl oss test failed to start"
        append("oss test", ossTestResult, error: (result?.status ?? 1) != 0)
    }

    /// B11: one paced send per target through the daemon's message.broadcast; the result lists every target.
    func broadcast(targets: [String], text: String, intervalMs: Int) async -> String {
        guard let r = await rpc("message.broadcast", RPCService.broadcastParams(targets: targets, text: text, intervalMs: intervalMs)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    /// The daemon's grants (controller.permissions); `prompt` triggers the dialogs at setup time.
    var permissions: [String: String] = [:]
    func checkPermissions(prompt: Bool = false) async {
        guard let r = await rpc("controller.permissions", ["prompt": .bool(prompt)], log: false) else { return }
        permissions = r.objectValue?["result"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }

    /// B52: the last readiness report, in memory only; the console never fetches it on its own (it can cost a paid vision call).
    var readiness: ReadinessReport?
    var readinessRunning = false

    /// Polls while the live tests run, once per `pollNanoseconds`, at most `maxPolls` extra times.
    func runReadiness(localOnly: Bool = false, refresh: Bool = false, maxPolls: Int = 45, pollNanoseconds: UInt64 = 1_000_000_000) async {
        readinessRunning = true
        defer { readinessRunning = false }
        var params: [String: JSONValue] = ["online": .bool(!localOnly), "refresh": .bool(refresh)]
        for poll in 0...maxPolls {
            guard let value = await rpc(RPCDispatcher.readinessMethod, params, log: false),
                  let text = try? value.serialized(),
                  let report = try? JSONDecoder().decode(ReadinessReport.self, from: Data(text.utf8)) else {
                // B53 review I4b: when the first call fails the old report goes, so the page shows what this Mac
                // shows directly instead of a stale ✔; a later poll that fails keeps what this run already got.
                // Live gate: the fallback reads launchd now, not the last 60-second refresh.
                if poll == 0 {
                    readiness = nil
                    refreshLocal()
                    await refreshAgent()
                }
                return
            }
            readiness = report
            guard report.online.state == "running" else { return }
            params["refresh"] = .bool(false)
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    /// Fix commands with this bundle's CLI (GUI users rarely have `imctl` on PATH).
    func cliCommand(_ command: String) -> String { ReadinessCommandText.substitute(command, cli: cli.executable.path) }

    func runSetup() async {
        let cli = self.cli
        await agentAction("imctl setup") { try cli.run(["setup", "--no-install", "--wait", "5"]) }
        await checkPermissions()
    }

    func openFullDiskAccessSettings() {
        if let url = AXPermission.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func pause() async { await rpc("controller.pause"); await refresh() }
    func resume() async { await rpc("controller.resume"); await refresh() }

    // MARK: Events

    func tailOnce() async {
        guard let r = await rpc("event.replay", RPCService.replayParams(after: lastEventId, limit: 200), log: false) else { return }
        let rows = (r.objectValue?["events"]?.arrayValue ?? []).compactMap { e -> EventRow? in
            guard let o = e.objectValue, let id = o["eventId"]?.numberValue else { return nil }
            return EventRow(id: Int64(id), tsMs: Int64(o["tsMs"]?.numberValue ?? 0), kind: o["kind"]?.stringValue ?? "",
                            payload: o["payload"].map { (try? $0.serialized()) ?? "" } ?? "")
        }
        if let last = rows.last { lastEventId = last.id }
        events.append(contentsOf: rows)
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
    }

    func resetTail(from id: Int64) { events = []; lastEventId = id }

    // MARK: Contacts (all through the daemon socket)

    func loadContacts(scope: String = "customers") async {
        guard let r = await rpc("contact.list", ["limit": .number(200), "scope": .string(scope)]) else { return }
        let rows = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
        if scope == "all" { pickerRows = rows } else { contacts = rows }
    }

    /// B13: the signed link behind a media / file / video row. A first-ever call fetches; a later call skips
    /// unless the cached link `isStale` (review fix: it used to cache forever, handing out a dead URL past
    /// `viewExpireSeconds`) or `force` is set (the row's 刷新 action, which re-requests even a fresh link). A
    /// failed first load records the error the row's 重试 clears before calling back in; a failed refresh
    /// leaves the previous — now stale — link in place instead of blanking the row.
    func loadMedia(for key: String, force: Bool = false) async {
        guard !key.isEmpty, !mediaLoading.contains(key) else { return }
        if !force {
            if let cached = mediaLinks[key] {
                guard Self.isStale(cached, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) else { return }
            } else if mediaErrors[key] != nil {
                return
            }
        }
        mediaLoading.insert(key); defer { mediaLoading.remove(key) }
        var service = self.service
        service.timeout = 330 // the daemon can spend up to 300 s uploading a large file
        let result = await Task.detached { Result { try service.call("message.media", ["messageKey": .string(key)]) } }.value
        let r: JSONValue
        switch result {
        case .success(let value): r = value
        case .failure(let error as UnixSocketClient.RPCError):
            let code = error.data?.objectValue?["code"]?.stringValue ?? "MEDIA_ERROR"
            mediaErrors[key] = code
            return
        case .failure: mediaErrors[key] = "NETWORK_ERROR"; return
        }
        guard let link = Self.link(fromMediaResult: r) else { mediaErrors[key] = "INVALID_MEDIA"; return }
        mediaLinks[key] = link; mediaErrors[key] = nil; mediaOpenErrors[key] = nil
    }

    /// Download and verify a media body once. The view decides whether to play it here or hand a document
    /// to Launch Services; this method never opens another app on its own.
    func prepareMedia(for key: String) async -> URL? {
        guard !mediaOpening.contains(key) else { return nil }
        mediaOpening.insert(key); defer { mediaOpening.remove(key) }
        mediaOpenErrors[key] = nil
        if let local = mediaLocalFiles[key], FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        if let link = mediaLinks[key], Self.isStale(link, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) {
            await loadMedia(for: key, force: true)
        }
        guard let link = mediaLinks[key] else { mediaOpenErrors[key] = Self.mediaReadMessage(mediaErrors[key] ?? "MEDIA_ERROR"); return nil }
        guard !Self.isStale(link, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) else {
            mediaOpenErrors[key] = "附件链接已过期。请重试取回。"
            return nil
        }
        guard let url = link.openURL else {
            mediaOpenErrors[key] = "企微尚未缓存视频正片；请在企微播放一次后点击刷新。"
            return nil
        }
        do {
            let name = link.openFileName
            let local = try await Task.detached { try MediaDownload.materialize(urlString: url, fileName: name, messageKey: key, expectedBytes: link.kind == "video" ? 0 : link.bytes) }.value
            mediaLocalFiles[key] = local
            return local
        } catch { mediaOpenErrors[key] = Self.mediaOpenMessage(error); return nil }
    }

    func openDocument(for key: String) async {
        guard let local = await prepareMedia(for: key) else { return }
        if !NSWorkspace.shared.open(local) { mediaOpenErrors[key] = "已下载，但系统没有可打开此格式的应用。" }
    }

    static func mediaReadMessage(_ code: String) -> String {
        switch code {
        case "MEDIA_NOT_FOUND": return "暂时无法确认这条消息对应的本地附件。可在企微打开原附件后重试。"
        case "OSS_NOT_CONFIGURED": return "本机媒体存储尚未配置。"
        case "MEDIA_TOO_LARGE", "SOURCE_TOO_LARGE": return "附件超过当前大小限制。"
        case "SOURCE_UNSUPPORTED": return "此附件格式暂不支持。"
        case "NETWORK_ERROR", "SOURCE_UNREACHABLE", "OSS_ERROR": return "附件取回失败。请检查网络后重试。"
        default: return "附件暂时无法取回。请稍后重试。"
        }
    }

    static func mediaOpenMessage(_ error: Error) -> String {
        guard let error = error as? ControlError else { return "本机无法打开附件。请重试。" }
        switch error {
        case .sourceNotAllowed: return "附件链接与本机存储设置不一致，请刷新后重试。"
        case .sourceUnsupported: return "附件格式与文件内容不匹配，无法安全打开。"
        case .sourceTooLarge, .mediaTooLarge: return "附件超过当前大小限制。"
        case .sourceUnreachable, .objectStore: return "下载失败。请检查网络后重试。"
        case .ossNotConfigured: return "本机媒体存储尚未配置。"
        case .mediaNotFound: return "附件内容已变化或不完整。请刷新后重试。"
        default: return "本机无法打开附件。请重试。"
        }
    }

    static func link(fromMediaResult r: JSONValue) -> MediaLink? {
        guard let o = r.objectValue, let url = o["url"]?.stringValue, let kind = o["kind"]?.stringValue else { return nil }
        return MediaLink(kind: kind, fileName: o["fileName"]?.stringValue ?? "", url: url, expiresAtMs: Int64(o["expiresAtMs"]?.numberValue ?? 0), duration: o["duration"]?.stringValue,
                         bytes: Int64(o["bytes"]?.numberValue ?? 0), bodyURL: o["bodyUrl"]?.stringValue,
                         bodyStatus: o["body"]?.stringValue)
    }

    /// Pure: OSS's signature on a link is unusable in the last 60 s before `expiresAtMs`, so the row treats it
    /// as stale that early instead of waiting for the daemon to actually refuse it.
    static func isStale(_ link: MediaLink, nowMs: Int64) -> Bool { Double(nowMs) > Double(link.expiresAtMs) - 60_000 }

    /// The active conversation's type, for the rename control: the row named by `activeTitle` (the list may be
    /// older than the last navigate / open — user 2026-09-16 saw the control missing on a group), else the selected row.
    var activeIsGroup: Bool {
        let row = conversations.first { $0["title"] == activeTitle } ?? conversations.first { $0["selected"] == "true" }
        return row?["conversationType"] == "group"
    }

    /// Titles a send may target: the compiled-in one plus policy.json's (B10: shown and edited on the 策略 page).
    var compiledTitle: String { describe["allowlist"] ?? "文件传输助手" }
    var allowedTitles: [String] { policyState["allowedTitles"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var effectiveTitles: [String] { Array(Set([compiledTitle] + allowedTitles)).sorted() }
    var gateReads: Bool { policyState["gateReads"]?.boolValue ?? false }
    var remoteEdits: Bool { policyState["remoteEdits"]?.boolValue ?? false }
    /// B14: the 「全部放开」 switch (policy.json › allowAll) — true only after `imctl policy all --enable` /
    /// the console's confirmed switch; `policy.set` never sets it, so this always reflects a local decision.
    var allowAll: Bool { policyState["allowAll"]?.boolValue ?? false }
    /// B14: 按类型放行 (policy.json › allowedTypes), as `policy.get` encodes `AllowedTypes` — a nested object.
    var allowedTypes: (group: Bool, customer: Bool, internal: Bool) {
        let t = policyState["allowedTypes"]?.objectValue ?? [:]
        return (t["group"]?.boolValue ?? false, t["customer"]?.boolValue ?? false, t["internal"]?.boolValue ?? false)
    }
    /// B14: policy.json › allowedChatIds (group chat_id rules).
    var allowedChatIds: [String] { policyState["allowedChatIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    /// B14: policy.json › allowedExternalUserIds (customer external_userid rules).
    var allowedExternalUserIds: [String] { policyState["allowedExternalUserIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// group.rename on the active conversation (B9: every group can be renamed from the conversations page).
    func renameActiveGroup(to name: String) async {
        let target = activeTitle
        guard !target.isEmpty, !name.isEmpty else { return }
        guard let r = await rpc("group.rename", RPCService.groupRenameParams(target: target, name: name)) else { renameResult = lastError ?? "failed"; return }
        renameResult = RPCService.pretty(r)
        if let title = r.objectValue?["result"]?.objectValue?["title"]?.stringValue, r.objectValue?["result"]?.objectValue?["renamed"]?.stringValue == "true" {
            activeTitle = title
            await loadConversations()
        }
    }

    /// A row that is not allowlisted cannot be selected directly; walk there with the client's own
    /// next / previous shortcuts (no target, not gated), the way a human would (user request 2026-09-16).
    func reach(_ target: String, expectedRevision: Int? = nil) async -> Bool {
        if conversations.isEmpty {
            guard let r = await rpc("conversation.list") else { return false }
            if let expectedRevision, expectedRevision != conversationRevision { return false }
            conversations = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
            activeTitle = conversations.first { $0["selected"] == "true" }?["title"] ?? activeTitle
        }
        if let expectedRevision, expectedRevision != conversationRevision { return false }
        guard let targetIndex = conversations.firstIndex(where: { $0["title"] == target }) else { return false }
        let activeIndex = conversations.firstIndex { $0["selected"] == "true" } ?? 0
        let action: NavigateAction = targetIndex >= activeIndex ? .nextConversation : .previousConversation
        for _ in 0..<(abs(targetIndex - activeIndex) + 2) {
            guard let r = await rpc("client.navigate", RPCService.navigateParams(action)), Self.failure(of: r) == nil,
                  let after = r.objectValue?["result"]?.objectValue?["after"]?.stringValue else { return false }
            if let expectedRevision, expectedRevision != conversationRevision { return false }
            activeTitle = after
            if after == target {
                await loadConversations()
                await loadHistory()
                return true
            }
        }
        historyError = "用上一 / 下一会话走了 \(abs(targetIndex - activeIndex) + 2) 步仍未到达「\(target)」，列表可能已变化：请重新读取列表再试"
        return false
    }

    func loadRequests() async {
        guard let r = await rpc("contact.request.list") else { return }
        requests = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
    }

    func acceptRequest(name: String) async {
        _ = await rpc("contact.request.accept", RPCService.acceptParams(name: name))
        await loadRequests()
    }

    func createGroup(members: [String], name: String?) async {
        guard let r = await rpc("group.create", RPCService.groupCreateParams(members: members, name: name)) else { groupResult = lastError ?? "failed"; return }
        groupResult = RPCService.pretty(r)
    }

    /// B14: group.addMembers from the 建群 page's 「添加到现有群」 section — dryRun selects candidates then
    /// cancels (never confirms); the result JSON carries state / added / skipped / evidence.
    func addGroupMembers(target: String, members: String, dryRun: Bool) async -> String {
        guard let r = await rpc("group.addMembers", RPCService.groupAddMembersParams(target: target, members: members, dryRun: dryRun)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    /// B12: search / add a customer by phone number — any number since 2026-10-13; each search and real add counts
    /// against its hourly cap. A real add from this page goes through `requestContactAdd` / `confirmContactAdd`.
    func contactAdd(phone: String, source: String, greeting: String, dryRun: Bool) async {
        guard let r = await rpc("contact.add", RPCService.contactAddParams(phone: phone, source: source, greeting: greeting, dryRun: dryRun)) else { addResult = lastError ?? "failed"; return }
        addResult = RPCService.pretty(r)
    }

    /// `contact.add`'s hourly caps from the policy file (any number may be added since 2026-10-13).
    var maxAddsPerHour: Int { Int(policyState["contactAdd"]?.objectValue?["maxAddsPerHour"]?.numberValue ?? 20) }
    var maxSearchesPerHour: Int { Int(policyState["contactAdd"]?.objectValue?["maxSearchesPerHour"]?.numberValue ?? 60) }

    /// User decision 2026-10-13: a real add from the console waits for the person to confirm — any number may be
    /// added and a sent request cannot be taken back.
    struct PendingContactAdd: Identifiable, Equatable {
        let id = UUID()
        let phone: String
        let source: String
        let greeting: String
        var maskedPhone: String { ContactAddPolicy.mask(phone) }
    }
    var pendingContactAdd: PendingContactAdd?

    func requestContactAdd(phone: String, source: String, greeting: String) {
        pendingContactAdd = PendingContactAdd(phone: phone, source: source, greeting: greeting)
    }

    /// The dialog's 发送 button, with the request the dialog showed (dismissing it clears `pendingContactAdd`,
    /// maybe before this runs).
    func confirmContactAdd(_ pending: PendingContactAdd) async {
        pendingContactAdd = nil
        await contactAdd(phone: pending.phone, source: pending.source, greeting: pending.greeting, dryRun: false)
    }

    /// Current policy.json (read directly; edits go through the CLI).
    func currentPolicy() -> SendPolicy { (try? SendPolicy.load(from: SendPolicy.defaultURL)) ?? SendPolicy() }

    func policyRequests(_ arguments: [String]) async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", "requests"] + arguments) }.value
        append("policy requests", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    // MARK: Policy (via CLI)

    func loadPolicy() async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", "list"]) }.value
        policyText = result?.output ?? "imctl policy list failed"
        if let r = await rpc("policy.get", log: false), Self.failure(of: r) == nil { policyState = r.objectValue?["result"]?.objectValue ?? [:] }
    }

    /// B10: whether opening / reading a conversation must pass the allowlist (default off).
    func policyReads(gate: Bool) async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", "reads", gate ? "--gate" : "--open"]) }.value
        append("policy reads", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    /// The local switch for policy.set over the wire (B9).
    func policyRemote(enable: Bool) async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", "remote", enable ? "--enable" : "--disable"]) }.value
        append("policy remote", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    func policy(_ verb: String, title: String) async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", verb, "--title", title]) }.value
        append("policy \(verb)", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    /// B14: the 「全部放开」 switch — the view confirms with the user before ever calling this with `on: true`.
    func policyAllowAll(_ on: Bool) async {
        let cli = self.cli
        let args = Self.policyAllArgs(on)
        let result = try? await Task.detached { try cli.run(args) }.value
        append("policy all", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    static func policyAllArgs(_ on: Bool) -> [String] { ["policy", "all", on ? "--enable" : "--disable"] }

    /// B14: 按类型放行 三开关 (group / customer / internal).
    func policyType(_ type: String, allow: Bool) async {
        let cli = self.cli
        let args = Self.policyTypeArgs(type, allow: allow)
        let result = try? await Task.detached { try cli.run(args) }.value
        append("policy \(allow ? "allow" : "deny") --type", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    static func policyTypeArgs(_ type: String, allow: Bool) -> [String] { ["policy", allow ? "allow" : "deny", "--type", type] }

    /// B14: chatId / externalUserId 条目增删 (`kind` is the CLI flag suffix: "chat-id" or "external-user-id").
    func policyId(kind: String, value: String, allow: Bool) async {
        let cli = self.cli
        let args = Self.policyIdArgs(kind: kind, value: value, allow: allow)
        let result = try? await Task.detached { try cli.run(args) }.value
        append("policy \(allow ? "allow" : "deny") --\(kind)", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    static func policyIdArgs(kind: String, value: String, allow: Bool) -> [String] { ["policy", allow ? "allow" : "deny", "--\(kind)", value] }

    /// B14: a title row's 「修改」 — deny the old title, then allow the new one (both local decisions through
    /// the CLI, same as every other policy edit), then reload so the table reflects it in one refresh. Each
    /// step is logged like `policy(_:title:)` / `policyType` do, and a failed deny stops the rename before
    /// the new title is ever allowed — the old title must actually be revoked first, so a broken CLI never
    /// leaves both titles allowed at once.
    func policyRename(oldTitle: String, newTitle: String) async {
        let cli = self.cli
        let steps = Self.policyRenameSteps(old: oldTitle, new: newTitle)
        let denyResult = try? await Task.detached { try cli.run(steps[0]) }.value
        let denyFailed = (denyResult?.status ?? 1) != 0
        append("policy deny --title", denyResult?.output ?? "failed", error: denyFailed)
        guard !denyFailed else { await loadPolicy(); return }
        let allowResult = try? await Task.detached { try cli.run(steps[1]) }.value
        append("policy allow --title", allowResult?.output ?? "failed", error: (allowResult?.status ?? 1) != 0)
        await loadPolicy()
    }

    static func policyRenameSteps(old: String, new: String) -> [[String]] {
        [["policy", "deny", "--title", old], ["policy", "allow", "--title", new]]
    }

    // MARK: B53 navigation and readiness actions

    var wizardPresented = false
    /// This console's CFBundleVersion (nil when run outside the app, e.g. `swift run`).
    var consoleBuild: String? { ReadinessClient.bundleBuild(at: Bundle.main.bundleURL) }

    /// B53: on launch, a local check only. The first launch that is not ready opens the wizard; later ones that are
    /// not ready open on the readiness page.
    func startupReadiness(defaults: UserDefaults = .standard) async {
        await runReadiness(localOnly: true, maxPolls: 0)
        if SetupWizard.shouldAutoOpen(report: readiness, flagDone: SetupWizard.flagDone(defaults)) {
            presentWizard()
        } else if readiness?.ready != true {
            section = .readiness
        }
    }

    var wizard = SetupWizard()

    /// From the readiness page or the menu bar.
    func openWizard() async {
        await runReadiness(localOnly: true, maxPolls: 0)
        presentWizard()
    }

    /// Step 1 with configured features ticked, whether reopened or opened by itself at the first launch.
    private func presentWizard() {
        wizard = SetupWizard()
        wizard.selected = SetupWizard.preselected(readiness)
        wizardPresented = true
    }

    /// Closed before the end: remembered too, so it does not open by itself again.
    func closeWizard(defaults: UserDefaults = .standard) {
        SetupWizard.markDone(defaults)
        wizardPresented = false
    }

    func finishWizard(defaults: UserDefaults = .standard) {
        closeWizard(defaults: defaults)
        section = .readiness
    }


    var section: ConsoleSection? = .readiness
    var settingsPane: SettingsPane = .mqtt
    /// Waiting for the person to confirm (the readiness page and the wizard show one dialog for it).
    var pendingAction: ReadinessAction?
    var actionNotice: String?
    /// Tests replace the effect of a confirmed action; production runs `performLive`.
    var performOverride: (@MainActor (ReadinessAction) async -> Void)?
    /// How long a restart waits for the daemon's count (tests shorten it).
    var restartCheckTimeout: TimeInterval = 15
    /// After a restart: more local checks until the daemon answers, this far apart (tests shorten them).
    var restartWaitPolls = 10
    var restartWaitNanoseconds: UInt64 = 1_000_000_000
    /// Where closing the wizard is remembered (tests use their own suite).
    var wizardDefaults: UserDefaults = .standard

    /// The single entry for fix buttons: navigation happens at once; anything else waits for `confirmPendingAction()`;
    /// a daemon restart is refused while a command runs.
    func requestAction(_ action: ReadinessAction) async {
        actionNotice = nil
        guard action.known != nil else { return }
        if action.navigatesOnly { await navigate(action); return }
        if action.restartsDaemon, let refusal = await restartAnswer().refusal { actionNotice = refusal; return }
        pendingAction = action
    }

    /// The dialog's 确认 button, with the action the dialog showed (review C1: dismissing the dialog clears
    /// `pendingAction`, maybe before this runs). A restart is checked again here: a command may have started meanwhile.
    func confirm(_ action: ReadinessAction) async {
        pendingAction = nil
        if action.restartsDaemon, let refusal = await restartAnswer().refusal { actionNotice = refusal; return }
        if let performOverride { await performOverride(action) } else { await performLive(action) }
        if action.known == .reinstallDaemon { wizard.applied() }
        // Review I4a: a retest leaves its own online report; a local check now would replace it with 未实测.
        guard action.known != .retest else { return }
        if action.restartsDaemon { await waitForDaemon() } else { await runReadiness(localOnly: true) }
    }

    /// Review I4b: right after a restart the daemon needs a moment; check until it answers (or show the fallback
    /// after `restartWaitPolls` more tries) instead of showing it as gone.
    func waitForDaemon() async {
        for attempt in 0...restartWaitPolls {
            await runReadiness(localOnly: true, maxPolls: 0)
            if readiness != nil || attempt == restartWaitPolls { return }
            try? await Task.sleep(nanoseconds: restartWaitNanoseconds)
        }
    }

    /// Runs whatever is pending (tests; the dialog passes what it showed to `confirm(_:)`).
    func confirmPendingAction() async {
        guard let action = pendingAction else { return }
        await confirm(action)
    }

    func cancelPendingAction() { pendingAction = nil }

    /// Review I5a: one dialog answers — the wizard's while the wizard is up (its sheet covers the window), else the
    /// console window's.
    func presentsConfirmation(inWizard: Bool) -> Bool { pendingAction != nil && inWizard == wizardPresented }
    func presentsNotice(inWizard: Bool) -> Bool { actionNotice != nil && inWizard == wizardPresented }

    /// What the daemon says right before a restart (review I3b: no answer in time is not "nothing running").
    func restartAnswer() async -> ReadinessRestartAnswer {
        var service = self.service
        service.timeout = restartCheckTimeout
        return await Task.detached {
            ReadinessRestartAnswer.asking { try service.call(RPCDispatcher.readinessMethod, ["online": .bool(false)]) }
        }.value
    }

    func navigate(_ action: ReadinessAction) async {
        // Review I5b: the wizard's sheet covers the window; close it so the new page is seen.
        if wizardPresented { closeWizard(defaults: wizardDefaults) }
        switch action.known {
        case .openSettings?:
            settingsPane = SettingsPane(target: action.target) ?? .mqtt
            section = .settings
        case .openPolicy?: section = .policy
        case .openLogs?:
            if let value = await rpc("controller.logs", ["lines": .number(50)], log: false) {
                append("守护进程日志（最近 50 行）", RPCService.pretty(value))
            }
            section = .log
        default: break
        }
    }

    func performLive(_ action: ReadinessAction) async {
        let cli = self.cli
        switch action.known {
        case .openSystemSettings?:
            if let url = ReadinessActionText.systemSettingsURL(action.target) { NSWorkspace.shared.open(url) }
        case .openWeCom?:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WeComClient.bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        case .setup?: await agentAction("imctl setup") { try cli.run(["setup", "--wait", "10"]) }
        case .reinstallDaemon?: await installDaemon()
        case .restartDaemon?: await restartDaemon()
        case .resumeDaemon?: await resume()
        case .registerAgents?: await agentAction("imctl mcp install") { try cli.run(["mcp", "install", "--claude-code", "--codex", "--skills"]) }
        case .installSkills?: await agentAction("imctl mcp install --skills") { try cli.run(["mcp", "install", "--skills"]) }
        case .retest?: await runReadiness(refresh: true)
        case .openSettings?, .openPolicy?, .openLogs?, nil: await navigate(action)
        }
    }

    // MARK: Daemon (via CLI / launchctl)

    func agentAction(_ title: String, _ run: @escaping @Sendable () throws -> CLIRunner.Result) async {
        let result: CLIRunner.Result
        do { result = try await Task.detached { try run() }.value }
        catch { result = CLIRunner.Result(status: 1, output: String(describing: error)) }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = result.status != 0
        append(title, output.isEmpty ? (failed ? "failed" : "ok") : output, error: failed)
        lastAgentAction = (title, output.isEmpty ? (failed ? "失败（无输出）" : "完成") : output, failed)
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }

    func installDaemon() async {
        let control = self.control, mqtt = mqttEnrolled
        await agentAction("agent install") { try control.install(mqttEnrolled: mqtt) }
    }

    func restartDaemon() async {
        let control = self.control
        await agentAction("launchctl kickstart") { try control.restart() }
    }

    func uninstallDaemon() async {
        let control = self.control
        await agentAction("agent uninstall") { try control.uninstall() }
    }

    func openAccessibilitySettings() {
        if let url = AXPermission.accessibilitySettingsURL { NSWorkspace.shared.open(url) }
    }

    func openLogs() { NSWorkspace.shared.open(ConsolePaths.logDirectory) }

    // MARK: Settings (local files only, 0600)

    /// What the settings page shows for editing: everything but the secrets,
    /// which stay in the files (an empty password / token keeps the stored one).
    /// Everything the two settings files store, secrets reduced to "present" flags.
    struct StoredSettings: Equatable {
        var host = "", port = 1883, tls = false, controllerID = "", username = "", topicPrefix = "im", hasPassword = false, keepAliveSeconds = 30
        var proxyURL = "", hasProxyToken = false, corpId = "", agentId: Int? = nil, proxyTimeoutSeconds = 15.0
        /// B13: `oss.json` as the settings page shows it — every field but the secret (a presence flag) and the
        /// AccessKeyId (masked — review fix: the page used to pre-fill the full id into a plain `TextField`).
        var ossEndpoint = "", ossBucket = "", ossBaseDir = "imctl", ossAccessKeyIdMasked = "", hasOSSSecret = false, ossViewExpireSeconds = 1800, ossMaxUploadBytes: Int64 = 52_428_800
        var visionProvider = CloudVisionProvider.qwen.rawValue, visionModel = CloudVisionSettings.defaultModel(for: .qwen), visionEnabled = false, visionFullWindowEnabled = false
        var visionKeysPresent: [String: Bool] = [:]
        /// The topics derived from prefix + controller id (cmd / rsp / evt / state).
        var topics: [String] { controllerID.isEmpty ? [] : ["cmd", "rsp", "evt", "state"].map { "\(topicPrefix)/\(controllerID)/\($0)" } }
    }

    func loadStoredSettings(mqttURL: URL = MQTTSettings.defaultURL, proxyURL: URL = WeComProxySettings.defaultURL,
                            ossURL: URL = OSSSettings.defaultURL, visionURL: URL = CloudVisionSettings.defaultURL) -> StoredSettings {
        var s = StoredSettings()
        if let m = try? MQTTSettings.load(from: mqttURL) {
            s.host = m.host; s.port = m.port; s.tls = m.useTLS; s.controllerID = m.controllerID
            s.username = m.username ?? ""; s.topicPrefix = m.topicPrefix; s.hasPassword = !(m.password ?? "").isEmpty
            s.keepAliveSeconds = m.keepAliveSeconds
        }
        if let p = try? WeComProxySettings.load(from: proxyURL) {
            s.proxyURL = p.baseURL; s.hasProxyToken = !p.token.isEmpty; s.corpId = p.corpId ?? ""; s.agentId = p.agentId
            s.proxyTimeoutSeconds = p.timeoutSeconds
        }
        if let o = try? OSSSettings.load(from: ossURL) {
            s.ossEndpoint = o.endpoint; s.ossBucket = o.bucket; s.ossBaseDir = o.baseDir; s.ossAccessKeyIdMasked = OSSSettings.mask(o.accessKeyId)
            s.hasOSSSecret = !o.accessKeySecret.isEmpty; s.ossViewExpireSeconds = o.viewExpireSeconds; s.ossMaxUploadBytes = o.maxUploadBytes
        }
        if let v = try? CloudVisionSettings.loadOrDefault(from: visionURL) {
            s.visionProvider = v.provider.rawValue; s.visionModel = v.model; s.visionEnabled = v.cloudEnabled; s.visionFullWindowEnabled = v.fullWindowEnabled
            s.visionKeysPresent = Dictionary(uniqueKeysWithValues: CloudVisionProvider.allCases.map { ($0.rawValue, v.keyPresent(for: $0)) })
        }
        return s
    }

    /// B52 addendum: the id the MQTT form starts with — the saved one, else this Mac's host-name default. Never a
    /// default over a saved id, nor while mqtt.json is there but unreadable (review I1: the Java side uses that id).
    static func formControllerID(stored: StoredSettings, hostDefault: String?, fileExists: Bool) -> String {
        if fileExists && stored.controllerID.isEmpty { return "" }
        return MQTTSettings.resolveControllerID(explicit: nil, existing: stored.controllerID, hostDefault: hostDefault) ?? ""
    }

    func saveMQTT(host: String, port: Int, tls: Bool, controllerID: String, username: String, password: String, topicPrefix: String,
                  keepAliveSeconds: Int = 30, to url: URL = MQTTSettings.defaultURL) {
        guard MQTTSettings.isValidControllerID(controllerID) else {
            append("mqtt enroll", "controller id \"\(controllerID)\" must be 1–64 of A–Z a–z 0–9 . _ - (it is one topic level); not saved", error: true)
            return
        }
        // An empty password keeps the one already stored (the page never shows it).
        let existing = try? MQTTSettings.load(from: url)
        let keptPassword = password.isEmpty ? existing?.password : password
        let settings = MQTTSettings(host: host, port: port, controllerID: controllerID, username: username.isEmpty ? nil : username,
                                    password: keptPassword, useTLS: tls, topicPrefix: topicPrefix.isEmpty ? "im" : topicPrefix,
                                    keepAliveSeconds: max(5, keepAliveSeconds))
        do {
            try settings.save(to: url)
            append("mqtt enroll", "saved \(url.path) (0600); controller \(controllerID); first MQTT setup: 状态 › 守护进程维护 › 安装 / 更新 (MQTT mode); later changes: restart")
        } catch {
            append("mqtt enroll", String(describing: error), error: true)
        }
        mqttEnrolled = FileManager.default.fileExists(atPath: url.path)
    }

    func saveProxy(baseURL: String, token: String, corpId: String = "", agentId: Int? = nil, timeoutSeconds: Double = 15,
                   to url: URL = WeComProxySettings.defaultURL) {
        let existing = try? WeComProxySettings.load(from: url)
        let keptToken = token.isEmpty ? (existing?.token ?? "") : token
        do {
            try WeComProxySettings(baseURL: baseURL, token: keptToken, corpId: corpId.isEmpty ? nil : corpId, agentId: agentId,
                                   timeoutSeconds: timeoutSeconds > 0 ? timeoutSeconds : 15).save(to: url)
            append("wecom enroll", "saved \(url.path) (0600); restart the daemon to enable the API route")
        } catch {
            append("wecom enroll", String(describing: error), error: true)
        }
        proxyEnrolled = FileManager.default.fileExists(atPath: url.path)
    }

    /// B13: writes `oss.json` (0600). An empty secret or AccessKeyId keeps the one already stored — the page
    /// shows the secret not at all and the id masked, and lets the person type a replacement for either.
    func saveOSS(endpoint: String, bucket: String, baseDir: String, accessKeyId: String, accessKeySecret: String, viewExpireSeconds: Int, maxUploadBytes: Int64, to url: URL = OSSSettings.defaultURL) {
        let existing = try? OSSSettings.load(from: url)
        let keptAccessKeyId = accessKeyId.isEmpty ? (existing?.accessKeyId ?? "") : accessKeyId
        let keptSecret = accessKeySecret.isEmpty ? (existing?.accessKeySecret ?? "") : accessKeySecret
        do {
            try OSSSettings(endpoint: endpoint, bucket: bucket, baseDir: baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")), accessKeyId: keptAccessKeyId, accessKeySecret: keptSecret,
                            viewExpireSeconds: max(60, viewExpireSeconds), maxUploadBytes: max(1, maxUploadBytes)).save(to: url)
            append("oss set", "saved \(url.path) (0600); restart the daemon, then test")
        } catch { append("oss set", String(describing: error), error: true) }
        ossEnrolled = FileManager.default.fileExists(atPath: url.path)
    }

    func saveVision(provider name: String, model: String, secret: String, to url: URL = CloudVisionSettings.defaultURL) {
        do {
            guard let provider = CloudVisionProvider(rawValue: name) else { throw CloudVisionSettingsError.invalidProvider }
            var settings = try CloudVisionSettings.loadOrDefault(from: url)
            try settings.setProvider(provider, model: model)
            if !secret.isEmpty { try settings.setAPIKey(secret, for: provider) }
            try settings.enable()
            try settings.save(to: url)
            append("vision set", "enabled provider=\(provider.rawValue) model=\(settings.model) keyPresent=true; restart the daemon")
            visionEnabled = true
            visionProvider = provider.rawValue
        } catch { append("vision set", String(describing: error), error: true) }
        visionEnrolled = FileManager.default.fileExists(atPath: url.path)
    }

    func disableVision(to url: URL = CloudVisionSettings.defaultURL) {
        do {
            var settings = try CloudVisionSettings.load(from: url)
            settings.disable()
            try settings.save(to: url)
            visionEnabled = false
            visionFullWindowEnabled = false
            append("vision disable", "cloud uploads disabled for the next visual action")
        } catch { append("vision disable", String(describing: error), error: true) }
    }

    func setFullWindowVision(_ enabled: Bool, to url: URL = CloudVisionSettings.defaultURL) {
        do {
            var settings = try CloudVisionSettings.load(from: url)
            try settings.setFullWindowEnabled(enabled)
            try settings.save(to: url)
            visionFullWindowEnabled = settings.fullWindowEnabled
            append("vision full-window", enabled ? "enabled for explicit desktop commands" : "disabled")
        } catch { append("vision full-window", String(describing: error), error: true) }
    }

    // MARK: Diagnostics (read-only, in-process)

    func runDiagnostics() async {
        let report = await Task.detached { Diagnostics.run() }.value
        diagnostics = report
        append("diagnostics", (try? JSONEncoder().encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}

import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import MQTTTransport
@testable import OSSClient
@testable import WeComAPI
@testable import imctl_console

/// The console fake with switches: history can be made to fail, and the active
/// conversation advances on every navigate so the model sees a switch.
final class SwitchingFakeHandler: CommandHandler {
    nonisolated(unsafe) static var failHistory = false
    nonisolated(unsafe) static var emptyHistory = false
    nonisolated(unsafe) static var active = "文件传输助手"
    nonisolated(unsafe) static var conversationReads = 0
    func describe() throws -> [String: String] { ["platform": "fake", "allowlist": "文件传输助手"] }
    func accountStatus() throws -> [String: String] { ["windowReachable": "true"] }
    func conversationList() throws -> [[String: String]] {
        [["index": "0", "title": Self.renamedTitle ?? "文件传输助手", "selected": Self.active == "文件传输助手" ? "true" : "false", "conversationType": "unknown"],
         ["index": "1", "title": "«b»", "selected": Self.active == "«b»" ? "true" : "false", "conversationType": "unknown"]]
    }
    func conversationRead(target: String) throws -> [String: String] {
        Self.conversationReads += 1
        guard target == "文件传输助手" else { throw ControlError.targetNotAllowed(target) }
        Self.active = target
        return ["active": target, "messageCount": "1"]
    }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] {
        if Self.failHistory { throw ControlError.internalError("no message table") }
        if Self.emptyHistory { return [] }
        return [["index": "0", "direction": "outbound", "text": "hi from \(Self.active)", "kind": "message"]]
    }
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        try checkpoint(); try afterSubmit()
        return SendResult(state: .succeeded, evidence: "row #1", latencyMs: 9)
    }
    nonisolated(unsafe) static var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        Self.fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
    nonisolated(unsafe) static var navigations = 0
    func clientNavigate(action: NavigateAction) throws -> [String: String] {
        let before = Self.active
        Self.active = before == "文件传输助手" ? "«b»" : "文件传输助手"
        Self.navigations += 1
        return ["action": action.rawValue, "before": before, "after": Self.active, "changed": "true"]
    }
    nonisolated(unsafe) static var renamedTitle: String?
    func groupRename(target: String, name: String) throws -> [String: String] {
        Self.renamedTitle = name   // the list row shows the new title, as the live client does after AXConfirm
        return ["title": name, "renamed": "true", "requestedName": name]
    }
    func contactList(limit: Int, scope: String) throws -> [[String: String]] { [["name": "测试联系人A", "source": "wechat", "section": "我的客户"]] }
    func diagnose() throws -> [String: String] { ["trusted": "true", "activeTitle": "文件传输助手"] }
    nonisolated(unsafe) static var contactAdds: [Bool] = []
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool) throws -> [String: String] {
        Self.contactAdds.append(dryRun)
        return ["status": dryRun ? "matched" : "requested", "matches": "1", "match0": "\(source)/测试联系人", "dryRun": dryRun ? "true" : "false"]
    }
    func permissions(prompt: Bool, probe: Bool) throws -> [String: String] { ["accessibility": "trusted", "wecomData": "granted", "fullDiskAccess": "no", "prompted": prompt ? "true" : "false"] }
    func mediaCache(limit: Int, refresh: Bool) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"]) }
    /// Review fix (Important 2): `kind` and a call counter are settable so a test can drive a non-image
    /// response (no network for the thumbnail fetch) and prove `loadMedia` re-requested.
    nonisolated(unsafe) static var mediaKind = "image"
    nonisolated(unsafe) static var mediaCallCount = 0
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        Self.mediaCallCount += 1
        guard messageKey == "k-media" else { throw ControlError.mediaNotFound("no observation for \(messageKey)") }
        return MediaReference(messageKey: messageKey, kind: Self.mediaKind, matchedBy: "observed", fileName: "p.png", bytes: 3, contentType: "image/png",
                              ossKey: "imctl/2026/09/22/k-media-p.png", url: "https://b.example/imctl/2026/09/22/k-media-p.png?x-oss-signature=abc", expiresAtMs: 1_790_000_000_000)
    }
    func mediaCacheList(root: String?, dir: String) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"], entries: [MediaCacheEntry(name: dir, isDirectory: true, size: 0, modifiedMs: 0)]) }
    func contactRequestList() throws -> [[String: String]] { [] }
    func contactRequestAccept(name: String) throws -> [String: String] { ["name": name, "accepted": "true", "status": "added"] }
    func groupCreate(members: [String], name: String?) throws -> [String: String] { ["title": name ?? "群聊", "memberCount": "2", "renamed": "false", "opened": "true"] }
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        try checkpoint(); try afterSubmit()
        return GroupAddMembersResult(state: .succeeded, target: target, before: 3, after: 4, added: members, skipped: [], dryRun: dryRun, evidence: "count 3→4", latencyMs: 210)
    }
}

@Suite("ConsoleModel through a fake daemon socket", .serialized)
@MainActor
struct ConsoleModelTests {
    func daemon() throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: SwitchingFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        return (server, path)
    }

    /// User decision 2026-10-13: a real add from the console waits for a confirmation that shows the masked number
    /// and the source; only the confirmed request reaches the daemon.
    @Test func aRealAddFromTheConsoleWaitsForConfirmation() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.contactAdds = []
        let model = ConsoleModel()
        model.socketPathOverride = path
        model.requestContactAdd(phone: "138 0000 0000", source: "wecom", greeting: "")
        #expect(SwitchingFakeHandler.contactAdds.isEmpty)
        let pending = try #require(model.pendingContactAdd)
        #expect(pending.maskedPhone == "138******00" && pending.source == "wecom")
        await model.confirmContactAdd(pending)
        #expect(SwitchingFakeHandler.contactAdds == [false] && model.pendingContactAdd == nil)
    }

    @Test func openingTheAlreadySelectedConversationSkipsTheRedundantRead() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.failHistory = false; SwitchingFakeHandler.active = "文件传输助手"
        SwitchingFakeHandler.conversationReads = 0
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.loadConversations()
        await model.open("文件传输助手")
        #expect(SwitchingFakeHandler.conversationReads == 0)
        #expect(model.messages.first?["text"] == "hi from 文件传输助手")
        #expect(model.historyError == nil)
        #expect(model.latestHistoryRevision == 1)
    }

    @Test func defaultHistoryRequestsLatestButScrollbackPreservesPosition() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.failHistory = false
        let model = ConsoleModel()
        model.socketPathOverride = path
        let viewportBefore = model.historyViewportID
        await model.loadHistory()
        #expect(model.latestHistoryRevision == 1)
        let latestViewport = model.historyViewportID
        #expect(latestViewport != viewportBefore)
        await model.loadHistory(limit: 60, scrollback: true)
        #expect(model.latestHistoryRevision == 1)
        #expect(model.historyViewportID == latestViewport)
        await model.loadHistory()
        #expect(model.latestHistoryRevision == 2)
        #expect(model.historyViewportID != latestViewport)
    }

    @Test func emptyHistoryReadExplainsUnavailableRowsAndRecoveryClearsNotice() async throws {
        let (server, path) = try daemon()
        defer { server.stop(); SwitchingFakeHandler.emptyHistory = false }
        SwitchingFakeHandler.failHistory = false
        SwitchingFakeHandler.emptyHistory = true
        SwitchingFakeHandler.active = "文件传输助手"
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.loadConversations()
        await model.open("文件传输助手")
        #expect(model.activeTitle == "文件传输助手")
        #expect(model.messages.isEmpty && model.historyError == nil)
        #expect(model.historyNotice?.contains("没有读到消息行") == true)
        SwitchingFakeHandler.emptyHistory = false
        await model.loadHistory()
        #expect(model.messages.count == 1 && model.historyNotice == nil)
    }

    @Test func messageLabelsDistinguishKnownAttachmentsFromUnidentifiedMedia() {
        #expect(ConversationsView.label(for: ["kind": "file", "fileType": "pdf", "fileName": "sample.pdf"]) == "📎 PDF 文档 · sample.pdf")
        #expect(ConversationsView.label(for: ["kind": "file", "fileType": "word", "fileName": "sample.docx"]) == "📎 Word 文档 · sample.docx")
        #expect(ConversationsView.label(for: ["kind": "video", "duration": "01:14"]) == "🎬 视频 · 01:14")
        #expect(ConversationsView.label(for: ["kind": "media", "mediaType": "image"]) == "图片")
        #expect(ConversationsView.label(for: ["kind": "media", "mediaType": "unknown"]) == "未识别媒体")
        #expect(ConversationsView.label(for: ["kind": "media"], resolvedMediaKind: "image") == "图片")
    }

    /// User report 2026-09-15 21:08: after 上一 / 下一会话 the page kept showing the previous conversation's messages.
    @Test func navigatingReloadsTheMessagesOfTheNewActiveConversation() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.failHistory = false; SwitchingFakeHandler.active = "文件传输助手"
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.open("文件传输助手")
        #expect(model.activeTitle == "文件传输助手" && model.messages.first?["text"] == "hi from 文件传输助手")
        let oldViewport = model.historyViewportID
        await model.navigate(.nextConversation)
        #expect(model.activeTitle == "«b»" && model.messages.first?["text"] == "hi from «b»" && model.historyError == nil)
        #expect(model.historyViewportID != oldViewport)
    }

    @Test func aFailedHistoryReadClearsTheStaleListAndReportsIt() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.failHistory = false; SwitchingFakeHandler.active = "文件传输助手"
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.loadHistory()
        #expect(model.messages.count == 1)
        SwitchingFakeHandler.failHistory = true
        await model.loadHistory()
        #expect(model.messages.isEmpty && model.historyError?.contains("message.history") == true)
        SwitchingFakeHandler.failHistory = false
        await model.open("«b»")   // not allowlisted: the console walks there instead (B9) and shows that conversation
        #expect(model.activeTitle == "«b»" && model.messages.first?["text"] == "hi from «b»" && model.historyError == nil)
    }

    /// User 2026-09-16: opening a selected row must also work for rows the policy does not allow —
    /// the console walks there with next / previous instead of failing.
    @Test func openingANonAllowlistedRowWalksThereWithTheClientShortcuts() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.failHistory = false; SwitchingFakeHandler.active = "文件传输助手"; SwitchingFakeHandler.navigations = 0
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.loadConversations()
        await model.open("«b»")
        #expect(model.activeTitle == "«b»" && SwitchingFakeHandler.navigations == 1 && model.historyError == nil)
        #expect(model.messages.first?["text"] == "hi from «b»" && model.lastError == nil)
    }

    /// User 2026-09-16 09:28: the rename control was missing while the test group was active — the list still
    /// showed an older selection. The control follows the active title, not the stale selected row.
    @Test func activeIsGroupFollowsTheActiveTitleBeforeTheSelectedRow() {
        let model = ConsoleModel()
        model.conversations = [["index": "0", "title": "测试联系人A", "selected": "true", "conversationType": "unknown"],
                               ["index": "1", "title": "测试群", "selected": "false", "conversationType": "group"]]
        model.activeTitle = "测试群"
        #expect(model.activeIsGroup)
        model.activeTitle = "测试联系人A"
        #expect(!model.activeIsGroup)
        model.activeTitle = "不在列表里"
        #expect(!model.activeIsGroup)   // falls back to the selected row (测试联系人A, unknown)
    }

    @Test func policyStateComesFromPolicyGetAndDrivesTheWhitelistView() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        model.describe = ["allowlist": "文件传输助手"]
        await model.loadPolicy()   // the CLI half fails in tests (no sibling binary); the daemon half is what the view uses
        #expect(model.effectiveTitles == ["文件传输助手"] && !model.gateReads && !model.remoteEdits)
        model.policyState = ["allowedTitles": .array([.string("测试群")]), "gateReads": .bool(true)]
        #expect(model.effectiveTitles == ["文件传输助手", "测试群"] && model.gateReads)
    }

    @Test func mediaResultDecodesToALinkOrNil() throws {
        let ok = ConsoleModel.link(fromMediaResult: .object(["kind": .string("file"), "fileName": .string("a.pdf"), "url": .string("https://b.example/a.pdf?sig"), "expiresAtMs": .number(5), "duration": .null]))
        #expect(ok?.kind == "file" && ok?.fileName == "a.pdf" && ok?.url == "https://b.example/a.pdf?sig" && ok?.expiresAtMs == 5)
        #expect(ConsoleModel.link(fromMediaResult: .object(["kind": .string("image")])) == nil)
        let video = ConsoleModel.link(fromMediaResult: .object(["kind": .string("video"), "fileName": .string("poster.jpg"),
            "url": .string("https://b.example/poster.jpg"), "bodyUrl": .string("https://b.example/movie.mp4"), "bytes": .number(12)]))
        #expect(video?.openURL == "https://b.example/movie.mp4" && video?.openFileName == "video.mp4" && video?.bytes == 12)
    }

    @Test func mediaDownloadAcceptsOnlyTheConfiguredBucketAndPlainNames() throws {
        let settings = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "sample-bucket", baseDir: "media",
                                   accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret")
        let good = "https://sample-bucket.oss-cn-hangzhou.aliyuncs.com/media/a.pdf?x-oss-signature=test"
        #expect(try MediaDownload.validated(urlString: good, fileName: "a.pdf", messageKey: "abcdef0123456789", settings: settings).1 == "a.pdf")
        #expect(try MediaDownload.validated(urlString: good, fileName: "a.heic", messageKey: "abcdef0123456789", settings: settings).1 == "a.heic")
        #expect(throws: Error.self) { try MediaDownload.validated(urlString: "https://evil.example/a.pdf", fileName: "a.pdf", messageKey: "abcdef0123456789", settings: settings) }
        #expect(throws: Error.self) { try MediaDownload.validated(urlString: good, fileName: "../a.pdf", messageKey: "abcdef0123456789", settings: settings) }
        #expect(throws: Error.self) { try MediaDownload.validated(urlString: good, fileName: "a.pdf", messageKey: "../outside", settings: settings) }
    }

    @Test func aFailedMediaReadShowsItsSpecificRPCReason() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.loadMedia(for: "missing")
        #expect(model.mediaErrors["missing"] == "MEDIA_NOT_FOUND")
        #expect(ConsoleModel.mediaReadMessage("MEDIA_NOT_FOUND").contains("无法确认"))
        #expect(ConsoleModel.mediaOpenMessage(ControlError.sourceUnsupported("private-path")).contains("格式与文件内容"))
    }

    @Test func renamingTheActiveGroupGoesThroughGroupRename() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.active = "文件传输助手"; SwitchingFakeHandler.renamedTitle = nil
        defer { SwitchingFakeHandler.renamedTitle = nil }
        let model = ConsoleModel()
        model.socketPathOverride = path
        model.activeTitle = "文件传输助手"
        await model.renameActiveGroup(to: "新名")
        #expect(model.renameResult.contains("\"renamed\" : \"true\"") && model.activeTitle == "新名")
        #expect(model.conversations.first?["title"] == "新名")   // re-read after the rename, so the list shows the new name
    }

    @Test func settingsRoundTripKeepsEveryStoredField() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mqtt = dir.appendingPathComponent("mqtt.json"), proxy = dir.appendingPathComponent("wecom-proxy.json")
        let model = ConsoleModel()
        model.saveMQTT(host: "broker.local", port: 8883, tls: true, controllerID: "mac-t", username: "u", password: "p", topicPrefix: "im", keepAliveSeconds: 45, to: mqtt)
        model.saveProxy(baseURL: "https://proxy.example", token: "t", corpId: "wwid", agentId: 1000002, timeoutSeconds: 20, to: proxy)
        let s = model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy)
        #expect(s.host == "broker.local" && s.port == 8883 && s.tls && s.controllerID == "mac-t" && s.username == "u" && s.hasPassword && s.keepAliveSeconds == 45)
        #expect(s.proxyURL == "https://proxy.example" && s.hasProxyToken && s.corpId == "wwid" && s.agentId == 1000002 && s.proxyTimeoutSeconds == 20)
        #expect(s.topics == ["im/mac-t/cmd", "im/mac-t/rsp", "im/mac-t/evt", "im/mac-t/state"])
        // an empty password / token keeps the stored secret
        model.saveMQTT(host: "broker.local", port: 8883, tls: true, controllerID: "mac-t", username: "u", password: "", topicPrefix: "im", keepAliveSeconds: 45, to: mqtt)
        model.saveProxy(baseURL: "https://proxy.example", token: "", corpId: "wwid", agentId: 1000002, timeoutSeconds: 20, to: proxy)
        #expect(try MQTTSettings.load(from: mqtt).password == "p" && (try WeComProxySettings.load(from: proxy)).token == "t")
        let oss = dir.appendingPathComponent("oss.json")
        model.saveOSS(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 900, maxUploadBytes: 2048, to: oss)
        let o = model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy, ossURL: oss)
        #expect(o.ossEndpoint == "https://oss-cn-hangzhou.aliyuncs.com" && o.ossBucket == "photos" && o.ossBaseDir == "imctl" && o.hasOSSSecret && o.ossViewExpireSeconds == 900 && o.ossMaxUploadBytes == 2048)
        // review fix (Important 1): the settings page must never see the full AccessKeyId again, only the masked form
        #expect(o.ossAccessKeyIdMasked == OSSSettings.mask("TESTAKID0000000001") && o.ossAccessKeyIdMasked == "TEST…01" && !o.ossAccessKeyIdMasked.contains("TESTAKID0000000001"))
        model.saveOSS(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "", viewExpireSeconds: 900, maxUploadBytes: 2048, to: oss)
        #expect(try OSSSettings.load(from: oss).accessKeySecret == "test-secret")
        // review fix (Important 1): an empty AccessKeyId, like an empty secret, keeps the one already stored instead of blanking it
        model.saveOSS(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "", accessKeySecret: "", viewExpireSeconds: 900, maxUploadBytes: 2048, to: oss)
        #expect(try OSSSettings.load(from: oss).accessKeyId == "TESTAKID0000000001")

        let vision = dir.appendingPathComponent("vision/cloud-vision.json")
        model.saveVision(provider: "qwen", model: "qwen3.7-plus", secret: "test-vision-secret", to: vision)
        let v = model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy, ossURL: oss, visionURL: vision)
        #expect(v.visionEnabled && v.visionProvider == "qwen" && v.visionModel == "qwen3.7-plus")
        #expect(v.visionKeysPresent["qwen"] == true)
        #expect(!String(describing: v).contains("test-vision-secret"))
        #expect(!model.log.contains(where: { $0.body.contains("test-vision-secret") }))
        model.saveVision(provider: "qwen", model: "qwen3.7-plus", secret: "", to: vision)
        #expect(model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy, ossURL: oss, visionURL: vision).visionEnabled)
        model.disableVision(to: vision)
        #expect(!model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy, ossURL: oss, visionURL: vision).visionEnabled)
    }

    @Test func fileTransferAssistantRowsAppearOnTheSenderSide() {
        #expect(ChatMessageRow.displayDirection(nil, activeTitle: "文件传输助手") == "outbound")
        #expect(ChatMessageRow.displayDirection("inbound", activeTitle: "文件传输助手") == "outbound")
        #expect(ChatMessageRow.displayDirection("inbound", activeTitle: "测试会话") == "inbound")
        #expect(ChatMessageRow.displayDirection(nil, activeTitle: "测试会话") == "unknown")
    }

    @Test func isStaleFlagsALinkInsideTheSixtySecondMarginOrPastExpiry() {
        let link = ConsoleModel.MediaLink(kind: "file", fileName: "a.pdf", url: "https://b.example/a.pdf", expiresAtMs: 1_000_000, duration: nil)
        #expect(!ConsoleModel.isStale(link, nowMs: 900_000))    // 100 s of headroom: fresh
        #expect(ConsoleModel.isStale(link, nowMs: 999_500))     // inside OSS's 60 s margin
        #expect(ConsoleModel.isStale(link, nowMs: 1_000_001))   // past expiry
    }

    /// Review fix (Important 2): a cached link used to be kept forever (`guard mediaLinks[key] == nil`), so
    /// 打开 / 复制地址 eventually handed out a dead URL. A fresh cache is left alone; a stale one or an explicit
    /// 刷新 (`force`) re-requests `message.media`. `kind: "file"` keeps the fixture off the thumbnail-download
    /// path so the test needs no network.
    @Test func loadMediaSkipsAFreshCacheButRefetchesWhenStaleOrForced() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        SwitchingFakeHandler.mediaKind = "file"; SwitchingFakeHandler.mediaCallCount = 0
        defer { SwitchingFakeHandler.mediaKind = "image"; SwitchingFakeHandler.mediaCallCount = 0 }
        let model = ConsoleModel()
        model.socketPathOverride = path
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        model.mediaLinks["k-media"] = ConsoleModel.MediaLink(kind: "file", fileName: "old.pdf", url: "https://b.example/old", expiresAtMs: nowMs + 600_000, duration: nil)
        await model.loadMedia(for: "k-media")
        #expect(SwitchingFakeHandler.mediaCallCount == 0 && model.mediaLinks["k-media"]?.url == "https://b.example/old")   // fresh: left alone

        await model.loadMedia(for: "k-media", force: true)
        #expect(SwitchingFakeHandler.mediaCallCount == 1 && model.mediaLinks["k-media"]?.url.contains("x-oss-signature=abc") == true)   // 刷新 forces a re-request

        model.mediaLinks["k-media"] = ConsoleModel.MediaLink(kind: "file", fileName: "old.pdf", url: "https://b.example/old", expiresAtMs: nowMs - 1_000, duration: nil)
        await model.loadMedia(for: "k-media")
        #expect(SwitchingFakeHandler.mediaCallCount == 2)   // stale: re-requested without being forced
    }

    @Test func allowedHostsParsesFromThePolicyGetSendFileBlock() {
        let model = ConsoleModel()
        model.policyState = ["sendFile": .object(["allowedHosts": .array([.string("cdn.example"), .string(".aliyuncs.com")]), "maxBytes": .number(1024)])]
        #expect(model.allowedHosts == ["cdn.example", ".aliyuncs.com"])
        model.policyState = [:]
        #expect(model.allowedHosts.isEmpty)
    }

    @Test func policyHostsArgsBuildTheAllowAndDenyFlags() {
        #expect(ConsoleModel.policyHostsArgs(allow: nil, deny: nil) == ["policy", "hosts"])
        #expect(ConsoleModel.policyHostsArgs(allow: "cdn.example", deny: nil) == ["policy", "hosts", "--allow", "cdn.example"])
        #expect(ConsoleModel.policyHostsArgs(allow: nil, deny: "old.example") == ["policy", "hosts", "--deny", "old.example"])
        #expect(ConsoleModel.policyHostsArgs(allow: "a.example", deny: "b.example") == ["policy", "hosts", "--allow", "a.example", "--deny", "b.example"])
    }

    // MARK: B14 — allowAll / type toggles / chatId / externalUserId (policy.get JSON + arg builders)

    /// The policy page's new computed properties, fed the same shape `policy.get` actually returns
    /// (`SendPolicy` encoded straight through: `allowedTypes` a nested object, the two id lists flat arrays).
    @Test func allowAllTypesAndIdsParseFromThePolicyGetJSON() {
        let model = ConsoleModel()
        model.policyState = [
            "allowAll": .bool(true),
            "allowedTypes": .object(["group": .bool(true), "customer": .bool(false), "internal": .bool(true)]),
            "allowedChatIds": .array([.string("wr1")]),
            "allowedExternalUserIds": .array([.string("wm1")]),
        ]
        #expect(model.allowAll)
        #expect(model.allowedTypes.group && !model.allowedTypes.customer && model.allowedTypes.internal)
        #expect(model.allowedChatIds == ["wr1"])
        #expect(model.allowedExternalUserIds == ["wm1"])
        model.policyState = [:]
        #expect(!model.allowAll)
        #expect(!model.allowedTypes.group && !model.allowedTypes.customer && !model.allowedTypes.internal)
        #expect(model.allowedChatIds.isEmpty && model.allowedExternalUserIds.isEmpty)
    }

    @Test func policyAllArgsBuildsEnableAndDisable() {
        #expect(ConsoleModel.policyAllArgs(true) == ["policy", "all", "--enable"])
        #expect(ConsoleModel.policyAllArgs(false) == ["policy", "all", "--disable"])
    }

    @Test func policyTypeArgsBuildsAllowAndDenyForEachType() {
        #expect(ConsoleModel.policyTypeArgs("group", allow: true) == ["policy", "allow", "--type", "group"])
        #expect(ConsoleModel.policyTypeArgs("customer", allow: false) == ["policy", "deny", "--type", "customer"])
        #expect(ConsoleModel.policyTypeArgs("internal", allow: true) == ["policy", "allow", "--type", "internal"])
    }

    @Test func policyIdArgsBuildsChatIdAndExternalUserIdFlags() {
        #expect(ConsoleModel.policyIdArgs(kind: "chat-id", value: "wr1", allow: true) == ["policy", "allow", "--chat-id", "wr1"])
        #expect(ConsoleModel.policyIdArgs(kind: "external-user-id", value: "wm1", allow: false) == ["policy", "deny", "--external-user-id", "wm1"])
    }

    @Test func policyRenameStepsDenyTheOldTitleThenAllowTheNew() {
        #expect(ConsoleModel.policyRenameSteps(old: "旧群名", new: "新群名") ==
                [["policy", "deny", "--title", "旧群名"], ["policy", "allow", "--title", "新群名"]])
    }

    /// B14 fix wave: `policyRename` used to swallow both CLI results (`_ = try? …`) and log a plain,
    /// never-an-error line. The CLI half fails in tests (no sibling binary, same as
    /// `policyStateComesFromPolicyGetAndDrivesTheWhitelistView`), so the deny step must now show up as
    /// a logged error, and the allow step must never run — the old title was not actually revoked.
    @Test func policyRenameReportsAFailedDenyAsAnErrorAndNeverAllowsTheNewTitle() async throws {
        let (server, path) = try daemon()
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.policyRename(oldTitle: "旧群名", newTitle: "新群名")
        let denyEntry = try #require(model.log.last { $0.title == "policy deny --title" })
        #expect(denyEntry.isError)
        #expect(!model.log.contains { $0.title == "policy allow --title" })
    }
}

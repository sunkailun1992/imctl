import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

final class ConsoleFakeHandler: CommandHandler {
    func describe() throws -> [String: String] { ["platform": "fake", "allowlist": "文件传输助手"] }
    func accountStatus() throws -> [String: String] { ["windowReachable": "true"] }
    func conversationList() throws -> [[String: String]] { [["title": "文件传输助手", "selected": "true", "conversationType": "unknown"]] }
    func conversationRead(target: String) throws -> [String: String] { ["active": target, "messageCount": "1"] }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] { [["index": "0", "direction": "outbound", "text": "hi"]] }
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        try checkpoint(); try afterSubmit()
        return SendResult(state: .succeeded, evidence: "row #1", latencyMs: 9)
    }
    var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
    func clientNavigate(action: NavigateAction) throws -> [String: String] {
        ["action": action.rawValue, "before": "a", "after": "b", "changed": "true"]
    }
    func contactList(limit: Int, scope: String) throws -> [[String: String]] { [["name": "测试联系人A", "source": "wechat", "section": "我的客户"]] }
    func diagnose() throws -> [String: String] { ["trusted": "true", "activeTitle": "文件传输助手"] }
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool) throws -> [String: String] {
        return ["status": dryRun ? "matched" : "requested", "matches": "1", "match0": "\(source)/测试联系人", "dryRun": dryRun ? "true" : "false"]
    }
    func permissions(prompt: Bool, probe: Bool) throws -> [String: String] { ["accessibility": "trusted", "wecomData": "granted", "fullDiskAccess": "no", "prompted": prompt ? "true" : "false"] }
    func mediaCache(limit: Int, refresh: Bool) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"]) }
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        guard messageKey == "k-media" else { throw ControlError.mediaNotFound("no observation for \(messageKey)") }
        return MediaReference(messageKey: messageKey, kind: "image", matchedBy: "observed", fileName: "p.png", bytes: 3, contentType: "image/png",
                              ossKey: "imctl/2026/09/22/k-media-p.png", url: "https://b.example/imctl/2026/09/22/k-media-p.png?x-oss-signature=abc", expiresAtMs: 1_790_000_000_000)
    }
    func mediaCacheList(root: String?, dir: String) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"], entries: [MediaCacheEntry(name: dir, isDirectory: true, size: 0, modifiedMs: 0)]) }
    func contactRequestList() throws -> [[String: String]] { [] }
    func contactRequestAccept(name: String) throws -> [String: String] { ["name": name, "accepted": "true", "status": "added"] }
    func groupCreate(members: [String], name: String?) throws -> [String: String] { ["title": name ?? "群聊", "memberCount": "2", "renamed": "false"] }
    func groupRename(target: String, name: String) throws -> [String: String] { ["title": name, "renamed": "true", "requestedName": name] }
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        try checkpoint(); try afterSubmit()
        return GroupAddMembersResult(state: .succeeded, target: target, before: 3, after: 4, added: members, skipped: [], dryRun: dryRun, evidence: "count 3→4", latencyMs: 210)
    }
}

@Suite("RPCService against a real socket", .serialized)
struct RPCServiceTests {
    @Test func sendsNavigatesAndReplaysThroughTheDaemonPath() throws {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: ConsoleFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let service = RPCService(socketPath: path, timeout: 5)
        #expect(try service.call("controller.describe").objectValue?["result"]?.objectValue?["platform"] == .string("fake"))
        let sent = try service.call("message.send", RPCService.sendParams(target: "文件传输助手", text: "hi"))
        #expect(sent.objectValue?["state"] == .string("succeeded"))
        let nav = try service.call("client.navigate", RPCService.navigateParams(.nextConversation))
        #expect(nav.objectValue?["result"]?.objectValue?["changed"] == .string("true"))
        let replay = try service.call("event.replay", RPCService.replayParams(after: 0, limit: 50))
        #expect((replay.objectValue?["count"]?.numberValue ?? 0) >= 6)
        #expect(RPCService.idempotencyKey().hasPrefix("console-") && RPCService.idempotencyKey() != RPCService.idempotencyKey())
        #expect(try store.recentCommands(limit: 10).count == 3)   // describe, send, navigate — replay is a query
    }

    @Test func contactsParamsCarryConsoleKeys() {
        let a = RPCService.acceptParams(name: "测试联系人A")
        #expect(a["name"] == .string("测试联系人A") && a["idempotencyKey"]?.stringValue?.hasPrefix("console-") == true)
        let g = RPCService.groupCreateParams(members: ["测试联系人A", "同事A"], name: "测试联系人A群聊")
        #expect(g["members"] == .array([.string("测试联系人A"), .string("同事A")]) && g["name"] == .string("测试联系人A群聊"))
        #expect(RPCService.groupCreateParams(members: ["x"], name: nil)["name"] == nil)
    }

    @Test func sendFileParamsCarryExactlyOneSource() {
        let byURL = RPCService.sendFileParams(target: "文件传输助手", url: "https://cdn.example/a.pdf", ossKey: "", fileName: "")
        #expect(byURL["url"] == .string("https://cdn.example/a.pdf") && byURL["ossKey"] == nil && byURL["fileName"] == nil && byURL["idempotencyKey"]?.stringValue?.hasPrefix("console-") == true)
        let byKey = RPCService.sendFileParams(target: "t", url: "", ossKey: "imctl/a.pdf", fileName: "b.pdf")
        #expect(byKey["ossKey"] == .string("imctl/a.pdf") && byKey["url"] == nil && byKey["fileName"] == .string("b.pdf"))
        // review fix (Minor): url still wins when both are given — SendView now refuses this case before calling in, instead of relying on this silent drop
        let both = RPCService.sendFileParams(target: "t", url: "https://cdn.example/a.pdf", ossKey: "imctl/a.pdf", fileName: "")
        #expect(both["url"] == .string("https://cdn.example/a.pdf") && both["ossKey"] == nil)
    }

    /// B14: the 添加到现有群 field is one free-text box (comma or 、 separated) rather than a picker — split,
    /// trim, drop empties. `,` / `，` are what `PolicyView.split` takes for the console's other name
    /// lists; `、` is accepted here on top of those two.
    @Test func groupAddMembersParamsSplitsTrimsAndDropsEmpties() {
        let p = RPCService.groupAddMembersParams(target: "测试群", members: "李四, 王五、赵六", dryRun: true)
        #expect(p["target"] == .string("测试群"))
        #expect(p["members"] == .array([.string("李四"), .string("王五"), .string("赵六")]))
        #expect(p["dryRun"] == .bool(true))
        #expect(p["idempotencyKey"]?.stringValue?.hasPrefix("console-") == true)

        let messy = RPCService.groupAddMembersParams(target: "t", members: "李四,, 、 王五 ,", dryRun: false)
        #expect(messy["members"] == .array([.string("李四"), .string("王五")]))
        #expect(messy["dryRun"] == .bool(false))

        // fullwidth comma (same separator PolicyView.split accepts)
        let fullwidth = RPCService.groupAddMembersParams(target: "t", members: "李四，王五", dryRun: false)
        #expect(fullwidth["members"] == .array([.string("李四"), .string("王五")]))
    }
}

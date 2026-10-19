import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

final class DispatchFakeHandler: CommandHandler {
    var sends = 0
    func describe() throws -> [String: String] { ["platform": "fake"] }
    func accountStatus() throws -> [String: String] { ["windowReachable": "true"] }
    func conversationList() throws -> [[String: String]] { [["title": "文件传输助手", "selected": "true"]] }
    func conversationRead(target: String) throws -> [String: String] { ["active": target] }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] { [] }
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        sends += 1
        try checkpoint(); try afterSubmit()
        return SendResult(state: .succeeded, evidence: "row #1", latencyMs: 90)
    }
    var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
    func clientNavigate(action: NavigateAction) throws -> [String: String] { ["action": action.rawValue, "changed": "false"] }
    func contactList(limit: Int, scope: String) throws -> [[String: String]] { [["name": "测试联系人A", "source": "wechat"]] }
    func diagnose() throws -> [String: String] { ["trusted": "true"] }
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
    func contactRequestList() throws -> [[String: String]] { [["name": "测试联系人A", "status": "pending", "source": "wechat"]] }
    func contactRequestAccept(name: String) throws -> [String: String] { ["name": name, "accepted": "true", "status": "added"] }
    func groupCreate(members: [String], name: String?) throws -> [String: String] { ["title": name ?? "群聊", "memberCount": String(members.count + 1), "renamed": "false"] }
    func groupRename(target: String, name: String) throws -> [String: String] { ["title": name, "renamed": "true", "requestedName": name] }
    var groupAddMembersCalls = 0
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        groupAddMembersCalls += 1
        try checkpoint(); try afterSubmit()
        return GroupAddMembersResult(state: .succeeded, target: target, before: 3, after: 4, added: members, skipped: [], dryRun: dryRun, evidence: "count 3→4", latencyMs: 210)
    }
}

@Suite("RPCDispatcher")
struct DispatcherTests {
    func make() throws -> (RPCDispatcher, DispatchFakeHandler) {
        let store = try ControlStore(path: ":memory:")
        let handler = DispatchFakeHandler()
        return (RPCDispatcher(executor: CommandExecutor(store: store, handler: handler)), handler)
    }

    func parse(_ s: String?) throws -> [String: JSONValue] {
        let text = try #require(s)
        let value = try JSONValue.parse(text)
        return try #require(value.objectValue)
    }

    @Test func initializeAndToolsList() throws {
        let (d, _) = try make()
        let init_ = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(init_["result"]?.objectValue?["serverInfo"]?.objectValue?["name"] == .string("imctl"))
        #expect(d.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(list["result"]?.objectValue?["tools"])
        if case .array(let arr) = tools { #expect(arr.count == 45) } else { Issue.record("tools not array") }
    }

    /// Finding F5: every `PolicySetParams` field an agent may set has to appear in the MCP tool schema, or
    /// the agent cannot reach it — `allowHosts` / `denyHosts` (B13 sendFile hosts) were missing.
    @Test func policySetSchemaListsEveryParameterIncludingTheSendFileHosts() throws {
        let tool = try #require(RPCDispatcher.toolDescriptors().first { $0.objectValue?["name"] == .string("policy.set") })
        let props = try #require(tool.objectValue?["inputSchema"]?.objectValue?["properties"]?.objectValue)
        #expect(Set(props.keys) == ["allow", "deny", "contactRequests", "gateReads", "allowHosts", "denyHosts"])
        // B14 review F3: and `allowAll`（「全部放开」）is NOT one of them — it is a local-only switch
        // (`imctl policy all` / the console), so no agent on this transport can even name it.
        #expect(props["allowAll"] == nil)
        for host in ["allowHosts", "denyHosts"] {
            let field = try #require(props[host]?.objectValue)
            #expect(field["type"] == .string("array"))
            #expect(field["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test func eventReplayReadsAfterCursorWithoutCreatingCommands() throws {
        let (d, _) = try make()
        _ = d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"message.send","params":{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}}"#)
        let r = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"event.replay","params":{"afterEventId":1,"limit":10}}"#))
        let result = try #require(r["result"]?.objectValue)
        guard case .array(let events) = try #require(result["events"]) else { Issue.record("events not array"); return }
        #expect(events.count == 2 && events.first?.objectValue?["eventId"] == .number(2))
        #expect(result["lastEventId"] == .number(3) && result["count"] == .number(2))
        #expect(events.first?.objectValue?["kind"] == .string("command.state"))
        #expect(events.first?.objectValue?["payload"]?.objectValue?["state"] == .string("running"))
        #expect(try d.executor.store.lastEventId() == 3)
        #expect(try d.executor.store.recentCommands(limit: 10).count == 1)
        // defaults and clamping
        let all = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"event.replay"}"#))
        #expect(all["result"]?.objectValue?["count"] == .number(3))
        let viaTool = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"event.replay","arguments":{"afterEventId":2}}}"#))
        guard case .array(let items) = try #require(viaTool["result"]?.objectValue?["content"]), let text = items.first?.objectValue?["text"]?.stringValue else { Issue.record("no content"); return }
        #expect(text.contains("\"eventId\":3") && viaTool["result"]?.objectValue?["isError"] == .bool(false))
    }

    @Test func toolsCallSendAndDirectMethodShareTheExecutor() throws {
        let (d, handler) = try make()
        let call = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"message.send","arguments":{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}}}"#))
        let content = try #require(call["result"]?.objectValue?["content"])
        guard case .array(let items) = content, let text = items.first?.objectValue?["text"]?.stringValue else { Issue.record("no content"); return }
        #expect(text.contains("\"succeeded\"") && text.contains("row #1"))
        #expect(call["result"]?.objectValue?["isError"] == .bool(false))
        // same key straight through the protocol method: no second send
        let direct = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"message.send","params":{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}}"#))
        #expect(direct["result"]?.objectValue?["state"] == .string("succeeded"))
        #expect(handler.sends == 1)
        let list = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"conversation.list"}"#))
        #expect(list["result"]?.objectValue?["state"] == .string("succeeded"))
        // command.get with the same key is a lookup, not a duplicate of the send
        let get = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"command.get","params":{"idempotencyKey":"k1"}}"#))
        #expect(get["result"]?.objectValue?["method"] == .string("command.get"))
        #expect(get["result"]?.objectValue?["result"]?.objectValue?["method"] == .string("message.send"))
    }

    @Test func sendFileIsAToolAndADirectMethod() throws {
        let (d, handler) = try make()
        let call = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"message.sendFile","arguments":{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}}}"#))
        #expect(call["result"]?.objectValue?["isError"] == .bool(false) && handler.fileSends.count == 1)
        // a different target from the tools/call send above: the send limiter (3 s per target) would otherwise block this one too
        let direct = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":10,"method":"message.sendFile","params":{"target":"另一个","ossKey":"imctl/a.pdf","fileName":"b.pdf","idempotencyKey":"f9"}}"#))
        #expect(direct["result"]?.objectValue?["state"] == .string("succeeded") && handler.fileSends.last?.source == .ossKey("imctl/a.pdf") && handler.fileSends.last?.fileName == "b.pdf")
    }

    @Test func groupAddMembersIsAToolAndADirectMethod() throws {
        let (d, handler) = try make()
        let call = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"group.addMembers","arguments":{"target":"群A","members":["李四"],"idempotencyKey":"m1"}}}"#))
        let content = try #require(call["result"]?.objectValue?["content"])
        guard case .array(let items) = content, let text = items.first?.objectValue?["text"]?.stringValue else { Issue.record("no content"); return }
        #expect(text.contains("\"succeeded\"") && text.contains("count 3→4"))
        #expect(call["result"]?.objectValue?["isError"] == .bool(false) && handler.groupAddMembersCalls == 1)
        // a different target from the tools/call send above: the send limiter (3 s per target) would otherwise block this one too
        let direct = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":12,"method":"group.addMembers","params":{"target":"群B","members":["王五"],"idempotencyKey":"m2"}}"#))
        #expect(direct["result"]?.objectValue?["state"] == .string("succeeded") && handler.groupAddMembersCalls == 2)
    }

    @Test func numericIdsZeroAndOneStayNumbers() throws {
        let (d, _) = try make()
        let one = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"conversation.list"}"#))
        #expect(one.contains("\"id\":1,") || one.contains("\"id\":1}"))
        #expect(try parse(one)["id"] == .number(1))
        let zero = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"ping"}"#))
        #expect(zero["id"] == .number(0))
        #expect(try JSONValue.parse("[true, 1, 0, false, 1.5]") == .array([.bool(true), .number(1), .number(0), .bool(false), .number(1.5)]))
    }

    @Test func errorsFollowJSONRPC() throws {
        let (d, _) = try make()
        let unknown = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"nope"}"#))
        #expect(unknown["error"]?.objectValue?["code"] == .number(-32601))
        let bad = try parse(d.handle(line: "{not json"))
        #expect(bad["error"]?.objectValue?["code"] == .number(-32700))
        let missingKey = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"message.send","params":{"target":"文件传输助手","text":"hi"}}"#))
        #expect(missingKey["error"]?.objectValue?["data"]?.objectValue?["code"] == .string("INVALID_PARAMS"))
        #expect(d.handle(line: "   ") == nil)
    }

    /// B54: the record view carries the diagnosis as an object, and nothing when there is none.
    @Test func theRecordViewCarriesTheDiagnosis() throws {
        var record = CommandRecord(method: .contactAdd, paramsJSON: "{}", idempotencyKey: "a", nowMs: 1)
        #expect(RPCDispatcher.recordJSON(record).objectValue?["diagnosis"] == nil)
        record.diagnosisJSON = #"{"visual":{"goal":"contactSendVerification","phase":"commit","round":1,"outcome":"stop"},"irreversibleSteps":1}"#
        let diagnosis = try #require(RPCDispatcher.recordJSON(record).objectValue?["diagnosis"]?.objectValue)
        #expect(diagnosis["irreversibleSteps"] == .number(1))
        #expect(diagnosis["visual"]?.objectValue?["outcome"] == .string("stop"))
    }
}

@Suite("message.media query")
struct MediaQueryTests {
    @Test func mediaIsAQueryOnBothPathsAndNeverACommand() throws {
        let store = try ControlStore(path: ":memory:")
        let d = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let direct = try JSONValue.parse(try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"message.media","params":{"messageKey":"k-media"}}"#)))
        #expect(direct.objectValue?["result"]?.objectValue?["url"]?.stringValue?.hasPrefix("https://b.example/") == true && direct.objectValue?["result"]?.objectValue?["matchedBy"]?.stringValue == "observed")
        let missing = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"message.media","params":{"messageKey":"other"}}"#))
        #expect(missing.contains("MEDIA_NOT_FOUND") && missing.contains("\"error\""))
        #expect(d.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"message.media","params":{}}"#)?.contains("INVALID_PARAMS") == true)
        let tool = try JSONValue.parse(try #require(d.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"message.media","arguments":{"messageKey":"k-media","maxPixels":300}}}"#)))
        let result = tool.objectValue?["result"]?.objectValue
        let text = result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        #expect(result?["isError"]?.boolValue == false && text?.contains("\"ossKey\":\"imctl/2026/09/22/k-media-p.png\"") == true)
        #expect(!(text?.contains("base64") ?? true))
        let toolMissing = try JSONValue.parse(try #require(d.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"message.media","arguments":{"messageKey":"zzz"}}}"#)))
        #expect(toolMissing.objectValue?["result"]?.objectValue?["isError"]?.boolValue == true)
        let events = try store.events(after: 0, limit: 10)
        let last = try store.lastEventId()
        #expect(events.isEmpty && last == 0)   // no command record, no events
    }
}

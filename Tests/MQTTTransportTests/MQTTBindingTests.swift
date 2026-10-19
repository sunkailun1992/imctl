import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import MQTTTransport

final class RecordingLink: MQTTLink {
    var messages: [OutboundMessage] = []
    var failNext = false
    struct Boom: Error {}
    func publish(_ message: OutboundMessage) throws {
        if failNext { failNext = false; throw Boom() }
        messages.append(message)
    }
}

final class BindingFakeHandler: CommandHandler {
    var sends = 0
    func describe() throws -> [String: String] { ["platform": "fake"] }
    func accountStatus() throws -> [String: String] { ["windowReachable": "true"] }
    func conversationList() throws -> [[String: String]] { [["title": "文件传输助手"]] }
    func conversationRead(target: String) throws -> [String: String] { ["active": target] }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] { [] }
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        sends += 1; try checkpoint(); try afterSubmit()
        return SendResult(state: .succeeded, evidence: "row #1", latencyMs: 90)
    }
    var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
    func clientNavigate(action: NavigateAction) throws -> [String: String] { ["action": action.rawValue, "changed": "false"] }
    func contactList(limit: Int, scope: String) throws -> [[String: String]] { [] }
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
    func contactRequestList() throws -> [[String: String]] { [] }
    func contactRequestAccept(name: String) throws -> [String: String] { ["name": name, "accepted": "true", "status": "added"] }
    func groupCreate(members: [String], name: String?) throws -> [String: String] { ["title": name ?? "群聊", "memberCount": "2", "renamed": "false"] }
    func groupRename(target: String, name: String) throws -> [String: String] { ["title": name, "renamed": "true", "requestedName": name] }
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        try checkpoint(); try afterSubmit()
        return GroupAddMembersResult(state: .succeeded, target: target, before: 3, after: 4, added: members, skipped: [], dryRun: dryRun, evidence: "count 3→4", latencyMs: 210)
    }
}

@Suite("MQTTBinding")
struct MQTTBindingTests {
    func make() throws -> (MQTTBinding, RecordingLink, ControlStore) {
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: BindingFakeHandler()))
        let link = RecordingLink()
        let settings = MQTTSettings(host: "broker.local", controllerID: "mac-01")
        return (MQTTBinding(settings: settings, dispatcher: dispatcher, store: store, link: link), link, store)
    }

    @Test func topicsFollowTheDesign() {
        let s = MQTTSettings(host: "h", controllerID: "mac-01")
        #expect(s.commandTopic == "im/mac-01/cmd" && s.responseTopic == "im/mac-01/rsp")
        #expect(s.eventTopic == "im/mac-01/evt" && s.stateTopic == "im/mac-01/state" && s.clientID == "imctl-mac-01")
    }

    @Test func commandResponseGoesToResponseTopicWithCorrelation() throws {
        let (binding, link, _) = try make()
        let corr = Data("abc".utf8)
        let response = try binding.handleCommand(
            payload: Data(#"{"jsonrpc":"2.0","id":1,"method":"conversation.list"}"#.utf8),
            responseTopic: nil, correlationData: corr)
        #expect(response?.contains("\"succeeded\"") == true)
        #expect(link.messages.count == 1)
        #expect(link.messages[0].topic == "im/mac-01/rsp" && link.messages[0].correlationData == corr && link.messages[0].qos == 1)
        #expect(link.messages[0].userProperties.contains { $0.0 == "controller_id" && $0.1 == "mac-01" })
    }

    @Test func responseTopicMustLiveUnderOwnSubtree() throws {
        let (binding, link, _) = try make()
        _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":2,"method":"account.status"}"#.utf8),
                                      responseTopic: "im/mac-01/rsp/java-1", correlationData: nil)
        #expect(link.messages.last?.topic == "im/mac-01/rsp/java-1")
        _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":3,"method":"account.status"}"#.utf8),
                                      responseTopic: "java/replies/x", correlationData: nil)
        #expect(link.messages.last?.topic == "im/mac-01/rsp")
        #expect(binding.resolvedResponseTopic("im/mac-02/rsp") == "im/mac-01/rsp")
        #expect(binding.resolvedResponseTopic("") == "im/mac-01/rsp")
        #expect(MQTTSettings(host: "h", controllerID: "mac-01").ownTopicPrefix == "im/mac-01/")
    }

    @Test func notificationsProduceNoResponse() throws {
        let (binding, link, _) = try make()
        let r = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8), responseTopic: nil, correlationData: nil)
        #expect(r == nil && link.messages.isEmpty)
    }

    @Test func eventPumpPublishesOnceInOrderAndPersistsCursor() throws {
        let (binding, link, store) = try make()
        // a send creates accepted/running/succeeded command.state events
        _ = try binding.handleCommand(
            payload: Data(#"{"jsonrpc":"2.0","id":3,"method":"message.send","params":{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}}"#.utf8),
            responseTopic: nil, correlationData: nil)
        link.messages.removeAll()
        let n = try binding.pumpEvents()
        #expect(n == 3)
        let ids = link.messages.compactMap { m in m.userProperties.first { $0.0 == "event_id" }?.1 }
        #expect(ids == ["1", "2", "3"])
        #expect(link.messages.allSatisfy { $0.topic == "im/mac-01/evt" && $0.qos == 1 })
        #expect(try binding.lastPublishedEventId() == 3)
        #expect(try binding.pumpEvents() == 0)
        try store.appendEvent(kind: .conversationActivity, payloadJSON: #"{"title":"x"}"#, nowMs: 5)
        #expect(try binding.pumpEvents() == 1)
        let lastPayload = try #require(link.messages.last?.payload)
        let body = String(decoding: lastPayload, as: UTF8.self)
        #expect(body.contains("\"kind\":\"conversation.activity\"") && body.contains("\"controllerId\":\"mac-01\""))
    }

    @Test func failedPublishDoesNotAdvanceCursor() throws {
        let (binding, link, store) = try make()
        try store.appendEvent(kind: .controllerState, payloadJSON: "{}", nowMs: 1)
        link.failNext = true
        #expect(throws: RecordingLink.Boom.self) { try binding.pumpEvents() }
        #expect(try binding.lastPublishedEventId() == 0)
        #expect(try binding.pumpEvents() == 1)
    }

    @Test func observedMediaSubtypeSurvivesEventPump() throws {
        let (binding, link, store) = try make()
        try store.appendEvent(kind: .messageObserved, payloadJSON: #"{"kind":"media","mediaType":"image","direction":"unknown"}"#, nowMs: 1)
        #expect(try binding.pumpEvents() == 1)
        let data = try #require(link.messages.first?.payload)
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(envelope["payload"] as? [String: String])
        #expect(envelope["kind"] as? String == "message.observed")
        #expect(payload["kind"] == "media" && payload["mediaType"] == "image" && payload["direction"] == "unknown")
    }

    @Test func statePayloadCarriesOnlineFlag() throws {
        let (binding, _, _) = try make()
        let text = String(decoding: binding.statePayload(online: false), as: UTF8.self)
        #expect(text.contains("\"online\":false") && text.contains("\"controllerId\":\"mac-01\""))
    }

    @Test func settingsSaveWithOwnerOnlyMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-mqtt-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("mqtt.json")
        let s = MQTTSettings(host: "h", port: 1883, controllerID: "mac-01", username: "u", password: "p")
        try s.save(to: url)
        #expect(try MQTTSettings.load(from: url) == s)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o077 == 0)
    }

    @Test func theLastCommandTimeIsKept() throws {
        let (binding, _, _) = try make()
        #expect(binding.lastCommandMs == nil)
        _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":1,"method":"event.replay"}"#.utf8), responseTopic: nil, correlationData: nil)
        #expect(binding.lastCommandMs != nil)
    }
}

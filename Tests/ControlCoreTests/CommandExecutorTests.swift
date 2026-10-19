import Foundation
import Testing
@testable import ControlCore

final class FakeHandler: CheckpointedDesktopCommandHandler, DesktopCommandOriginAware {
    var desktopCommandOrigin: DesktopCommandOrigin = .external
    var desktopCommandMethod: RPCMethod?
    var desktopCommandIsBroadcastChild = false
    var desktopCommandVisualEnd: CommandDiagnosis.Visual?
    /// B54: the send ends visually — this end is set, then `sendErrorAfterCheckpoint` is thrown
    /// (or, with `visualEndBeforeCheckpoint`, a guard error before the checkpoint).
    var visualEndOnSend: CommandDiagnosis.Visual?
    var visualEndBeforeCheckpoint = false
    /// B54: contact.add crosses this many checkpoints, then ends visually.
    var contactAddVisualEnd: (checkpoints: Int, visual: CommandDiagnosis.Visual)?
    var seenOrigins: [DesktopCommandOrigin] = []
    var seenMethods: [RPCMethod?] = []
    var seenBroadcastChildren: [Bool] = []
    var sendCalls = 0
    var sendResult = SendResult(state: .succeeded, evidence: "row #9", latencyMs: 100)
    var sendErrorAfterCheckpoint: ControlError?
    var lists = 0
    func describe() throws -> [String: String] { ["platform": "fake"] }
    func accountStatus() throws -> [String: String] { ["loggedIn": "true"] }
    func conversationList() throws -> [[String: String]] { lists += 1; return [["title": "文件传输助手"]] }
    func conversationRead(target: String) throws -> [String: String] { ["active": target] }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] { [["text": "hi", "scrollback": scrollback ? "true" : "false"]] }
    /// Per instance (tests run in parallel; a static here made the rate-limit tests flaky).
    var failReason: String?
    /// Targets that fail (B11 broadcast tests).
    var failingTargets: Set<String> = []
    var sentTargets: [String] = []
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        seenOrigins.append(desktopCommandOrigin)
        seenMethods.append(desktopCommandMethod)
        seenBroadcastChildren.append(desktopCommandIsBroadcastChild)
        sendCalls += 1
        sentTargets.append(target)
        if failingTargets.contains(target) { throw ControlError.targetNotAllowed(target) }
        if let visual = visualEndOnSend, visualEndBeforeCheckpoint {
            desktopCommandVisualEnd = visual
            throw ControlError.localGuard("composer visual round stopped")
        }
        try checkpoint()
        try afterSubmit()
        if let sendErrorAfterCheckpoint {
            if let visual = visualEndOnSend { desktopCommandVisualEnd = visual }
            throw sendErrorAfterCheckpoint
        }
        if let reason = failReason { return SendResult(state: .failed, evidence: nil, reason: reason, latencyMs: 10) }
        return sendResult
    }
    var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
    var navigations: [NavigateAction] = []
    func clientNavigate(action: NavigateAction) throws -> [String: String] {
        navigations.append(action)
        return ["action": action.rawValue, "before": "a", "after": "b", "changed": "true"]
    }
    var accepted: [String] = []
    var groups: [[String]] = []
    var acceptResult: [String: String]?
    var acceptErrorAfterCheckpoint: ControlError?
    var omitAcceptCheckpoint = false
    var groupResult: [String: String]?
    var renameResult: [String: String]?
    var addResult: [String: String]?
    func contactList(limit: Int, scope: String) throws -> [[String: String]] { [["name": "测试联系人A", "source": "wechat"]] }
    func diagnose() throws -> [String: String] { ["trusted": "true"] }
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool) throws -> [String: String] {
        return addResult ?? ["status": dryRun ? "matched" : "requested", "matches": "1", "match0": "\(source)/测试联系人", "dryRun": dryRun ? "true" : "false"]
    }
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool,
                    checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        if let end = contactAddVisualEnd, !dryRun {
            for _ in 0..<end.checkpoints { try checkpoint() }
            desktopCommandVisualEnd = end.visual
            throw ControlError.localGuard("contact add visual round stopped")
        }
        if !dryRun { try checkpoint(); try afterSubmit() }
        return try contactAdd(phone: phone, source: source, greeting: greeting, dryRun: dryRun)
    }
    func permissions(prompt: Bool, probe: Bool) throws -> [String: String] { ["accessibility": "trusted", "wecomData": "granted", "fullDiskAccess": "no", "prompted": prompt ? "true" : "false"] }
    func mediaCache(limit: Int, refresh: Bool) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"]) }
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        guard messageKey == "k-media" else { throw ControlError.mediaNotFound("no observation for \(messageKey)") }
        return MediaReference(messageKey: messageKey, kind: "image", matchedBy: "observed", fileName: "p.png", bytes: 3, contentType: "image/png",
                              ossKey: "imctl/2026/09/22/k-media-p.png", url: "https://b.example/imctl/2026/09/22/k-media-p.png?x-oss-signature=abc", expiresAtMs: 1_790_000_000_000)
    }
    func mediaCacheList(root: String?, dir: String) throws -> MediaCacheReport { MediaCacheReport(status: "ready", roots: ["fake"], entries: [MediaCacheEntry(name: dir, isDirectory: true, size: 0, modifiedMs: 0)]) }
    func contactRequestList() throws -> [[String: String]] { [["name": "测试联系人A", "greeting": "我是 测试联系人A", "source": "wechat", "status": "pending"]] }
    func contactRequestAccept(name: String) throws -> [String: String] {
        accepted.append(name)
        return acceptResult ?? ["name": name, "accepted": "true", "status": "added"]
    }
    func contactRequestAccept(name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        if !omitAcceptCheckpoint { try checkpoint() }
        if let acceptErrorAfterCheckpoint { throw acceptErrorAfterCheckpoint }
        let result = try contactRequestAccept(name: name)
        try afterSubmit()
        return result
    }
    func groupCreate(members: [String], name: String?) throws -> [String: String] {
        groups.append(members)
        return groupResult ?? ["title": name ?? members.joined(separator: "、"), "memberCount": String(members.count + 1),
                               "opened": "true", "renamed": name == nil ? "false" : "true"]
    }
    func groupCreate(members: [String], name: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try checkpoint()
        let result = try groupCreate(members: members, name: name)
        try afterSubmit()
        return result
    }
    func groupRename(target: String, name: String) throws -> [String: String] {
        renameResult ?? ["title": name, "renamed": "true", "requestedName": name]
    }
    func groupRename(target: String, name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try checkpoint()
        let result = try groupRename(target: target, name: name)
        try afterSubmit()
        return result
    }
    var groupAddMembersCalls: [(target: String, members: [String], dryRun: Bool)] = []
    /// When set, the add comes back `failed` — 确定 was pressed and the sheet stayed open, so nothing
    /// was added — with `added` still carrying what the sheet had selected.
    var groupAddMembersFailure: String?
    var groupAddMembersUnknown = false
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        groupAddMembersCalls.append((target, members, dryRun))
        try checkpoint(); try afterSubmit()
        if let reason = groupAddMembersFailure {
            return GroupAddMembersResult(state: .failed, target: target, before: 3, after: nil, added: members, skipped: [], dryRun: dryRun, evidence: reason, latencyMs: 210, reason: reason)
        }
        if groupAddMembersUnknown {
            return GroupAddMembersResult(state: .unknown, target: target, before: 3, after: nil, added: members,
                                         skipped: [], dryRun: dryRun, evidence: "unverified", latencyMs: 210)
        }
        return GroupAddMembersResult(state: .succeeded, target: target, before: 3, after: 4, added: members, skipped: [], dryRun: dryRun, evidence: "count 3→4", latencyMs: 210)
    }
}

final class FakeAPIHandler: APICommandHandler {
    var calls: [(RPCMethod, String)] = []
    var result = #"{"chatId":"wr1"}"#
    func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String { calls.append((method, paramsJSON)); return result }
}

@Suite("CommandExecutor")
struct CommandExecutorTests {
    func make(crash: Bool = false, limiter: RateLimiter? = RateLimiter()) throws -> (CommandExecutor, FakeHandler, ControlStore) {
        let store = try ControlStore(path: ":memory:")
        let handler = FakeHandler()
        var t: Int64 = 1000
        let exec = CommandExecutor(store: store, handler: handler, now: { t += 1; return t }, crashAfterSubmit: crash, rateLimiter: limiter)
        return (exec, handler, store)
    }

    let send = #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}"#

    @Test func sendSucceedsWithEventTrail() throws {
        let (exec, handler, store) = try make()
        let r = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(r.state == .succeeded && r.resultJSON?.contains("row #9") == true && r.checkpointMs != nil)
        #expect(handler.sendCalls == 1)
        let states = try store.events(after: 0, limit: 10).filter { $0.kind == .commandState }.map { $0.payloadJSON }
        #expect(states.count == 3)
        #expect(states[0].contains("\"accepted\"") && states[1].contains("\"running\"") && states[2].contains("\"succeeded\""))
    }

    @Test func duplicateIdempotencyKeyIsNotReRun() throws {
        let (exec, handler, _) = try make()
        let first = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        let second = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(first.id == second.id)
        #expect(handler.sendCalls == 1)
    }

    @Test func sendWithoutKeyIsRejected() throws {
        let (exec, _, _) = try make()
        #expect(throws: ControlError.invalidParams("message.send requires idempotencyKey")) {
            try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: nil)
        }
    }

    @Test func expiredBeforeExecution() throws {
        let (exec, handler, _) = try make()
        let params = #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k2","ttlMs":10,"issuedAtMs":1}"#
        let r = try exec.submit(method: .messageSend, paramsJSON: params, idempotencyKey: "k2")
        #expect(r.state == .expired && r.errorCode == "EXPIRED")
        #expect(handler.sendCalls == 0)
    }

    @Test func pausedControllerFailsSendsButAllowsReads() throws {
        let (exec, handler, _) = try make()
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        let r = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k3")
        #expect(r.state == .failed && r.errorCode == "PAUSED")
        #expect(handler.sendCalls == 0)
        let list = try exec.submit(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil)
        #expect(list.state == .succeeded && handler.lists == 1)
        _ = try exec.submit(method: .controllerResume, paramsJSON: "{}", idempotencyKey: nil)
        let r2 = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k4"}"#, idempotencyKey: "k4")
        #expect(r2.state == .succeeded)
    }

    @Test func crashAfterSubmitBecomesUnknownOnRestartAndNeverReRuns() throws {
        let (exec, handler, store) = try make(crash: true)
        exec.exitHook = { throw CrashInjected() }
        #expect(throws: CrashInjected.self) { try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1") }
        let stuck = try #require(try store.command(idempotencyKey: "k1"))
        #expect(stuck.state == .running && stuck.checkpointMs != nil)
        // "restart": a new executor over the same store
        let exec2 = CommandExecutor(store: store, handler: handler)
        let recovered = try exec2.recoverAfterRestart()
        #expect(recovered.map(\.id) == [stuck.id])
        #expect(try store.command(id: stuck.id)?.state == .unknown)
        let again = try exec2.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(again.state == .unknown)
        #expect(handler.sendCalls == 1)
    }

    /// Finding F8: `message.sendFile` crosses the same irreversible point as `message.send` (⌘V, then the
    /// one Return), so it needs the same proof — a crash between the checkpoint and the evidence becomes
    /// `unknown` on restart, and replaying the key returns that record instead of pasting the file again.
    @Test func crashAfterSendFileCheckpointBecomesUnknownOnRestartAndNeverReRuns() throws {
        let (exec, handler, store) = try make(crash: true)
        exec.exitHook = { throw CrashInjected() }
        let file = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        #expect(throws: CrashInjected.self) { try exec.submit(method: .messageSendFile, paramsJSON: file, idempotencyKey: "f1") }
        let stuck = try #require(try store.command(idempotencyKey: "f1"))
        #expect(stuck.state == .running && stuck.checkpointMs != nil)
        // "restart": a new executor over the same store
        let exec2 = CommandExecutor(store: store, handler: handler)
        let recovered = try exec2.recoverAfterRestart()
        #expect(recovered.map(\.id) == [stuck.id])
        #expect(try store.command(id: stuck.id)?.state == .unknown)
        let again = try exec2.submit(method: .messageSendFile, paramsJSON: file, idempotencyKey: "f1")
        #expect(again.state == .unknown && again.id == stuck.id)
        #expect(handler.fileSends.count == 1)
    }

    @Test func commandGetAndFailureMapping() throws {
        let (exec, handler, _) = try make()
        handler.sendResult = SendResult(state: .failed, reason: "no bubble")
        let r = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(r.state == .failed)
        let got = try exec.submit(method: .commandGet, paramsJSON: #"{"idempotencyKey":"k1"}"#, idempotencyKey: nil)
        #expect(got.state == .succeeded && got.resultJSON?.contains(r.id) == true)
        let describe = try exec.submit(method: .controllerDescribe, paramsJSON: "{}", idempotencyKey: nil)
        #expect(describe.resultJSON?.contains("im-control/0.1") == true)
    }


    @Test func rateLimitIsAHardCapOnAttempts() throws {
        let (exec, handler, _) = try make()
        let first = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(first.state == .succeeded)
        let second = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"again","idempotencyKey":"k2"}"#, idempotencyKey: "k2")
        #expect(second.state == .failed && second.errorCode == "RATE_LIMITED")
        #expect(handler.sendCalls == 1)
        // replaying k1 is not an attempt
        #expect(try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1").id == first.id)
        let other = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"另一个","text":"x","idempotencyKey":"k3"}"#, idempotencyKey: "k3")
        #expect(other.state == .succeeded && handler.sendCalls == 2)
    }

    @Test func globalCapCountsFailedAttemptsToo() throws {
        let store = try ControlStore(path: ":memory:")
        let handler = FakeHandler()
        handler.sendResult = SendResult(state: .failed, reason: "no bubble")
        var t: Int64 = 1000
        let exec = CommandExecutor(store: store, handler: handler, now: { t += 1; return t },
                                   rateLimiter: RateLimiter(perTargetMinIntervalMs: 0, globalLimit: 2, windowMs: 60_000))
        for k in ["a", "b"] {
            _ = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"t","text":"x","idempotencyKey":"\#(k)"}"#, idempotencyKey: k)
        }
        let third = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"t","text":"x","idempotencyKey":"c"}"#, idempotencyKey: "c")
        #expect(third.errorCode == "RATE_LIMITED" && handler.sendCalls == 2)
        let events = try store.events(after: 0, limit: 100).filter { $0.payloadJSON.contains("RATE_LIMITED") }
        #expect(events.count == 1)
    }


    final class MemoryPolicyEditor: PolicyEditing {
        var policy = SendPolicy()
        var refused = false
        func current() throws -> SendPolicy { policy }
        func apply(allow: [String], deny: [String], contactRequests: ContactRequestPolicy?, gateReads: Bool?, allowHosts: [String], denyHosts: [String]) throws -> SendPolicy {
            guard policy.remoteEdits else { refused = true; throw ControlError.localGuard("remote policy edits are off on this Mac") }
            for t in allow { policy.allow(.title(t)) }
            for t in deny { policy.deny(.title(t)) }
            if let r = contactRequests { policy.contactRequests = r }
            if let g = gateReads { policy.gateReads = g }
            for h in allowHosts { policy.sendFile.allow(h) }
            for h in denyHosts { policy.sendFile.deny(h) }
            return policy
        }
    }

    /// B9: the console's policy / diagnostics / log pages over the wire; widening still needs the local switch.
    @Test func daemonLevelMethodsAreServedAndPolicySetNeedsTheLocalSwitch() throws {
        let store = try ControlStore(path: ":memory:")
        let executor = CommandExecutor(store: store, handler: FakeHandler())
        #expect(try executor.submit(method: .policyGet, paramsJSON: "{}", idempotencyKey: nil).errorCode == "UNSUPPORTED")
        let editor = MemoryPolicyEditor()
        executor.policyEditor = editor
        #expect(try executor.submit(method: .policyGet, paramsJSON: "{}", idempotencyKey: nil).resultJSON?.contains("\"remoteEdits\":false") == true)
        let refused = try executor.submit(method: .policySet, paramsJSON: #"{"allow":["imctl测试群"]}"#, idempotencyKey: nil)
        #expect(refused.state == .failed && refused.errorCode == "LOCAL_GUARD" && editor.refused && editor.policy.allowedTitles.isEmpty)
        editor.policy.remoteEdits = true
        let applied = try executor.submit(method: .policySet, paramsJSON: #"{"allow":["imctl测试群"],"contactRequests":{"autoAccept":"rules","allowNames":["测试联系人A"],"groupNameTemplate":"{客户名}-售后"}}"#, idempotencyKey: nil)
        #expect(applied.state == .succeeded && editor.policy.allowedTitles == ["imctl测试群"] && editor.policy.contactRequests.groupName(for: "测试联系人A") == "测试联系人A-售后")
        let gated = try executor.submit(method: .policySet, paramsJSON: #"{"gateReads":true,"allowPhones":["138 0000 0000"]}"#, idempotencyKey: nil)
        #expect(gated.state == .succeeded && editor.policy.gateReads && gated.resultJSON?.contains("\"gateReads\":true") == true)
        // User decision 2026-10-13: no phone list any more — phone fields are still accepted and change nothing.
        let before = editor.policy
        let phonesOnly = try executor.submit(method: .policySet, paramsJSON: #"{"denyPhones":["13800000000"]}"#, idempotencyKey: nil)
        #expect(phonesOnly.state == .succeeded && editor.policy == before && gated.resultJSON?.contains("allowedPhones") == false)
        let hosts = try executor.submit(method: .policySet, paramsJSON: #"{"allowHosts":["cdn.example"]}"#, idempotencyKey: nil)
        #expect(hosts.state == .succeeded && editor.policy.sendFile.allowedHosts == ["cdn.example"])
        #expect(try executor.submit(method: .controllerDiagnose, paramsJSON: "{}", idempotencyKey: nil).resultJSON?.contains("\"trusted\":\"true\"") == true)
        let media = try executor.submit(method: .controllerMediaCache, paramsJSON: #"{"limit":5}"#, idempotencyKey: nil)
        #expect(media.state == .succeeded && media.resultJSON?.contains("\"status\":\"ready\"") == true)
        #expect(try executor.submit(method: .controllerLogs, paramsJSON: "{}", idempotencyKey: nil).errorCode == "UNSUPPORTED")
        executor.logReader = { n in Array(["a", "b", "c"].suffix(n)) }
        let logs = try executor.submit(method: .controllerLogs, paramsJSON: #"{"lines":2}"#, idempotencyKey: nil)
        #expect(logs.resultJSON?.contains("\"lines\":\"b\\nc\"") == true && logs.resultJSON?.contains("\"count\":\"2\"") == true)
    }

    /// B14 review F3: 「全部放开」 stays a local decision. `policy.set` has no `allowAll`
    /// parameter at all, so a caller that smuggles one into the params — even with `remoteEdits` on,
    /// i.e. past the one guard that stands between the wire and the policy file — widens nothing: the
    /// switch is only reachable through `imctl policy all` / the console on this Mac, where the daemon
    /// log and `controller.describe.policy` show it. The returned policy is what the console reads
    /// back, so it has to keep saying `false` too.
    @Test func policySetCanNeverTurnOnAllowAll() throws {
        let store = try ControlStore(path: ":memory:")
        let executor = CommandExecutor(store: store, handler: FakeHandler())
        let editor = MemoryPolicyEditor()
        editor.policy.remoteEdits = true
        executor.policyEditor = editor
        let smuggled = try executor.submit(method: .policySet, paramsJSON: #"{"allow":["x"],"allowAll":true}"#, idempotencyKey: nil)
        #expect(smuggled.state == .succeeded && editor.policy.allowedTitles == ["x"])   // the rest of the call still applies
        #expect(editor.policy.allowAll == false)
        #expect(smuggled.resultJSON?.contains("\"allowAll\":false") == true)
        #expect(try executor.submit(method: .policyGet, paramsJSON: "{}", idempotencyKey: nil).resultJSON?.contains("\"allowAll\":true") == false)
    }

    /// A handler-reported failure (a send without its bubble) puts its reason on the record, not only inside the result.
    @Test func failedSendCarriesItsReasonOnTheRecord() throws {
        let store = try ControlStore(path: ":memory:")
        let handler = FakeHandler()
        handler.failReason = "no matching bubble within 10s; composer still holds the text"
        let executor = CommandExecutor(store: store, handler: handler)
        let r = try executor.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"x","idempotencyKey":"k-fail"}"#, idempotencyKey: "k-fail")
        #expect(r.state == .failed && r.errorMessage == handler.failReason)
    }

    @Test func apiMethodsGoToTheApiHandlerAndAreUnsupportedWithoutOne() throws {
        let (exec, handler, _) = try make()
        let none = try exec.submit(method: .groupGet, paramsJSON: #"{"chatId":"wr1"}"#, idempotencyKey: nil)
        #expect(none.state == .failed && none.errorCode == "UNSUPPORTED")
        let api = FakeAPIHandler()
        exec.apiHandler = api
        let got = try exec.submit(method: .groupGet, paramsJSON: #"{"chatId":"wr1"}"#, idempotencyKey: nil)
        #expect(got.state == .succeeded && got.resultJSON == #"{"chatId":"wr1"}"# && api.calls.count == 1 && api.calls[0].0 == .groupGet)
        #expect(handler.sendCalls == 0)
        #expect(throws: ControlError.invalidParams("broadcast.create requires idempotencyKey")) {
            try exec.submit(method: .broadcastCreate, paramsJSON: "{}", idempotencyKey: nil)
        }
        let b1 = try exec.submit(method: .broadcastCreate, paramsJSON: #"{"text":"hi","idempotencyKey":"b1"}"#, idempotencyKey: "b1")
        let b2 = try exec.submit(method: .broadcastCreate, paramsJSON: #"{"text":"hi","idempotencyKey":"b1"}"#, idempotencyKey: "b1")
        #expect(b1.id == b2.id && api.calls.count == 2)
        // pause does not gate API methods
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        #expect(try exec.submit(method: .groupList, paramsJSON: "{}", idempotencyKey: nil).state == .succeeded)
        let describe = try exec.submit(method: .controllerDescribe, paramsJSON: "{}", idempotencyKey: nil)
        #expect(describe.resultJSON?.contains("\"wecomApi\":\"enabled\"") == true)
    }

    @Test func broadcastDesktopConfirmRequiresVerifiedEvidenceForSuccess() throws {
        let (exec, _, _) = try make(limiter: nil)
        let api = FakeAPIHandler()
        exec.apiHandler = api
        api.result = #"{"verified":"false","msgid":"test"}"#
        let uncertain = try exec.submit(method: .broadcastConfirm, paramsJSON: #"{"msgid":"test"}"#, idempotencyKey: nil)
        #expect(uncertain.state == .unknown && uncertain.checkpointMs != nil && uncertain.idempotencyKey?.hasPrefix("broadcast.confirm:") == true)
        let replay = try exec.submit(method: .broadcastConfirm, paramsJSON: #"{"msgid":"test"}"#, idempotencyKey: nil)
        #expect(replay.id == uncertain.id && api.calls.count == 1)
        api.result = #"{"verified":"true","msgid":"test"}"#
        let confirmed = try exec.submit(method: .broadcastConfirm, paramsJSON: #"{"msgid":"another-test"}"#, idempotencyKey: nil)
        #expect(confirmed.state == .succeeded)
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        let paused = try exec.submit(method: .broadcastConfirm, paramsJSON: #"{"msgid":"paused-test"}"#, idempotencyKey: nil)
        #expect(paused.state == .failed && paused.errorCode == "PAUSED" && api.calls.count == 2)
    }

    @Test func clientNavigateNeedsKeyRespectsPauseAndRoutesToHandler() throws {
        let (exec, handler, store) = try make()
        let params = #"{"action":"nextConversation","idempotencyKey":"n1"}"#
        #expect(throws: ControlError.invalidParams("client.navigate requires idempotencyKey")) {
            try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: nil)
        }
        let ok = try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: "n1")
        #expect(ok.state == .succeeded && ok.resultJSON?.contains(#""changed":"true""#) == true && handler.navigations == [.nextConversation])
        // same key replays the record without a second press
        #expect(try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: "n1").id == ok.id && handler.navigations.count == 1)
        let bad = try exec.submit(method: .clientNavigate, paramsJSON: #"{"action":"messagesView","idempotencyKey":"n2"}"#, idempotencyKey: "n2")
        #expect(bad.state == .failed && bad.errorCode == "INVALID_PARAMS" && handler.navigations.count == 1)
        try store.setPause(.api, on: true, nowMs: 5)
        let paused = try exec.submit(method: .clientNavigate, paramsJSON: params.replacingOccurrences(of: "n1", with: "n3"), idempotencyKey: "n3")
        #expect(paused.state == .failed && paused.errorCode == "PAUSED" && handler.navigations.count == 1)
    }

    /// B11: one record for the run, one paced child send per target, other clients' commands allowed in between.
    @Test func broadcastSendsOnePacedChildPerTargetAndReportsEveryOutcome() throws {
        let (exec, handler, store) = try make()
        handler.failingTargets = ["坏目标"]
        var slept: [Int64] = []
        exec.sleep = { slept.append($0) }
        let params = #"{"targets":["文件传输助手","坏目标","另一个"],"text":"hello","idempotencyKey":"bc1","intervalMs":2000}"#
        let run = try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc1")
        let result = try JSONDecoder().decode(BroadcastResult.self, from: Data((run.resultJSON ?? "").utf8))
        #expect(run.state == .failed && run.errorCode == "TARGET_NOT_ALLOWED" && run.errorMessage?.hasPrefix("1 of 3 target(s) failed") == true)
        #expect(result.total == 3 && result.succeeded == 2 && result.failed == 1 && result.items.map(\.target) == ["文件传输助手", "坏目标", "另一个"])
        #expect(result.items[0].state == "succeeded" && result.items[0].evidence == "row #9" && result.items[1].errorCode == "TARGET_NOT_ALLOWED")
        #expect(handler.sentTargets == ["文件传输助手", "坏目标", "另一个"] && slept == [2000, 2000])
        // children are ordinary send records with derived keys; the run is replayed by its own key
        let child0 = try store.command(idempotencyKey: "bc1#0"), child1 = try store.command(idempotencyKey: "bc1#1")
        #expect(child0?.state == .succeeded && child1?.state == .failed)
        #expect(try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc1").id == run.id && handler.sendCalls == 3)
        #expect(throws: ControlError.self) { try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: nil) }
        #expect(throws: ControlError.self) { try exec.submit(method: .messageBroadcast, paramsJSON: #"{"targets":[],"text":"x","idempotencyKey":"bc2"}"#, idempotencyKey: "bc2") }
        #expect(throws: ControlError.self) { try exec.submit(method: .messageBroadcast, paramsJSON: #"{"targets":["a","a"],"text":"x","idempotencyKey":"bc3"}"#, idempotencyKey: "bc3") }
        let ok = try exec.submit(method: .messageBroadcast, paramsJSON: #"{"targets":["甲","乙"],"text":"x","idempotencyKey":"bc4","intervalMs":0,"stopOnFailure":true}"#, idempotencyKey: "bc4")
        #expect(ok.state == .succeeded && ok.errorCode == nil)
        // the rate limiter is waited for, not burned: with the global cap at 2 the third target waits and then goes
        let (paced, pacedHandler, _) = try make(limiter: RateLimiter(perTargetMinIntervalMs: 0, globalLimit: 2, windowMs: 60_000))
        var waits = 0
        paced.sleep = { _ in waits += 1 }
        paced.broadcastMaxWaitMs = 3000
        let capped = try paced.submit(method: .messageBroadcast, paramsJSON: #"{"targets":["a","b","c"],"text":"x","idempotencyKey":"bc5","intervalMs":0}"#, idempotencyKey: "bc5")
        let cappedResult = try JSONDecoder().decode(BroadcastResult.self, from: Data((capped.resultJSON ?? "").utf8))
        #expect(pacedHandler.sendCalls == 2 && cappedResult.items[2].errorCode == "RATE_LIMITED" && waits >= 3)
        #expect(try paced.submit(method: .controllerPermissions, paramsJSON: #"{"prompt":true}"#, idempotencyKey: nil).resultJSON?.contains("\"prompted\":\"true\"") == true)
    }

    @Test func broadcastWithUnknownChildStaysUnknownAndDoesNotRetry() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.sendResult = SendResult(state: .unknown, evidence: nil, reason: "client evidence absent")
        let params = #"{"targets":["文件传输助手"],"text":"test","idempotencyKey":"bc-unknown","intervalMs":0}"#
        let first = try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc-unknown")
        #expect(first.state == .unknown && first.errorCode == "UNKNOWN_CHILD")
        let replay = try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc-unknown")
        #expect(replay.id == first.id && handler.sendCalls == 1)
    }

    /// B12: contact.add needs a key, is paused with the client actions, and counts real adds against their own
    /// hourly cap; since the phone list went (2026-10-13) a malformed number is refused before the client and
    /// searches (dry runs) count against a cap of their own.
    @Test func contactAddIsKeyedValidatedAndCappedPerHour() throws {
        let (exec, _, _) = try make()
        #expect(throws: ControlError.self) { try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","idempotencyKey":"a0"}"#, idempotencyKey: nil) }
        let badSource = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"sms","idempotencyKey":"a0"}"#, idempotencyKey: "a0")
        #expect(badSource.state == .failed && badSource.errorCode == "INVALID_PARAMS")
        let malformed = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"abc1","idempotencyKey":"a1"}"#, idempotencyKey: "a1")
        #expect(malformed.state == .failed && malformed.errorCode == "INVALID_PARAMS")
        exec.contactAddsPerHour = { 1 }
        exec.contactSearchesPerHour = { 1 }
        let dry = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","dryRun":true,"idempotencyKey":"a2"}"#, idempotencyKey: "a2")
        #expect(dry.state == .succeeded && dry.resultJSON?.contains("\"status\":\"matched\"") == true)
        let first = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wechat","idempotencyKey":"a3"}"#, idempotencyKey: "a3")
        #expect(first.state == .succeeded && first.resultJSON?.contains("\"match0\":\"wechat/测试联系人\"") == true)
        let capped = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","idempotencyKey":"a4"}"#, idempotencyKey: "a4")
        #expect(capped.state == .failed && capped.errorCode == "RATE_LIMITED")
        let searchCapped = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13900000001","dryRun": true,"idempotencyKey":"a5"}"#,
                                           idempotencyKey: "a5")
        #expect(searchCapped.state == .failed && searchCapped.errorCode == "RATE_LIMITED" && searchCapped.errorMessage?.contains("search") == true)
        #expect(try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wechat","idempotencyKey":"a3"}"#, idempotencyKey: "a3").id == first.id)
    }

    @Test func rateLimitIsPerConversationNotPerSpelling() throws {
        let (exec, handler, store) = try make()
        try store.upsertIdentity(kind: .group, id: "g1", title: "文件传输助手", nowMs: 1)
        let first = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"chatId:g1","text":"a","idempotencyKey":"r1"}"#, idempotencyKey: "r1")
        #expect(first.state == .succeeded)
        let second = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"b","idempotencyKey":"r2"}"#, idempotencyKey: "r2")
        #expect(second.state == .failed && second.errorCode == "RATE_LIMITED" && handler.sendCalls == 1)
        let unknownId = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"chatId:nobody","text":"c","idempotencyKey":"r3"}"#, idempotencyKey: "r3")
        #expect(unknownId.state == .succeeded && handler.sendCalls == 2)   // unbridged id: its own key
    }

    @Test func acceptAndGroupCreateEmitDomainEventsAndAcceptsAreCapped() throws {
        let (exec, handler, store) = try make()
        exec.acceptsPerHour = { 2 }
        let a1 = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"测试联系人A","idempotencyKey":"auto-1"}"#, idempotencyKey: "auto-1")
        #expect(a1.state == .succeeded && handler.accepted == ["测试联系人A"])
        let accepted = try store.events(after: 0, limit: 50).filter { $0.kind == .contactRequestAccepted }
        #expect(accepted.count == 1 && accepted[0].payloadJSON.contains(#""by":"policy""#) && accepted[0].payloadJSON.contains(a1.id))
        _ = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"B","idempotencyKey":"r-2"}"#, idempotencyKey: "r-2")
        let third = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"C","idempotencyKey":"r-3"}"#, idempotencyKey: "r-3")
        #expect(third.state == .failed && third.errorCode == "RATE_LIMITED" && handler.accepted.count == 2)
        let g = try exec.submit(method: .groupCreate, paramsJSON: #"{"members":["测试联系人A"],"name":"测试联系人A群聊","idempotencyKey":"g1"}"#, idempotencyKey: "g1")
        #expect(g.state == .succeeded && handler.groups == [["测试联系人A"]])
        let created = try store.events(after: 0, limit: 50).filter { $0.kind == .groupCreated }
        #expect(created.count == 1 && created[0].payloadJSON.contains(#""requestedName":"测试联系人A群聊""#))
        #expect(throws: ControlError.invalidParams("group.create requires idempotencyKey")) {
            try exec.submit(method: .groupCreate, paramsJSON: #"{"members":["x"],"idempotencyKey":"g2"}"#, idempotencyKey: nil)
        }
        try store.setPause(.api, on: true, nowMs: 5)
        #expect(try exec.submit(method: .contactList, paramsJSON: "{}", idempotencyKey: nil).errorCode == "PAUSED")
    }

    @Test func desktopMutationsDoNotClaimSuccessWithoutTheirOwnEvidence() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.acceptResult = ["accepted": "false", "status": "pending"]
        let accept = try exec.submit(method: .contactRequestAccept,
                                     paramsJSON: #"{"name":"测试联系人","idempotencyKey":"uncertain-accept"}"#,
                                     idempotencyKey: "uncertain-accept")
        #expect(accept.state == .unknown && accept.checkpointMs != nil)
        #expect(try store.events(after: 0, limit: 100).filter { $0.kind == .contactRequestAccepted }.isEmpty)

        handler.groupResult = ["title": "临时群", "opened": "true", "renamed": "false"]
        let create = try exec.submit(method: .groupCreate,
                                     paramsJSON: #"{"members":["甲","乙"],"name":"预期群名","idempotencyKey":"uncertain-create"}"#,
                                     idempotencyKey: "uncertain-create")
        #expect(create.state == .unknown && create.checkpointMs != nil)
        #expect(try store.events(after: 0, limit: 100).filter { $0.kind == .groupCreated }.isEmpty)

        handler.renameResult = ["title": "旧名", "renamed": "false", "requestedName": "新名"]
        let rename = try exec.submit(method: .groupRename,
                                     paramsJSON: #"{"target":"测试群","name":"新名","idempotencyKey":"uncertain-rename"}"#,
                                     idempotencyKey: "uncertain-rename")
        #expect(rename.state == .unknown && rename.checkpointMs != nil)

        handler.addResult = ["status": "pressed", "dryRun": "false"]
        let add = try exec.submit(method: .contactAdd,
                                  paramsJSON: #"{"phone":"13800000000","idempotencyKey":"uncertain-add"}"#,
                                  idempotencyKey: "uncertain-add")
        #expect(add.state == .unknown && add.checkpointMs != nil)
        #expect(try exec.submit(method: .contactAdd,
                                paramsJSON: #"{"phone":"13800000000","idempotencyKey":"uncertain-add"}"#,
                                idempotencyKey: "uncertain-add").id == add.id)
    }

    @Test func controlErrorAfterIrreversibleCheckpointIsUnknown() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.acceptErrorAfterCheckpoint = .targetNotAllowed("later policy recheck")
        let params = #"{"name":"测试联系人","idempotencyKey":"post-checkpoint-error"}"#
        let first = try exec.submit(method: .contactRequestAccept, paramsJSON: params,
                                    idempotencyKey: "post-checkpoint-error")
        #expect(first.state == .unknown && first.checkpointMs != nil)
        #expect(try store.events(after: 0, limit: 100).filter { $0.kind == .contactRequestAccepted }.isEmpty)
        handler.acceptErrorAfterCheckpoint = nil
        let replay = try exec.submit(method: .contactRequestAccept, paramsJSON: params,
                                     idempotencyKey: "post-checkpoint-error")
        #expect(replay.id == first.id && replay.state == .unknown && handler.accepted.isEmpty)
    }

    @Test func verifiedMutationWithoutItsCheckpointCannotSucceed() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.omitAcceptCheckpoint = true
        let record = try exec.submit(method: .contactRequestAccept,
                                     paramsJSON: #"{"name":"测试联系人","idempotencyKey":"missing-boundary"}"#,
                                     idempotencyKey: "missing-boundary")
        #expect(record.state == .unknown && record.checkpointMs == nil)
        #expect(try store.events(after: 0, limit: 100).filter { $0.kind == .contactRequestAccepted }.isEmpty)
    }

    @Test func sendErrorAfterCheckpointIsUnknownAndNeverRetried() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("bubble missing")
        let params = #"{"target":"文件传输助手","text":"hello","idempotencyKey":"send-post-error"}"#
        let first = try exec.submit(method: .messageSend, paramsJSON: params, idempotencyKey: "send-post-error")
        #expect(first.state == .unknown && first.errorCode == "UNKNOWN_AFTER_CHECKPOINT" && first.checkpointMs != nil)
        handler.sendErrorAfterCheckpoint = nil
        let replay = try exec.submit(method: .messageSend, paramsJSON: params, idempotencyKey: "send-post-error")
        #expect(replay.id == first.id && replay.state == .unknown && handler.sendCalls == 1)
    }

    @Test func unknownDesktopAttemptCountsAgainstTheHourlyLimit() throws {
        let (exec, handler, _) = try make(limiter: nil)
        exec.contactAddsPerHour = { 1 }
        handler.addResult = ["status": "pressed", "dryRun": "false"]
        let first = try exec.submit(method: .contactAdd,
                                    paramsJSON: #"{"phone":"13800000000","idempotencyKey":"first"}"#,
                                    idempotencyKey: "first")
        let second = try exec.submit(method: .contactAdd,
                                     paramsJSON: #"{"phone":"13800000000","idempotencyKey":"second"}"#,
                                     idempotencyKey: "second")
        #expect(first.state == .unknown && second.state == .failed && second.errorCode == "RATE_LIMITED")
    }

    @Test func interruptedDesktopMutationRecoversAsUnknownWithoutRepeating() throws {
        let (exec, handler, store) = try make(crash: true, limiter: nil)
        exec.exitHook = { throw CrashInjected() }
        let params = #"{"members":["甲","乙"],"idempotencyKey":"group-crash"}"#
        #expect(throws: CrashInjected.self) {
            try exec.submit(method: .groupCreate, paramsJSON: params, idempotencyKey: "group-crash")
        }
        let pending = try #require(try store.command(idempotencyKey: "group-crash"))
        #expect(pending.state == .running && pending.checkpointMs != nil && handler.groups.count == 1)
        let recovered = CommandExecutor(store: store, handler: handler, rateLimiter: nil)
        #expect(try recovered.recoverAfterRestart().count == 1)
        let replay = try recovered.submit(method: .groupCreate, paramsJSON: params, idempotencyKey: "group-crash")
        #expect(replay.state == .unknown && handler.groups.count == 1)
    }

    @Test func automationOriginIsScopedToItsCommandAndBroadcastChildren() throws {
        let (exec, handler, _) = try make(limiter: nil)
        exec.sleep = { _ in }
        _ = try exec.submit(method: .messageSend,
                            paramsJSON: #"{"target":"甲","text":"一","idempotencyKey":"origin-1"}"#,
                            idempotencyKey: "origin-1")
        _ = try exec.submit(method: .messageBroadcast,
                            paramsJSON: #"{"targets":["乙","丙"],"text":"二","idempotencyKey":"origin-b","intervalMs":0}"#,
                            idempotencyKey: "origin-b", origin: .automation)
        #expect(handler.seenOrigins == [.external, .automation, .automation])
        #expect(handler.seenMethods == [.messageSend, .messageSend, .messageSend])
        #expect(handler.seenBroadcastChildren == [false, true, true])
        #expect(handler.desktopCommandOrigin == .external)
        #expect(handler.desktopCommandMethod == nil)
        #expect(handler.desktopCommandIsBroadcastChild == false)
    }

    @Test func externalBroadcastChildrenKeepOriginButHaveAnExplicitScope() throws {
        let (exec, handler, _) = try make(limiter: nil)
        exec.sleep = { _ in }
        let params = #"{"targets":["甲","乙"],"text":"test","idempotencyKey":"scope-b","intervalMs":0}"#
        let first = try exec.submit(method: .messageBroadcast, paramsJSON: params,
                                    idempotencyKey: "scope-b")
        #expect(first.state == .succeeded)
        #expect(handler.seenOrigins == [.external, .external])
        #expect(handler.seenMethods == [.messageSend, .messageSend])
        #expect(handler.seenBroadcastChildren == [true, true])
        #expect(!handler.desktopCommandIsBroadcastChild)
        let replay = try exec.submit(method: .messageBroadcast, paramsJSON: params,
                                     idempotencyKey: "scope-b")
        #expect(replay.id == first.id && handler.sendCalls == 2)
    }

    @Test func sendFileRoutesValidatesAndIsRateLimitedLikeASend() throws {
        let (exec, handler, store) = try make()
        let url = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        let r = try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: "f1")
        #expect(r.state == .succeeded && r.resultJSON?.contains("\"kind\":\"file\"") == true && r.checkpointMs != nil)
        #expect(handler.fileSends.count == 1 && handler.fileSends[0].source == .url(URL(string: "https://cdn.example/a.pdf")!))
        #expect(try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: "f1").id == r.id && handler.fileSends.count == 1)
        // the same conversation within 3 s: the send limiter counts file sends too
        let again = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","ossKey":"imctl/x.pdf","idempotencyKey":"f2"}"#, idempotencyKey: "f2")
        #expect(again.state == .failed && again.errorCode == "RATE_LIMITED")
        // a fresh target (not "文件传输助手" again, which the send limiter above is still cooling down on): this
        // checks url/ossKey validation, not the limiter. Unlike the missing-idempotencyKey case below, this
        // INVALID_PARAMS is raised inside execute(), so run()'s catch turns it into a failed record rather
        // than a thrown error (same as the existing badSource / bad-navigate-action cases in this file).
        let invalidSource = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"另一个","idempotencyKey":"f3"}"#, idempotencyKey: "f3")
        #expect(invalidSource.state == .failed && invalidSource.errorCode == "INVALID_PARAMS" && invalidSource.errorMessage == "message.sendFile needs exactly one of url / ossKey")
        // both present is equally invalid (same message as neither); another fresh target, since "文件传输助手"
        // and "另一个" above are both still cooling down on the 3 s per-conversation limiter.
        let bothSources = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"第三个","url":"https://cdn.example/a.pdf","ossKey":"imctl/x.pdf","idempotencyKey":"f3b"}"#, idempotencyKey: "f3b")
        #expect(bothSources.state == .failed && bothSources.errorCode == "INVALID_PARAMS" && bothSources.errorMessage == "message.sendFile needs exactly one of url / ossKey")
        #expect(throws: ControlError.self) { try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: nil) }
        let expired = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f4","ttlMs":10,"issuedAtMs":1}"#, idempotencyKey: "f4")
        #expect(expired.state == .expired)
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        let paused = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"other","url":"https://cdn.example/b.pdf","idempotencyKey":"f5"}"#, idempotencyKey: "f5")
        #expect(paused.state == .failed && paused.errorCode == "PAUSED")
        exec.ossEnabled = { true }
        let describe = try exec.submit(method: .controllerDescribe, paramsJSON: "{}", idempotencyKey: nil)
        #expect(describe.resultJSON?.contains("\"oss\":\"enabled\"") == true)
        #expect(try store.recentSends(sinceMs: 0).contains { $0.kind == "file" && $0.fileName == "a.pdf" })
    }

    /// B14: `group.addMembers` shares `message.sendFile`'s pipeline — idempotency, the per-conversation
    /// limiter, checkpoint/afterSubmit hooks around the handler call — and additionally emits
    /// `group.membersAdded` once per real add (never for a `dryRun`).
    @Test func groupAddMembersRoutesValidatesIsRateLimitedAndEmitsAnEventOnceExceptForDryRun() throws {
        let (exec, handler, store) = try make()
        let params = #"{"target":"群A","members":["李四","王五"],"idempotencyKey":"m1"}"#
        let r = try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "m1")
        #expect(r.state == .succeeded && r.resultJSON?.contains("count 3→4") == true && r.checkpointMs != nil)
        #expect(handler.groupAddMembersCalls.count == 1 && handler.groupAddMembersCalls[0].members == ["李四", "王五"])
        // replaying the key returns the same record without a second handler call
        #expect(try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "m1").id == r.id)
        #expect(handler.groupAddMembersCalls.count == 1)
        let events = try store.events(after: 0, limit: 50).filter { $0.kind == .groupMembersAdded }
        #expect(events.count == 1 && events[0].payloadJSON.contains(#""added":"李四,王五""#)
                && events[0].payloadJSON.contains(#""before":"3""#) && events[0].payloadJSON.contains(#""after":"4""#))

        // dryRun succeeds but never emits the event
        let dry = try exec.submit(method: .groupAddMembers, paramsJSON: #"{"target":"群B","members":["李四"],"dryRun":true,"idempotencyKey":"m2"}"#, idempotencyKey: "m2")
        #expect(dry.state == .succeeded)
        #expect(try store.events(after: 0, limit: 50).filter { $0.kind == .groupMembersAdded }.count == 1)

        // the same target again within 3 s is rate-limited; a fresh target is not
        let again = try exec.submit(method: .groupAddMembers, paramsJSON: #"{"target":"群A","members":["赵六"],"idempotencyKey":"m3"}"#, idempotencyKey: "m3")
        #expect(again.state == .failed && again.errorCode == "RATE_LIMITED" && handler.groupAddMembersCalls.count == 2)
        let other = try exec.submit(method: .groupAddMembers, paramsJSON: #"{"target":"群C","members":["赵六"],"idempotencyKey":"m4"}"#, idempotencyKey: "m4")
        #expect(other.state == .succeeded && handler.groupAddMembersCalls.count == 3)

        // INVALID_PARAMS: empty members, and more than 20 (fresh targets so the limiter is not the reason)
        let empty = try exec.submit(method: .groupAddMembers, paramsJSON: #"{"target":"群D","members":[],"idempotencyKey":"m5"}"#, idempotencyKey: "m5")
        #expect(empty.state == .failed && empty.errorCode == "INVALID_PARAMS")
        let many = (1...21).map { "\"m\($0)\"" }.joined(separator: ",")
        let tooMany = try exec.submit(method: .groupAddMembers, paramsJSON: "{\"target\":\"群E\",\"members\":[\(many)],\"idempotencyKey\":\"m6\"}", idempotencyKey: "m6")
        #expect(tooMany.state == .failed && tooMany.errorCode == "INVALID_PARAMS")
        #expect(handler.groupAddMembersCalls.count == 3)
        #expect(throws: ControlError.invalidParams("group.addMembers requires idempotencyKey")) {
            try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: nil)
        }
    }

    /// B14 review F1 + F7: a `failed` add — 确定 pressed, the sheet stayed open, so the group gained
    /// nobody — must NOT emit `group.membersAdded`, even though `added` is non-empty: `added` is what
    /// the sheet had selected, not what the group got. Only confirmed success
    /// may announce members. And, like a failed `message.sendFile`, the result's `reason`
    /// has to reach the command record, so a consumer reading the record alone learns why.
    @Test func aFailedGroupAddMembersEmitsNoEventAndCarriesItsReason() throws {
        let (exec, handler, store) = try make()
        handler.groupAddMembersFailure = "sheet-still-open"
        let r = try exec.submit(method: .groupAddMembers, paramsJSON: #"{"target":"群F","members":["李四"],"idempotencyKey":"f1"}"#, idempotencyKey: "f1")
        #expect(r.state == .failed && handler.groupAddMembersCalls.count == 1)
        #expect(try store.events(after: 0, limit: 50).filter { $0.kind == .groupMembersAdded }.isEmpty)
        #expect(r.errorMessage == "sheet-still-open")
    }

    @Test func uncertainGroupAddMembersHasTerminalUnknownButNoMembershipEvent() throws {
        let (exec, handler, store) = try make()
        handler.groupAddMembersUnknown = true
        let params = #"{"target":"群U","members":["李四"],"idempotencyKey":"u1"}"#
        let record = try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "u1")
        #expect(record.state == .unknown && record.checkpointMs != nil)
        #expect(handler.groupAddMembersCalls.count == 1)
        let events = try store.events(after: 0, limit: 50)
        #expect(events.filter { $0.kind == .groupMembersAdded }.isEmpty)
        #expect(events.contains { $0.kind == .commandState && $0.payloadJSON.contains("unknown") })
        let replay = try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "u1")
        #expect(replay.id == record.id && replay.state == .unknown)
        #expect(handler.groupAddMembersCalls.count == 1)
    }

    /// B14: crosses the same irreversible point as `message.send` / `message.sendFile` (the sheet's
    /// own 确定), so a crash between the checkpoint and the evidence becomes `unknown` on restart, and
    /// replaying the key returns that record instead of running the add again.
    @Test func crashAfterGroupAddMembersCheckpointBecomesUnknownOnRestartAndNeverReRuns() throws {
        let (exec, handler, store) = try make(crash: true)
        exec.exitHook = { throw CrashInjected() }
        let params = #"{"target":"群A","members":["李四"],"idempotencyKey":"m1"}"#
        #expect(throws: CrashInjected.self) { try exec.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "m1") }
        let stuck = try #require(try store.command(idempotencyKey: "m1"))
        #expect(stuck.state == .running && stuck.checkpointMs != nil)
        // "restart": a new executor over the same store
        let exec2 = CommandExecutor(store: store, handler: handler)
        let recovered = try exec2.recoverAfterRestart()
        #expect(recovered.map(\.id) == [stuck.id])
        #expect(try store.command(id: stuck.id)?.state == .unknown)
        let again = try exec2.submit(method: .groupAddMembers, paramsJSON: params, idempotencyKey: "m1")
        #expect(again.state == .unknown && again.id == stuck.id)
        #expect(handler.groupAddMembersCalls.count == 1)
        #expect(try store.events(after: 0, limit: 50).filter { $0.kind == .groupMembersAdded }.isEmpty)
    }

    static func diagnosis(_ record: CommandRecord) -> CommandDiagnosis? {
        record.diagnosisJSON.flatMap { try? JSONDecoder().decode(CommandDiagnosis.self, from: Data($0.utf8)) }
    }
    static let stop = CommandDiagnosis.Visual(goal: "sendButton", phase: "commit", round: 2, outcome: "stop")

    /// B54: a visual end after the checkpoint stays `unknown` and keeps where it ended, with one irreversible point.
    @Test func aVisualEndAfterTheCheckpointIsUnknownWithItsDiagnosis() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let record = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(record.state == .unknown && record.errorCode == "UNKNOWN_AFTER_CHECKPOINT")
        #expect(Self.diagnosis(record) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 1))
        let last = try #require(try store.events(after: 0, limit: 100).last { $0.kind == .commandState })
        #expect(last.payloadJSON.contains(#""visualOutcome":"stop""#) && last.payloadJSON.contains(#""irreversibleSteps":"1""#)
                && last.payloadJSON.contains(#""visualGoal":"sendButton""#))
    }

    /// A visual end before any checkpoint fails with the same diagnosis and zero irreversible points.
    @Test func aVisualEndBeforeAnyCheckpointFailsWithZeroSteps() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.visualEndOnSend = Self.stop
        handler.visualEndBeforeCheckpoint = true
        let record = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(record.state == .failed && record.checkpointMs == nil)
        #expect(Self.diagnosis(record) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 0))
    }

    /// Ends that are not visual carry no diagnosis; successes neither; an end left on the handler from outside
    /// the executor is cleared before the next command.
    @Test func nonVisualEndsAndSuccessesCarryNoDiagnosis() throws {
        let (exec, handler, _) = try make(limiter: nil)
        let ok = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(ok.state == .succeeded && ok.diagnosisJSON == nil)
        handler.sendErrorAfterCheckpoint = .localGuard("bubble missing")
        handler.desktopCommandVisualEnd = Self.stop
        let lost = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k2"}"#, idempotencyKey: "k2")
        #expect(lost.state == .unknown && lost.diagnosisJSON == nil)
    }

    /// contact.add goes through the desktop-mutation path (no throw reaches the executor): the diagnosis counts
    /// the irreversible points crossed — 1 after the chosen result's 添加, 2 after 发送 too.
    @Test func contactAddCountsBothIrreversiblePoints() throws {
        let (exec, handler, _) = try make(limiter: nil)
        let invite = CommandDiagnosis.Visual(goal: "contactSendVerification", phase: "commit", round: 1, outcome: "stop")
        handler.contactAddVisualEnd = (1, invite)
        let one = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wecom","idempotencyKey":"a1"}"#,
                                  idempotencyKey: "a1")
        #expect(one.state == .unknown && Self.diagnosis(one) == CommandDiagnosis(visual: invite, irreversibleSteps: 1))
        handler.contactAddVisualEnd = (2, invite)
        let two = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wecom","idempotencyKey":"a2"}"#,
                                  idempotencyKey: "a2")
        #expect(two.state == .unknown && Self.diagnosis(two) == CommandDiagnosis(visual: invite, irreversibleSteps: 2))
    }

    /// Review Focus 2: a broadcast child that ends visually after its checkpoint keeps its own diagnosis; the
    /// parent carries none, and the next command does not inherit the end.
    @Test func aBroadcastChildKeepsItsOwnDiagnosis() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let params = #"{"targets":["文件传输助手"],"text":"test","idempotencyKey":"bc","intervalMs":0}"#
        let parent = try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc")
        #expect(parent.state == .unknown && parent.diagnosisJSON == nil)
        let child = try #require(try store.command(idempotencyKey: "bc#0"))
        #expect(Self.diagnosis(child) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 1))
        handler.visualEndOnSend = nil
        let next = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k9"}"#, idempotencyKey: "k9")
        #expect(next.state == .unknown && next.diagnosisJSON == nil)
    }

    /// Review Focus 5: the same key after a visual end returns the original record and its diagnosis, not a re-run.
    @Test func aReplayAfterAVisualEndReturnsTheSameDiagnosis() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let first = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        handler.sendErrorAfterCheckpoint = nil
        handler.visualEndOnSend = nil
        let replay = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(replay.id == first.id && replay.diagnosisJSON == first.diagnosisJSON && first.diagnosisJSON != nil
                && handler.sendCalls == 1)
    }
}

import Foundation
import Testing
@testable import ControlCore

@Suite("Protocol types")
struct ProtocolTests {
    @Test func methodsRoundTripAndOnlySendNeedsKey() {
        #expect(RPCMethod(rawValue: "message.send") == .messageSend)
        #expect(RPCMethod.allCases.count == 42)
        #expect(RPCMethod.allCases.filter(\.requiresIdempotencyKey) == [.messageSend, .messageSendFile, .clientNavigate, .contactRequestAccept, .groupCreate, .groupRename, .groupAddMembers, .messageBroadcast, .contactAdd, .broadcastCreate, .broadcastConfirm])
    }

    @Test func terminalStates() {
        #expect(!CommandStateV1.accepted.isTerminal && !CommandStateV1.running.isTerminal)
        for s in [CommandStateV1.succeeded, .failed, .unknown, .cancelled, .expired] { #expect(s.isTerminal) }
    }

    @Test func errorCodesAreWireStrings() {
        #expect(ControlError.targetNotFound("x").code == "TARGET_NOT_FOUND")
        #expect(ControlError.paused([.api, .system]).message.contains("api,system"))
        #expect(PauseReason.localGuard.rawValue == "local_guard")
    }


    @Test func rateLimitedAndConversationTypeAreWireStrings() {
        #expect(ControlError.rateLimited("x").code == "RATE_LIMITED")
        #expect(ConversationType.internal.rawValue == "internal" && ConversationType.allCases.count == 4)
        #expect(ControlError.targetNotFound("chatId:x").message == "no conversation for target \"chatId:x\"")
    }


    @Test func wecomApiMethodsAreRoutedSeparately() {
        #expect(RPCMethod.allCases.count == 42)
        #expect(RPCMethod.allCases.filter(\.requiresIdempotencyKey) == [.messageSend, .messageSendFile, .clientNavigate, .contactRequestAccept, .groupCreate, .groupRename, .groupAddMembers, .messageBroadcast, .contactAdd, .broadcastCreate, .broadcastConfirm])
        #expect(RPCMethod.allCases.filter(\.isWeComAPI).count == 16)
        #expect(RPCMethod(rawValue: "group.joinway.create") == .groupJoinwayCreate && RPCMethod.broadcastConfirm.isWeComAPI)
        #expect(!RPCMethod.messageSend.isWeComAPI)
        #expect(ControlError.unsupported("x").code == "UNSUPPORTED" && ControlError.wecomAPI(errcode: 40014, errmsg: "invalid token").code == "WECOM_API")
        #expect(ControlError.wecomAPI(errcode: 40014, errmsg: "invalid token").message == "wecom errcode 40014: invalid token")
        #expect(ControlError.proxy("down").code == "PROXY_ERROR")
        #expect(!ActionKind.confirmBroadcast.requiresTarget)
    }

    @Test func clientNavigateIsAClientMethodWithThreeActions() throws {
        #expect(RPCMethod(rawValue: "client.navigate") == .clientNavigate && !RPCMethod.clientNavigate.isWeComAPI)
        #expect(NavigateAction.allCases.map(\.rawValue) == ["nextConversation", "previousConversation", "nextUnreadConversation"])
        let p = try JSONDecoder().decode(NavigateParams.self, from: Data(#"{"action":"nextUnreadConversation","idempotencyKey":"n1"}"#.utf8))
        #expect(p == NavigateParams(action: .nextUnreadConversation, idempotencyKey: "n1"))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NavigateParams.self, from: Data(#"{"action":"messagesView","idempotencyKey":"n1"}"#.utf8)) }
        #expect(!ActionKind.navigate.requiresTarget && ActionKind.allCases.count == 16 && ActionKind.renameGroup.requiresTarget)
    }

    @Test func contactsMethodsEventsAndPolicy() throws {
        #expect(RPCMethod(rawValue: "contact.request.accept") == .contactRequestAccept && !RPCMethod.contactList.isWeComAPI && !RPCMethod.groupCreate.isWeComAPI)
        #expect(ControlEventKind.allCases.count == 9 && ControlEventKind.groupCreated.rawValue == "group.created" && ControlEventKind.groupMembersAdded.rawValue == "group.membersAdded")
        #expect(ActionKind.allCases.count == 16 && !ActionKind.createGroup.requiresTarget && !ActionKind.openContacts.requiresTarget)
        let p = try JSONDecoder().decode(GroupCreateParams.self, from: Data(#"{"members":["测试联系人A"],"idempotencyKey":"g1"}"#.utf8))
        #expect(p.members == ["测试联系人A"] && p.name == nil)
        var policy = ContactRequestPolicy()
        #expect(policy.autoAccept == .off && policy.autoGroup == .off && policy.maxAcceptsPerHour == 20 && policy.groupNameSuffix == "群聊")
        #expect(policy.groupName(for: "测试联系人A") == "测试联系人A群聊")
        policy.autoAccept = .rules; policy.allowNames = ["测试联系人A"]; policy.greetingContains = ["示例公司"]
        #expect(policy.decides(name: "测试联系人A", greeting: "") && policy.decides(name: "x", greeting: "我来自示例公司") && !policy.decides(name: "x", greeting: "hi"))
        policy.autoAccept = .all; #expect(policy.decides(name: "anyone", greeting: nil))
        policy.autoAccept = .remote; #expect(!policy.decides(name: "测试联系人A", greeting: nil))
    }

    @Test func sendFileIsAClientMethodWithOneSourceAndItsOwnErrors() throws {
        #expect(RPCMethod(rawValue: "message.sendFile") == .messageSendFile && RPCMethod.messageSendFile.requiresIdempotencyKey && !RPCMethod.messageSendFile.isWeComAPI)
        let p = try JSONDecoder().decode(SendFileParams.self, from: Data(#"{"target":"文件传输助手","url":"https://h.example/a.pdf","idempotencyKey":"f1"}"#.utf8))
        #expect(p.url == "https://h.example/a.pdf" && p.ossKey == nil && p.fileName == nil)
        let r = SendFileResult(state: .succeeded, evidence: "row #2 kind=file", fileName: "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"kind\":\"file\"") && json.contains("\"bytes\":3"))
        for (e, code) in [(ControlError.sourceNotAllowed("x"), "SOURCE_NOT_ALLOWED"), (.sourceUnsupported("x"), "SOURCE_UNSUPPORTED"), (.sourceTooLarge("x"), "SOURCE_TOO_LARGE"),
                          (.sourceUnreachable("x"), "SOURCE_UNREACHABLE"), (.pasteFailed("x"), "PASTE_FAILED"), (.ossNotConfigured("x"), "OSS_NOT_CONFIGURED"),
                          (.mediaTooLarge("x"), "MEDIA_TOO_LARGE"), (.objectStore("x"), "OSS_ERROR")] {
            #expect(e.code == code && ControlError.allCodes.contains(code))
        }
        #expect(ActionKind.sendFile.requiresTarget && ActionKind.allCases.count == 16)
        #expect(throws: PolicyError.phaseForbids(.sendFile)) { try ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.sendFile], phase: .phase0).authorize(.sendFile, target: "文件传输助手") }
        let send = ControllerSend(commandId: "c", target: "t", text: "", tsMs: 1, kind: "file", fileName: "a.pdf")
        #expect(send.kind == "file" && ControllerSend(commandId: "c", target: "t", text: "hi", tsMs: 1).kind == "text")
        let ref = MediaReference(messageKey: "k", kind: "image", matchedBy: "observed", fileName: "p.png", bytes: 10, contentType: "image/png", ossKey: "imctl/2026/09/22/k-p.png", url: "https://b.example/x?sig", expiresAtMs: 5)
        #expect(String(decoding: try JSONEncoder().encode(ref), as: UTF8.self).contains("\"url\":"))
    }

    @Test func groupAddMembersIsAClientMethodWithItsOwnEventAndError() throws {
        #expect(RPCMethod(rawValue: "group.addMembers") == .groupAddMembers && RPCMethod.groupAddMembers.requiresIdempotencyKey && !RPCMethod.groupAddMembers.isWeComAPI)
        // dryRun absent from the wire JSON must still decode false, not throw.
        let p = try JSONDecoder().decode(GroupAddMembersParams.self, from: Data(#"{"target":"测试群","members":["李四","王五"],"idempotencyKey":"a1"}"#.utf8))
        #expect(p.target == "测试群" && p.members == ["李四", "王五"] && p.dryRun == false && p.ttlMs == nil && p.issuedAtMs == nil)
        let withDryRun = try JSONDecoder().decode(GroupAddMembersParams.self, from: Data(#"{"target":"测试群","members":["李四"],"dryRun":true,"idempotencyKey":"a2"}"#.utf8))
        #expect(withDryRun.dryRun == true)
        let r = GroupAddMembersResult(state: .succeeded, target: "测试群", before: 3, after: 4, added: ["王五"],
                                       skipped: [SkippedMember(name: "李四", reason: "alreadyMember")], dryRun: false, evidence: "count 3→4", latencyMs: 210)
        let decoded = try JSONDecoder().decode(GroupAddMembersResult.self, from: JSONEncoder().encode(r))
        #expect(decoded == r && decoded.skipped.first?.name == "李四" && decoded.skipped.first?.reason == "alreadyMember")
        #expect(ControlEventKind(rawValue: "group.membersAdded") == .groupMembersAdded)
        #expect(ControlError.notAGroup("测试群").code == "NOT_A_GROUP" && ControlError.allCodes.contains("NOT_A_GROUP"))
        #expect(ActionKind.addGroupMembers.requiresTarget && ActionKind.allCases.count == 16)
        #expect(throws: PolicyError.phaseForbids(.addGroupMembers)) {
            try ActionPolicy(allowedTargets: ["测试群"], enabled: [.addGroupMembers], phase: .phase0).authorize(.addGroupMembers, target: "测试群")
        }
    }
}

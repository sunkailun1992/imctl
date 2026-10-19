import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("broadcast.confirm AX probe on fake")
struct BroadcastConfirmTests {
    /// Main window plus a 群发助手 sheet with an exact API task identifier.
    static func windowWithAssistant(msgid: String? = "msg1", extraSend: Bool = false,
                                    duplicateTask: Bool = false) -> AXNode {
        var window = GroupFixture.window()
        var children = [
            AXNode(role: AXRole.staticText, value: .string("群发助手"), frame: CGRect(x: 620, y: 310, width: 100, height: 20)),
            AXNode(role: AXRole.staticText, value: .string("待发送 1 条"), frame: CGRect(x: 620, y: 340, width: 200, height: 20)),
        ]
        if let msgid {
            children.append(AXNode(role: AXRole.staticText, value: .string(msgid), frame: CGRect(x: 620, y: 370, width: 200, height: 20)))
        }
        children.append(AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 1200, y: 760, width: 80, height: 30), enabled: true, actions: [AXAction.press]))
        if extraSend {
            children.append(AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 1100, y: 760, width: 80, height: 30), enabled: true, actions: [AXAction.press]))
        }
        let sheet = AXNode(role: AXRole.sheet, frame: CGRect(x: 600, y: 300, width: 700, height: 500), children: children)
        window.children[0].children.append(sheet)
        if duplicateTask { window.children[0].children.append(sheet) }
        return window
    }

    @Test func pressesTheSendButtonAndVerifiesItWentAway() throws {
        let fake = FakeAXBackend(root: Self.windowWithAssistant())
        let reader = try WeComReader(window: fake.rootElement)
        let button = try #require(fake.handle(atPath: [0, 3, 3]))
        fake.reactions["action:AXPress"] = { fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false)) }
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        actions.verifyTimeout = 0.2
        actions.verifyInterval = 0.02
        let out = try actions.confirmBroadcast(reader: reader, msgid: "msg1")
        #expect(out.verified && out.details["button"] == "发送" && out.details["msgid"] == "msg1")
        #expect(fake.recordedActions.map(\.action) == [AXAction.press] && fake.recordedSets.isEmpty)
    }

    @Test func missingAssistantIsUnsupportedAndPolicyGated() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        #expect(throws: ActionError.actionUnavailable("群发助手 msgid 未核对")) { try actions.confirmBroadcast(reader: reader, msgid: nil) }
        #expect(throws: PolicyError.notEnabled(.confirmBroadcast)) {
            try WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"])).confirmBroadcast(reader: reader, msgid: nil)
        }
        #expect(fake.recordedActions.isEmpty)
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-bc-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement },
                                    policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast], phase: .phase1), checkpoints: cps)
        #expect(throws: ControlError.unsupported("action 群发助手 msgid 对应的唯一发送按钮 unavailable")) { try h.confirmBroadcast(msgid: "m") }
    }

    @Test func genericAssistantOrMultipleButtonsNeverSends() throws {
        for root in [Self.windowWithAssistant(msgid: nil), Self.windowWithAssistant(extraSend: true),
                     Self.windowWithAssistant(duplicateTask: true)] {
            let fake = FakeAXBackend(root: root)
            let reader = try WeComReader(window: fake.rootElement)
            let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
            #expect(throws: ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")) {
                try actions.confirmBroadcast(reader: reader, msgid: "msg1")
            }
            #expect(fake.recordedActions.isEmpty)
        }
    }

    @Test func taskDriftAfterCheckpointCannotPressAnotherButton() throws {
        let fake = FakeAXBackend(root: Self.windowWithAssistant())
        let reader = try WeComReader(window: fake.rootElement)
        let button = try #require(fake.handle(atPath: [0, 3, 3]))
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        var checkpoints = 0
        #expect(throws: ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")) {
            try actions.confirmBroadcast(reader: reader, msgid: "msg1", hooks: SubmitHooks(beforeIrreversible: {
                checkpoints += 1
                fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false))
            }))
        }
        #expect(checkpoints == 1)
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func sameTaskInTwoWeComWindowsIsAmbiguousBeforeCheckpoint() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [
            Self.windowWithAssistant(), Self.windowWithAssistant()
        ]))
        let main = try #require(fake.element(atPath: [0]))
        let reader = try WeComReader(window: main)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        var checkpoints = 0
        #expect(throws: ActionError.actionUnavailable("群发助手 msgid 对应的唯一发送按钮")) {
            try actions.confirmBroadcast(reader: reader, msgid: "msg1",
                                         hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
    }

    @Test func failedGlobalWindowEnumerationCannotAssumeUniqueTask() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [
            Self.windowWithAssistant()
        ]))
        let main = try #require(fake.element(atPath: [0]))
        let reader = try WeComReader(window: main)
        fake.injectedFailures["get:\(AXAttribute.windows)"] = .attributeUnsupported(AXAttribute.windows)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                    enabled: [.confirmBroadcast]))
        var checkpoints = 0
        #expect(throws: AXKitError.self) {
            try actions.confirmBroadcast(reader: reader, msgid: "msg1",
                hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
    }
}

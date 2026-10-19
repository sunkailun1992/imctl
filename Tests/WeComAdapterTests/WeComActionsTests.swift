import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("WeComActions on fake")
struct WeComActionsTests {
    func policy(_ enabled: Set<ActionKind>) -> ActionPolicy {
        ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: enabled)
    }

    @Test func selectSetsSelectedRowsAndVerifiesActiveTitle() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let out = try WeComActions(policy: policy([.selectConversation])).selectConversation("文件传输助手", reader: reader)
        #expect(out.verified)
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].attribute == AXAttribute.selectedRows)
        #expect(fake.recordedSets[0].value.elementsValue?.count == 1)
    }

    /// B10: reads are open by default (an unknown title fails as not found, after the allowlist would have
    /// refused it before); with `gateReads` the allowlist still answers before any AX write.
    @Test func selectRefusesTargetsOutsideAllowlistBeforeTouchingAX() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        #expect(throws: ActionError.targetNotFound("«b8e3a1b8»")) {
            try WeComActions(policy: policy([.selectConversation])).selectConversation("«b8e3a1b8»", reader: reader)
        }
        var gated = policy([.selectConversation]); gated.sendPolicy.gateReads = true
        #expect(throws: PolicyError.targetNotAllowed("«b8e3a1b8»")) {
            try WeComActions(policy: gated).selectConversation("«b8e3a1b8»", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func selectReportsMissingTarget() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let p = ActionPolicy(allowedTargets: ["文件传输助手", "nobody"], enabled: [.selectConversation])
        #expect(throws: ActionError.targetNotFound("nobody")) { try WeComActions(policy: p).selectConversation("nobody", reader: reader) }
    }

    @Test func composeThenClearRoundTrip() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: policy([.composeText, .clearComposer]))
        let composed = try actions.composeText("imctl-probe", reader: reader)
        #expect(composed.verified && composed.target == "文件传输助手")
        #expect(try reader.composerValue() == "imctl-probe")
        #expect(throws: ActionError.localGuard("composer not empty")) { try actions.composeText("again", reader: reader) }
        let cleared = try actions.clearComposer(reader: reader)
        #expect(cleared.verified)
        #expect(try reader.composerValue() == "")
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.value, AXAttribute.value])
    }

    @Test func composeRefusesWhenActiveConversationNotAllowlisted() throws {
        let fake = try Fixtures.mainWindow()
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("someone"))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(throws: PolicyError.targetNotAllowed("someone")) {
            try WeComActions(policy: policy([.composeText])).composeText("x", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }
}

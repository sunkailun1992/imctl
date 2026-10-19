import Testing
import ControlCore
@testable import AXKit
@testable import WeComAdapter
@testable import imctl

/// Pure formatting tests for the `addmembers` probe's row line — no AX backend, no live client:
/// `PickerContact` values are built by hand with a throwaway fake element for `row` (the field the
/// formatter never reads). Names used here are the repo's synthetic set (李四 / 王五 / 甲公司), not
/// real contacts.
@Suite("probe addmembers row formatting")
struct ProbeAddMembersTests {
    static func contact(_ name: String, section: String, source: String = "wecom", disabled: Bool = false) -> PickerContact {
        let row = FakeAXBackend(root: AXNode()).rootElement
        return PickerContact(name: name, tag: nil, source: source, section: section, row: row, disabled: disabled)
    }

    @Test func redactedRowsCarryNoNameOrSectionText() {
        let rows = [
            Self.contact("李四", section: "我的客户"),
            Self.contact("王五", section: "甲公司", source: "wechat", disabled: true),
        ]
        let lines = ProbeAddMembersCommand.formatRows(rows, noRedact: false)
        #expect(lines == [
            "#1 len=2 section=4c source=wecom disabled=false",
            "#2 len=2 section=3c source=wechat disabled=true",
        ])
        for line in lines {
            #expect(!line.contains("李四"))
            #expect(!line.contains("王五"))
            #expect(!line.contains("我的客户"))
            #expect(!line.contains("甲公司"))
        }
    }

    @Test func noRedactRowsIncludeTheRealNameAndSection() {
        let rows = [Self.contact("李四", section: "我的客户", disabled: false)]
        let lines = ProbeAddMembersCommand.formatRows(rows, noRedact: true)
        #expect(lines == ["#1 name=李四 section=我的客户 source=wecom disabled=false"])
    }

    @Test func emptyRowsProduceNoLines() {
        #expect(ProbeAddMembersCommand.formatRows([], noRedact: false).isEmpty)
        #expect(ProbeAddMembersCommand.formatRows([], noRedact: true).isEmpty)
    }

    @Test func indexIsOneBasedAndFollowsInputOrder() {
        let rows = [Self.contact("李四", section: "甲公司"), Self.contact("王五", section: "甲公司")]
        let lines = ProbeAddMembersCommand.formatRows(rows, noRedact: false)
        #expect(lines[0].hasPrefix("#1 "))
        #expect(lines[1].hasPrefix("#2 "))
    }
}

/// Task 7 fix: `ProbeAddMembersCommand.gate` is the standalone `.addGroupMembers` authorize call
/// `run()` makes before it ever touches the client (`selectConversation`, then
/// `openAddMembersSheet`'s real header-button presses) — pure, so allowed vs refused is covered
/// here with an in-memory `ActionPolicy` instead of a live sheet. No real names: targets below are
/// the repo's synthetic fixture titles / placeholders, never a real contact or group.
@Suite("probe addmembers policy gate")
struct ProbeAddMembersGateTests {
    @Test func gateAllowsACompiledInOrPolicyJSONTarget() throws {
        let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .addGroupMembers], phase: .phase1)
        try ProbeAddMembersCommand.gate(policy: policy, target: "文件传输助手")   // must not throw
    }

    @Test func gateRefusesATargetOffTheAllowlist() throws {
        let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .addGroupMembers], phase: .phase1)
        #expect(throws: PolicyError.targetNotAllowed("张三")) {
            try ProbeAddMembersCommand.gate(policy: policy, target: "张三")
        }
    }

    @Test func gateRefusesWhenAddGroupMembersIsNotEnabled() throws {
        let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation], phase: .phase1)
        #expect(throws: PolicyError.notEnabled(.addGroupMembers)) {
            try ProbeAddMembersCommand.gate(policy: policy, target: "文件传输助手")
        }
    }

    @Test func gateRefusesInPhase0RegardlessOfAllowlist() throws {
        let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .addGroupMembers], phase: .phase0)
        #expect(throws: PolicyError.phaseForbids(.addGroupMembers)) {
            try ProbeAddMembersCommand.gate(policy: policy, target: "文件传输助手")
        }
    }

    @Test func gateAllowsAnAllowAllTargetEvenOffTheCompiledList() throws {
        var sendPolicy = SendPolicy(); sendPolicy.allowAll = true
        let policy = ActionPolicy(allowedTargets: [], enabled: [.selectConversation, .addGroupMembers], phase: .phase1, sendPolicy: sendPolicy)
        try ProbeAddMembersCommand.gate(policy: policy, target: "随便什么标题")   // must not throw
    }
}

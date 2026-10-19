import Testing
@testable import ControlCore

@Suite("ActionPolicy")
struct ActionPolicyTests {
    let allow: Set<String> = ["文件传输助手"]

    @Test func deniesEverythingByDefault() {
        let p = ActionPolicy(allowedTargets: allow)
        #expect(throws: PolicyError.notEnabled(.selectConversation)) { try p.authorize(.selectConversation, target: "文件传输助手") }
        #expect(throws: PolicyError.notEnabled(.composeText)) { try p.authorize(.composeText, target: "文件传输助手") }
    }

    /// B10 (user 2026-09-16): opening a conversation is not restricted by default; `gateReads` restores the gate.
    @Test func enabledStillRequiresAllowlistedTarget() {
        let open = ActionPolicy(allowedTargets: allow, enabled: [.selectConversation])
        #expect(throws: Never.self) { try open.authorize(.selectConversation, target: "张三") }
        let p = ActionPolicy(allowedTargets: allow, enabled: [.selectConversation], sendPolicy: SendPolicy(gateReads: true))
        #expect(throws: PolicyError.targetNotAllowed("张三")) { try p.authorize(.selectConversation, target: "张三") }
        #expect(throws: PolicyError.targetRequired(.selectConversation)) { try p.authorize(.selectConversation, target: nil) }
        #expect(throws: Never.self) { try p.authorize(.selectConversation, target: "文件传输助手") }
    }

    @Test func submitIsForbiddenInPhase0EvenWhenEnabled() {
        let p = ActionPolicy(allowedTargets: allow, enabled: [.submit])
        #expect(throws: PolicyError.phaseForbids(.submit)) { try p.authorize(.submit, target: "文件传输助手") }
    }

    @Test func scrollHistoryNeedsAllowlistedActiveConversation() {
        let p = ActionPolicy(allowedTargets: allow, enabled: [.scrollHistory], sendPolicy: SendPolicy(gateReads: true))
        #expect(throws: PolicyError.targetNotAllowed("张三")) { try p.authorize(.scrollHistory, target: "张三") }
        #expect(throws: Never.self) { try ActionPolicy(allowedTargets: allow, enabled: [.scrollHistory]).authorize(.scrollHistory, target: "张三") }
        #expect(throws: PolicyError.targetRequired(.scrollHistory)) { try p.authorize(.scrollHistory, target: "") }
        #expect(throws: Never.self) { try p.authorize(.scrollHistory, target: "文件传输助手") }
        #expect(throws: PolicyError.notEnabled(.scrollHistory)) { try ActionPolicy(allowedTargets: allow).authorize(.scrollHistory, target: "文件传输助手") }
    }

    /// Open reads never widen what the other side can see: composing, submitting and renaming still need the allowlist.
    @Test func writesStillNeedTheAllowlistWhenReadsAreOpen() {
        let p = ActionPolicy(allowedTargets: allow, enabled: [.composeText, .submit, .renameGroup, .showComposerMenu, .selectConversation], phase: .phase1)
        for kind in [ActionKind.composeText, .submit, .renameGroup, .showComposerMenu] {
            #expect(throws: PolicyError.targetNotAllowed("张三")) { try p.authorize(kind, target: "张三") }
        }
        #expect(throws: PolicyError.targetRequired(.selectConversation)) { try p.authorize(.selectConversation, target: "") }
        #expect(ActionKind.allCases.filter(\.isReadOnly) == [.selectConversation, .scrollHistory])
    }

    @Test func clearComposerNeedsNoTargetButNeedsEnable() {
        #expect(throws: PolicyError.notEnabled(.clearComposer)) { try ActionPolicy(allowedTargets: allow).authorize(.clearComposer, target: nil) }
        #expect(throws: Never.self) { try ActionPolicy(allowedTargets: allow, enabled: [.clearComposer]).authorize(.clearComposer, target: nil) }
    }


    @Test func resolvedTargetsAreAllowedByTitleTypeOrId() {
        var file = SendPolicy()
        file.allow(.type(.group)); file.allow(.chatId("wr1")); file.allow(.externalUserId("wm1")); file.allow(.title("小明"))
        let p = ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1, sendPolicy: file)
        #expect(p.effectiveTitles == ["文件传输助手", "小明"])
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "任意群", type: .group)) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "x", chatId: "wr1")) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "y", externalUserId: "wm1")) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "小明")) }
        #expect(throws: PolicyError.targetNotAllowed("客户A")) { try p.authorize(.submit, resolved: ResolvedTarget(title: "客户A", type: .customer)) }
        #expect(throws: PolicyError.targetNotAllowed("z")) { try p.authorize(.submit, resolved: ResolvedTarget(title: "z", type: .unknown, chatId: "wr2")) }
        #expect(throws: PolicyError.targetRequired(.submit)) { try p.authorize(.submit, resolved: nil) }
        // the compiled allowlist alone still works exactly as before
        #expect(throws: PolicyError.targetNotAllowed("任意群")) { try ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1).authorize(.submit, target: "任意群") }
    }

    /// B14 (user 2026-09-22 「全部放开」): the only path that allows a resolved target of type
    /// `unknown`. Phase, enable and gateReads still gate independently — allowAll only widens
    /// what `allows()` itself accepts.
    @Test func allowAllBypassesTheTargetAllowlistOnlyWhenOnAndOnlyWidensTargetMatching() {
        let unknownTarget = ResolvedTarget(title: "随便什么群", type: .unknown)

        let off = ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1)
        #expect(!off.allows(unknownTarget))
        #expect(throws: PolicyError.targetNotAllowed("随便什么群")) { try off.authorize(.submit, resolved: unknownTarget) }

        let on = ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1, sendPolicy: SendPolicy(allowAll: true))
        #expect(on.allows(unknownTarget))
        #expect(throws: Never.self) { try on.authorize(.submit, resolved: unknownTarget) }

        // phase 0 still forbids submit even with allowAll on
        let phase0 = ActionPolicy(allowedTargets: allow, enabled: [.submit], sendPolicy: SendPolicy(allowAll: true))
        #expect(throws: PolicyError.phaseForbids(.submit)) { try phase0.authorize(.submit, resolved: unknownTarget) }

        // not enabled is still refused even with allowAll on
        let notEnabled = ActionPolicy(allowedTargets: allow, phase: .phase1, sendPolicy: SendPolicy(allowAll: true))
        #expect(throws: PolicyError.notEnabled(.submit)) { try notEnabled.authorize(.submit, resolved: unknownTarget) }

        // gateReads keeps gating read-only kinds on its own; allowAll only changes what allows() accepts once reached
        var gated = SendPolicy(allowAll: true); gated.gateReads = true
        let gatedOpen = ActionPolicy(allowedTargets: allow, enabled: [.selectConversation], sendPolicy: gated)
        #expect(throws: Never.self) { try gatedOpen.authorize(.selectConversation, target: "随便什么群") }
        let gatedClosed = ActionPolicy(allowedTargets: allow, enabled: [.selectConversation], sendPolicy: SendPolicy(gateReads: true))
        #expect(throws: PolicyError.targetNotAllowed("随便什么群")) { try gatedClosed.authorize(.selectConversation, target: "随便什么群") }
    }
}

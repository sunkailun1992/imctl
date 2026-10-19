import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

/// B24 uses the existing synthetic group/sheet, never a real WeCom window.
/// Only opening the empty add-members sheet is in the reversible visual loop;
/// every invocation below ends in dry-run cancellation before 确定.
@Suite("group add-members header visual rounds")
struct AIPlannerAddMembersHeaderIntegrationTests {
    private static func fixture(withSheet: Bool = false, preSelected: Int = 0,
                                opens: [AddGroupMembersTests.Opens] = [.addMembers],
                                cancelIsIneffective: Bool = false) throws
        -> (WeComCommandHandler, AddGroupMembersTests.Harness) {
        let actions = AddGroupMembersTests()
        let box = try actions.harness(withSheet: withSheet, preSelected: preSelected,
                                      opensOnPress: opens,
                                      cancelIsIneffective: cancelIsIneffective)
        let handler = WeComCommandHandler(rootProvider: { box.window },
                                          policy: box.actions.policy,
                                          checkpoints: box.checkpoints)
        handler.desktopCommandMethod = .groupAddMembers
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("B24 header path must not use the one-step selector")
            return nil
        }
        handler.configureActions = { action in
            action.verifyTimeout = 0.05
            action.verifyInterval = 0.005
            action.addMembersTimeout = 0.05
            action.groupOpenTimeout = 0.1
            action.frontmostPid = box.actions.frontmostPid
            action.restoreFrontmost = box.actions.restoreFrontmost
            action.postShortcut = box.actions.postShortcut
            action.postReturnKey = box.actions.postReturnKey
        }
        return (handler, box)
    }

    private static func shot(frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    private static func installRunner(_ handler: WeComCommandHandler,
                                      capture: @escaping () -> Void,
                                      decide: @escaping (AIPlannerObservation, AIPlannerStepContext) -> AIPlannerStepDecision) {
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in capture(); return Self.shot(frame: frame) },
                decide: { observation, context, _ in decide(observation, context) })
        }
    }

    private static func choose(_ observation: AIPlannerObservation, context: AIPlannerStepContext,
                               highestX: Bool) -> AIPlannerStepDecision {
        if context.phase == .verify {
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        let ordered = observation.candidates.sorted { $0.frame.minX < $1.frame.minX }
        return AIPlannerStepDecision(step: .press,
                                     candidateID: highestX ? ordered.last?.id : ordered.first?.id)
    }

    private static func dryRun(_ handler: WeComCommandHandler) throws -> GroupAddMembersResult {
        try handler.groupAddMembers(target: GroupFixture.groupTitle, members: ["王五"], dryRun: true,
                                    checkpoint: { Issue.record("dry-run reached checkpoint") },
                                    afterSubmit: { Issue.record("dry-run reached afterSubmit") })
    }

    @Test func ambiguousButtonsUseSelectionAndFreshSheetVerificationRounds() throws {
        let (handler, box) = try Self.fixture()
        var captures = 0, decisions = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            decisions += 1
            #expect(context.method == .groupAddMembers)
            #expect(context.allowedSteps == (context.phase == .verify
                ? [.verify, .reobserve, .stop] : [.press, .reobserve, .verify, .stop]))
            if case .control(.addGroupMembers) = context.goal {} else { Issue.record("wrong goal") }
            #expect(observation.candidates.count == (context.phase == .verify ? 1 : 2))
            return Self.choose(observation, context: context, highestX: true)
        })
        let out = try Self.dryRun(handler)
        #expect(out.evidence == "dry-run")
        #expect(captures == 2 && decisions == 2)
        #expect(box.journal.events == ["header", "cancel"])
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func firstPressWithoutSheetGetsFreshSecondRound() throws {
        let (handler, box) = try Self.fixture()
        let key = "action:\(AXAction.press)"
        let original = try #require(box.fake.reactions[key])
        var headerPresses = 0, captures = 0
        box.fake.reactions[key] = {
            if box.fake.recordedActions.last?.handle == box.fake.recordedActions.first?.handle {
                headerPresses += 1
                if headerPresses == 1 { return }
            }
            original()
        }
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            Self.choose(observation, context: context, highestX: true)
        })
        let out = try Self.dryRun(handler)
        #expect(out.evidence == "dry-run" && headerPresses == 2 && captures == 3)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func wrongSheetStopsWithoutCancellingOrPressingAgain() throws {
        let (handler, box) = try Self.fixture(opens: [.anotherSheet, .addMembers])
        var rounds = 0
        Self.installRunner(handler, capture: {}, decide: { observation, context in
            rounds += 1
            return Self.choose(observation, context: context, highestX: rounds == 1)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(rounds == 1)
        #expect(box.journal.events == ["header"])
        #expect(try GroupPickerSheet.locate(window: box.window) != nil)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func wrongSheetThatWillNotCloseStopsBeforeSecondPress() throws {
        let (handler, box) = try Self.fixture(opens: [.anotherSheet, .addMembers],
                                               cancelIsIneffective: true)
        Self.installRunner(handler, capture: {}, decide: { observation, context in
            Self.choose(observation, context: context, highestX: true)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(box.journal.events == ["header"])
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func preselectedSheetAfterPressIsLeftIntact() throws {
        let (handler, box) = try Self.fixture()
        let key = "action:\(AXAction.press)"
        let original = try #require(box.fake.reactions[key])
        box.fake.reactions[key] = {
            original()
            guard box.journal.events.last == "header",
                  let sheet = try? GroupPickerSheet.locate(window: box.window),
                  let selected = sheet.selectedTable else { return }
            box.fake.appendChild(to: selected.handle,
                                 node: AXNode(role: AXRole.row,
                                              frame: CGRect(x: 961, y: 388, width: 319, height: 36)))
        }
        Self.installRunner(handler, capture: {}, decide: { observation, context in
            Self.choose(observation, context: context, highestX: true)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(box.journal.events == ["header"])
        #expect(try GroupPickerSheet.locate(window: box.window)?.selectedCount() == 1)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func exactHelpAlsoRequiresModelChoiceAndFreshSheetVerification() throws {
        let (handler, box) = try Self.fixture()
        let named = try #require(WeComActions.headerButtons(layout: box.reader.layout).first)
        box.fake.mutate(named.handle, attribute: AXAttribute.help, to: .string("添加群成员"))
        var captures = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            #expect(observation.candidates.count == 1)
            return Self.choose(observation, context: context, highestX: true)
        })
        let out = try Self.dryRun(handler)
        #expect(out.evidence == "dry-run" && captures == 2)
        #expect(box.journal.events == ["header", "cancel"])
    }

    @Test func exactAXHelpIsExplainedToModelButUnlabelledIconIsNot() throws {
        let (_, box) = try Self.fixture()
        let button = try #require(WeComActions.headerButtons(layout: box.reader.layout).first)
        let context = try AIPlannerStepContext(
            method: .groupAddMembers, allowedSteps: [.press, .reobserve, .verify, .stop],
            phase: .locate, lastEvidence: .targetVisible,
            goal: .control(.addGroupMembers))
        func prompt() throws -> String {
            let observation = try AIPlannerObservation.capture(
                window: box.window, expectedPID: box.fake.pid,
                allowedKinds: [.press], eligibleHandles: [button.handle],
                capture: { _, frame in Self.shot(frame: frame) })
            var received = ""
            let client = AIPlannerStepClient { request in
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let messages = try #require(body["messages"] as? [[String: Any]])
                let parts = try #require(messages.first?["content"] as? [[String: Any]])
                received = try #require(parts.first?["text"] as? String)
                let reply = try JSONSerialization.data(withJSONObject: [
                    "choices": [["finish_reason": "stop", "message": ["content": "{\"step\":\"stop\"}"]]]
                ])
                let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: "HTTP/1.1", headerFields: nil))
                return (reply, response)
            }
            #expect(try client.decide(observation: observation, context: context,
                                      settings: AIPlannerVisionClientTests.settings()).step == .stop)
            return received
        }
        let unnamedPrompt = try prompt()
        #expect(!unnamedPrompt.contains("exact Add Group Members AX help/value"))
        box.fake.mutate(button.handle, attribute: AXAttribute.help, to: .string("添加群成员"))
        let namedPrompt = try prompt()
        #expect(namedPrompt.contains("exact Add Group Members AX help/value"))
        #expect(namedPrompt.contains("choose press with candidate_id C0"))
    }

    @Test func exactHelpModelStopCannotPressTheOtherwiseUniqueButton() throws {
        let (handler, box) = try Self.fixture()
        let named = try #require(WeComActions.headerButtons(layout: box.reader.layout).first)
        box.fake.mutate(named.handle, attribute: AXAttribute.help, to: .string("添加群成员"))
        var captures = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            #expect(context.phase == .locate && observation.candidates.count == 1)
            return AIPlannerStepDecision(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(captures == 1 && box.fake.recordedActions.isEmpty)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func alreadyOpenPickerFailsBeforeCaptureWithoutCancellingUserState() throws {
        for preSelected in [0, 1] {
            let (handler, box) = try Self.fixture(withSheet: true, preSelected: preSelected)
            var captures = 0
            Self.installRunner(handler, capture: { captures += 1 }, decide: { _, _ in
                Issue.record("preexisting picker reached the model")
                return AIPlannerStepDecision(step: .stop, candidateID: nil)
            })
            #expect(throws: ControlError.self) { try Self.dryRun(handler) }
            #expect(captures == 0 && box.fake.recordedActions.isEmpty)
            #expect(box.checkpoints.written.isEmpty)
            #expect(try GroupPickerSheet.locate(window: box.window) != nil)
        }
    }

    @Test func noSafeHeaderCandidateStopsBeforeCaptureAndPress() throws {
        let (handler, box) = try Self.fixture()
        for button in try WeComActions.headerButtons(layout: box.reader.layout) {
            box.fake.mutate(button.handle, attribute: AXAttribute.help, to: .string("确定并发送"))
        }
        var captures = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { _, _ in
            Issue.record("unsafe candidate reached the model")
            return AIPlannerStepDecision(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(captures == 0 && box.fake.recordedActions.isEmpty)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func secondRoundCannotPressOrProceedWhenModelStops() throws {
        let (handler, box) = try Self.fixture()
        var captures = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            if context.phase == .verify {
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                return AIPlannerStepDecision(step: .stop, candidateID: nil)
            }
            return Self.choose(observation, context: context, highestX: true)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(captures == 2 && box.journal.events == ["header", "cancel"])
        #expect(try GroupPickerSheet.locate(window: box.window) == nil)
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func replacingOpenedSheetDuringModelVerificationCannotContinue() throws {
        let (handler, box) = try Self.fixture()
        Self.installRunner(handler, capture: {}, decide: { observation, context in
            if context.phase == .verify {
                if let opened = try? GroupPickerSheet.locate(window: box.window),
                   let replacement = try? AddGroupMembersTests.sheetNode(.addMembers) {
                    box.fake.mutate(opened.sheet.handle, attribute: AXAttribute.role,
                                    to: .string(AXRole.group))
                    _ = box.fake.appendChild(to: box.window.handle, node: replacement)
                } else {
                    Issue.record("test fixture did not expose the opened sheet")
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            return Self.choose(observation, context: context, highestX: true)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(box.journal.events == ["header"] && box.checkpoints.written.isEmpty)
    }

    @Test func nonexistentSyntheticMemberDryRunUsesTwoRoundsAndNeverConfirms() throws {
        let (handler, box) = try Self.fixture()
        var captures = 0
        Self.installRunner(handler, capture: { captures += 1 }, decide: { observation, context in
            Self.choose(observation, context: context, highestX: true)
        })
        let out = try handler.groupAddMembers(target: GroupFixture.groupTitle,
                                              members: ["不存在的合成测试成员"], dryRun: true,
                                              checkpoint: { Issue.record("dry-run reached checkpoint") },
                                              afterSubmit: { Issue.record("dry-run reached afterSubmit") })
        #expect(out.evidence == "nothing-to-add" && out.skipped.map(\.reason) == ["notFound"])
        #expect(captures == 2 && box.journal.events == ["header", "cancel"])
        #expect(box.checkpoints.written.isEmpty)
    }

    @Test func correctSheetCanHideTheGroupCountAfterPress() throws {
        let (handler, box) = try Self.fixture()
        let count = try #require(box.countHandle)
        let key = "action:\(AXAction.press)"
        let original = try #require(box.fake.reactions[key])
        box.fake.reactions[key] = {
            original()
            if box.journal.events.last == "header" {
                box.fake.mutate(count, attribute: AXAttribute.value, to: nil)
            }
        }
        Self.installRunner(handler, capture: {}, decide: { observation, context in
            Self.choose(observation, context: context, highestX: true)
        })
        let out = try Self.dryRun(handler)
        #expect(out.evidence == "dry-run")
        #expect(box.journal.events == ["header", "cancel"])
    }

    @Test func policyAndPauseRevocationsPreventHeaderPress() throws {
        for revoke in 0..<2 {
            let (handler, box) = try Self.fixture()
            var paused = false
            handler.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
            Self.installRunner(handler, capture: {}, decide: { observation, context in
                if revoke == 0 { handler.policy.enabled.remove(.addGroupMembers) }
                else { paused = true }
                return Self.choose(observation, context: context, highestX: true)
            })
            #expect(throws: ControlError.self) { try Self.dryRun(handler) }
            #expect(box.fake.recordedActions.isEmpty && box.checkpoints.written.isEmpty)
        }
    }

    @Test func livePolicyAndPauseAreRecheckedAfterMemberSelection() throws {
        for revoke in 0..<2 {
            let (handler, box) = try Self.fixture()
            var paused = false
            handler.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
            let configure = handler.configureActions
            handler.configureActions = { action in
                configure(&action)
                action.postReturnKey = { pid, control in
                    try box.actions.postReturnKey(pid, control)
                    if revoke == 0 { handler.policy.enabled.remove(.addGroupMembers) }
                    else { paused = true }
                }
            }
            Self.installRunner(handler, capture: {}, decide: { observation, context in
                Self.choose(observation, context: context, highestX: true)
            })
            #expect(throws: ControlError.self) { try Self.dryRun(handler) }
            #expect(box.journal.returns == 1)
            #expect(box.journal.events == ["header"])
            #expect(box.checkpoints.written.isEmpty)
        }
    }

    @Test func checkpointHookPolicyOrPauseRevocationReturnsWithoutConfirm() throws {
        for revoke in 0..<2 {
            let (handler, box) = try Self.fixture()
            var paused = false
            handler.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
            Self.installRunner(handler, capture: {}, decide: { observation, context in
                Self.choose(observation, context: context, highestX: true)
            })
            #expect(throws: ControlError.self) {
                try handler.groupAddMembers(target: GroupFixture.groupTitle, members: ["王五"], dryRun: false,
                                            checkpoint: {
                                                if revoke == 0 { handler.policy.enabled.remove(.addGroupMembers) }
                                                else { paused = true }
                                            }, afterSubmit: { Issue.record("confirm crossed after gate revocation") })
            }
            #expect(box.checkpoints.written.first?.state == .pending)
            #expect(!box.journal.events.contains("confirm"))
        }
    }

    @Test func methodPermissionAndWindowDriftPreventHeaderPress() throws {
        for drift in 0..<3 {
            let (handler, box) = try Self.fixture()
            var enabled = true
            handler.visualEnabled = { enabled }
            let frame = try #require(try box.window.frame())
            Self.installRunner(handler, capture: {}, decide: { observation, context in
                switch drift {
                case 0: handler.desktopCommandMethod = .groupRename
                case 1: enabled = false
                default: box.fake.mutate(box.window.handle, attribute: AXAttribute.frame,
                                         to: .rect(frame.offsetBy(dx: 20, dy: 0)))
                }
                return Self.choose(observation, context: context, highestX: true)
            })
            #expect(throws: ControlError.self) { try Self.dryRun(handler) }
            #expect(box.fake.recordedActions.isEmpty && box.checkpoints.written.isEmpty)
        }
    }

    @Test func groupCountAndCandidateDriftPreventHeaderPress() throws {
        for drift in 0..<2 {
            let (handler, box) = try Self.fixture()
            let count = try #require(box.countHandle)
            Self.installRunner(handler, capture: {}, decide: { observation, context in
                let decision = Self.choose(observation, context: context, highestX: true)
                if drift == 0 {
                    box.fake.mutate(count, attribute: AXAttribute.value, to: .string("群成员·4"))
                } else if let candidate = observation.candidates.first(where: { $0.id == decision.candidateID }) {
                    box.fake.mutate(candidate.element.handle, attribute: AXAttribute.frame,
                                    to: .rect(candidate.frame.offsetBy(dx: 20, dy: 0)))
                }
                return decision
            })
            #expect(throws: ControlError.self) { try Self.dryRun(handler) }
            #expect(box.fake.recordedActions.isEmpty && box.checkpoints.written.isEmpty)
        }
    }

    @Test func confirmationAndSendControlsAreNeverCandidates() throws {
        let (handler, box) = try Self.fixture()
        let first = try #require(WeComActions.headerButtons(layout: box.reader.layout).first)
        box.fake.mutate(first.handle, attribute: AXAttribute.help, to: .string("确定并发送"))
        var offered = 0
        Self.installRunner(handler, capture: {}, decide: { observation, _ in
            offered = observation.candidates.count
            #expect(observation.candidates.allSatisfy { $0.element.handle != first.handle })
            return AIPlannerStepDecision(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try Self.dryRun(handler) }
        #expect(offered == 1 && box.fake.recordedActions.isEmpty)
    }

    @Test func genericRunnerStillRejectsPressBeforeScreenshot() throws {
        let (_, box) = try Self.fixture()
        let button = try #require(WeComActions.headerButtons(layout: box.reader.layout).first)
        var captures = 0
        let runner = AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
            beforeRound: {}, settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
            decide: { _, _, _ in AIPlannerStepDecision(step: .press, candidateID: "C0") })
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try runner.run(method: .groupAddMembers, gate: {}, observe: {
                AIPlannerReversibleRound(window: box.window, goal: .control(.addGroupMembers),
                                         action: .press, eligible: [button],
                                         expectedTitle: GroupFixture.groupTitle,
                                         phase: .locate, evidence: .targetVisible)
            }, apply: { _, _ in Issue.record("generic runner pressed a button") },
            verify: { false })
        }
        #expect(captures == 0 && box.fake.recordedActions.isEmpty)
    }
}

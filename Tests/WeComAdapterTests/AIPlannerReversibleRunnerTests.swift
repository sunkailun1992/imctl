import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("AI planner reversible command rounds")
struct AIPlannerReversibleRunnerTests {
    private enum GateError: Error { case denied }

    @Test func sixtySecondCeilingIsRestrictedToReadNavigation() throws {
        let (_, window, table, _) = try Self.fixture()
        let runner = AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2,
                                              maxDuration: 60, beforeRound: {})
        func run(_ method: RPCMethod, using runner: AIPlannerReversibleRunner) throws -> AIPlannerReversibleOutcome {
            try runner.run(method: method, gate: {},
                           observe: { try Self.round(window: window, table: table) },
                           apply: { _, _ in Issue.record("satisfied AX postcondition must not mutate") },
                           verify: { true })
        }
        #expect(try run(.messageHistory, using: runner) == .verified)
        #expect(try run(.contactRequestList, using: runner) == .verified)
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try run(.contactRequestAccept, using: runner)
        }
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try run(.messageSend, using: runner)
        }
        let overLimit = AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2,
                                                  maxDuration: 60.01, beforeRound: {})
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try run(.messageHistory, using: overLimit)
        }
    }

    @Test func readNavigationStillStopsAtItsCommandWideDeadline() throws {
        let (_, window, table, _) = try Self.fixture()
        var clock: TimeInterval = 0
        let runner = AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2,
                                              maxDuration: 60, beforeRound: {},
                                              now: { clock })
        #expect(throws: AIPlannerVisionError.timeout) {
            try runner.run(method: .messageHistory,
                           gate: { clock = 60 },
                           observe: { try Self.round(window: window, table: table) },
                           apply: { _, _ in Issue.record("deadline must prevent AX action") },
                           verify: { true })
        }
    }

    @Test func slowAXReadNavigationCanCompleteItsSecondVisualRoundBeforeSixtySeconds() throws {
        let (fake, window, table, status) = try Self.fixture()
        var clock: TimeInterval = 0
        var captures = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
            clock = 27 // The first model and AX action outlived the former 24 s local cap.
        }
        let runner = AIPlannerReversibleRunner(
            maxRounds: 4, maxActions: 2, maxDuration: 60, beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                if context.phase == .verify {
                    clock = 35
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            },
            now: { clock })
        let outcome = try runner.run(method: .messageHistory,
                                     requireVisualPostcondition: true,
                                     gate: {}, observe: { try Self.round(window: window, table: table) },
                                     apply: { _, row in
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                     }, verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified)
        #expect(captures == 2 && fake.recordedSets.count == 1 && clock == 35)
    }

    private static func fixture() throws -> (FakeAXBackend, AXElement, AXElement, AXElement) {
        let (fake, window) = AIPlannerObservationTests.fixture()
        let table = try #require(fake.element(atPath: [0]))
        let statusHandle = try #require(fake.appendChild(
            to: fake.rootHandle,
            node: AXNode(role: AXRole.staticText, value: .string("尚未打开"),
                         frame: CGRect(x: 135, y: 80, width: 90, height: 20))
        ))
        return (fake, window, table, AXElement(handle: statusHandle, backend: fake))
    }

    private static func round(window: AXElement, table: AXElement) throws -> AIPlannerReversibleRound {
        let row = try #require(try table.children().first)
        return AIPlannerReversibleRound(window: window, goal: .conversationRow(title: "测试会话"),
                                        action: .selectRow, eligible: [row], expectedTitle: nil,
                                        phase: .locate, evidence: .targetVisible)
    }

    private static func capture() -> AIPlannerObservation.Capture {
        { _, _ in AIPlannerObservationTests.shot() }
    }

    @Test func groupCreatePassiveRoundsRequireTwoFreshCapturesAndNeverAct() throws {
        let (fake, window, table, _) = try Self.fixture()
        let row = try #require(try table.children().first)
        let buttonHandle = try #require(fake.appendChild(to: fake.rootHandle,
            node: AXNode(role: AXRole.button, title: "完成",
                         frame: CGRect(x: 145, y: 100, width: 70, height: 30), enabled: true,
                         actions: [AXAction.press])))
        let button = AXElement(handle: buttonHandle, backend: fake)
        let settings = try AIPlannerVisionClientTests.settings()
        var captures = 0, decisions = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {}, settingsProvider: { settings },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                decisions += 1
                #expect(context.method == .groupCreate)
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
        let before = try runner.observeGroupCreation(
            phase: .prepare, gate: {}, observe: {
                AIPlannerReversibleRound(window: window, goal: .control(.confirm),
                    action: .press, eligible: [button], expectedTitle: nil,
                    phase: .prepare, evidence: .pendingConfirmation)
            }, verify: { true })
        let after = try runner.observeGroupCreation(
            phase: .verify, expectedSettings: before.settings,
            gate: {}, observe: {
                AIPlannerReversibleRound(window: window, goal: .conversationRow(title: "合成新群"),
                    action: .selectRow, eligible: [row], expectedTitle: nil,
                    phase: .verify, evidence: .postconditionPresent)
            }, verify: { true })
        #expect(before.outcome == .verified && after.outcome == .verified)
        #expect(captures == 2 && decisions == 2)
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func groupCreateModelCannotPressDoneOrSupplySuccess() throws {
        let (fake, window, _, _) = try Self.fixture()
        let buttonHandle = try #require(fake.appendChild(to: fake.rootHandle,
            node: AXNode(role: AXRole.button, title: "完成",
                         frame: CGRect(x: 145, y: 100, width: 70, height: 30), enabled: true,
                         actions: [AXAction.press])))
        let button = AXElement(handle: buttonHandle, backend: fake)
        let runner = AIPlannerReversibleRunner(
            beforeRound: {}, settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in AIPlannerStepDecision(step: .press, candidateID: "C0") })
        #expect(throws: AIPlannerVisionError.invalidChoice) {
            try runner.observeGroupCreation(phase: .prepare, gate: {}, observe: {
                AIPlannerReversibleRound(window: window, goal: .control(.confirm),
                    action: .press, eligible: [button], expectedTitle: nil,
                    phase: .prepare, evidence: .pendingConfirmation)
            }, verify: { true })
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func reobservesAndUsesCallerAXPostcondition() throws {
        let (fake, window, table, status) = try Self.fixture()
        var modelRounds = 0
        var screenshots = 0
        var gates = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        }
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in screenshots += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                modelRounds += 1
                #expect(context.method == .conversationRead)
                #expect(context.allowedSteps == [.selectRow, .reobserve, .verify, .stop])
                return modelRounds == 1
                    ? AIPlannerStepDecision(step: .reobserve, candidateID: nil)
                    : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            }
        )
        let outcome = try runner.run(method: .conversationRead,
                                     gate: { gates += 1 },
                                     observe: { try Self.round(window: window, table: table) },
                                     apply: { step, row in
                                         #expect(step == .selectRow)
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                     },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified)
        #expect(modelRounds == 2 && screenshots == 2 && gates >= 3)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func visualPostconditionRequiresFreshReadOnlyModelRoundAfterAction() throws {
        let (fake, window, table, status) = try Self.fixture()
        var screenshots = 0, modelRounds = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        }
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in screenshots += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                modelRounds += 1
                if modelRounds == 1 {
                    #expect(context.phase == .locate)
                    return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                }
                #expect(context.phase == .verify)
                #expect(context.lastEvidence == .postconditionPresent)
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
        )
        let outcome = try runner.run(method: .conversationRead, requireVisualPostcondition: true,
                                     gate: {}, observe: { try Self.round(window: window, table: table) },
                                     apply: { _, row in
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                     },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified)
        #expect(screenshots == 2 && modelRounds == 2)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func alreadyPresentAXPostconditionStillRequiresModelVerification() throws {
        let (fake, window, table, status) = try Self.fixture()
        fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        var screenshots = 0, decisions = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in screenshots += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                decisions += 1
                #expect(context.phase == .verify)
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
        )
        let outcome = try runner.run(method: .conversationRead, requireVisualPostcondition: true,
                                     gate: {}, observe: { try Self.round(window: window, table: table) },
                                     apply: { _, _ in Issue.record("verification must not mutate the client") },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified && screenshots == 1 && decisions == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func visualVerificationMayReobserveButNeverRepeatsAXAction() throws {
        let (fake, window, table, status) = try Self.fixture()
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        }
        var screenshots = 0, decisions = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in screenshots += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                decisions += 1
                if decisions == 1 { return AIPlannerStepDecision(step: .selectRow, candidateID: "C0") }
                #expect(context.phase == .verify)
                return AIPlannerStepDecision(step: decisions == 2 ? .reobserve : .verify,
                                             candidateID: nil)
            }
        )
        let outcome = try runner.run(method: .conversationRead, requireVisualPostcondition: true,
                                     gate: {}, observe: { try Self.round(window: window, table: table) },
                                     apply: { _, row in
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                     },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified && screenshots == 3 && decisions == 3)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func visualPostconditionStopsOrLosesAXProofWithoutSecondAction() throws {
        for losesProof in [false, true] {
            let (fake, window, table, status) = try Self.fixture()
            fake.reactions["set:\(AXAttribute.selectedRows)"] = {
                fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
            }
            var decisions = 0
            let runner = AIPlannerReversibleRunner(
                beforeRound: {},
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: Self.capture(),
                decide: { _, context, _ in
                    decisions += 1
                    if decisions == 1 { return AIPlannerStepDecision(step: .selectRow, candidateID: "C0") }
                    #expect(context.phase == .verify)
                    if losesProof {
                        fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("尚未打开"))
                        return AIPlannerStepDecision(step: .verify, candidateID: nil)
                    }
                    return AIPlannerStepDecision(step: .stop, candidateID: nil)
                }
            )
            let outcome = try runner.run(method: .conversationRead, requireVisualPostcondition: true,
                                         gate: {}, observe: { try Self.round(window: window, table: table) },
                                         apply: { _, row in
                                             try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                         },
                                         verify: { try status.valueString() == "测试会话" })
            #expect(outcome == (losesProof ? .unverified : .stopped))
            #expect(decisions == 2 && fake.recordedSets.count == 1)
        }
    }

    @Test func revokedGateDuringVisualVerificationCannotDeclareSuccess() throws {
        let (fake, window, table, status) = try Self.fixture()
        fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        var allowed = true, screenshots = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in screenshots += 1; return Self.capture()(pid, frame) },
            decide: { _, context, _ in
                #expect(context.phase == .verify)
                allowed = false
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
        )
        do {
            _ = try runner.run(method: .conversationRead, requireVisualPostcondition: true,
                               gate: { if !allowed { throw GateError.denied } },
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("verification must not mutate the client") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("revoked gate accepted model verification")
        } catch GateError.denied {}
        #expect(screenshots == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func newEligibleRowAfterMissIsObservedAfreshBeforeSecondAction() throws {
        let (fake, window, table, status) = try Self.fixture()
        var selected: [AXElementHandle] = []
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in AIPlannerStepDecision(step: .selectRow, candidateID: "C0") }
        )
        let outcome = try runner.run(method: .conversationRead, gate: {},
                                     observe: { try Self.round(window: window, table: table) },
                                     apply: { _, row in
                                         selected.append(row.handle)
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                         if selected.count == 1 {
                                             fake.replaceChildren(of: table.handle, with: [
                                                 AXNode(role: AXRole.row, title: "测试会话",
                                                        frame: CGRect(x: 60, y: 50, width: 65, height: 24))
                                             ])
                                         } else {
                                             fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
                                         }
                                     },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified)
        #expect(selected.count == 2 && selected[0] != selected[1])
        #expect(fake.recordedSets.count == 2)
    }

    @Test func modelVerifyDoesNotDeclareSuccessWithoutAXProof() throws {
        let (fake, window, table, status) = try Self.fixture()
        var modelRounds = 0
        let runner = AIPlannerReversibleRunner(
            maxRounds: 2,
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                modelRounds += 1
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("verify must not perform an action") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Model's verify answer was treated as completion")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(modelRounds == 2)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func staleCandidateStopsBeforeAXWrite() throws {
        let (fake, window, table, status) = try Self.fixture()
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                let row = try #require(try table.children().first)
                fake.mutate(row.handle, attribute: AXAttribute.title, to: .string("其他会话"))
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("stale candidate was acted on") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Stale candidate was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .staleView) }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func changedGateAfterInferencePreventsAXWrite() throws {
        let (fake, window, table, status) = try Self.fixture()
        var allowed = true
        var captures = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, _, _ in
                allowed = false
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            }
        )
        do {
            _ = try runner.run(method: .conversationRead,
                               gate: { if !allowed { throw GateError.denied } },
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("revoked action was performed") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Revoked gate was ignored")
        } catch GateError.denied {}
        #expect(captures == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func gateDenialOrAlreadyVerifiedNeverCaptures() throws {
        let (fake, window, table, status) = try Self.fixture()
        var captures = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, _, _ in Issue.record("no inference expected"); return AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: { throw GateError.denied },
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("denied action was performed") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Gate denial was ignored")
        } catch GateError.denied {}
        fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        let outcome = try runner.run(method: .conversationRead, gate: {},
                                     observe: { try Self.round(window: window, table: table) },
                                     apply: { _, _ in Issue.record("already complete action was performed") },
                                     verify: { try status.valueString() == "测试会话" })
        #expect(outcome == .verified && captures == 0)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func fullWindowGateRejectsBeforeScreenshotOrAXWrite() throws {
        let (fake, window, table, status) = try Self.fixture()
        var settings = CloudVisionSettings()
        try settings.setAPIKey("unit-test-key", for: .qwen)
        try settings.enable()
        var captured = false
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { settings },
            capture: { _, _ in captured = true; return Self.capture()(4242, AIPlannerObservationTests.windowFrame) },
            decide: { _, _, _ in Issue.record("disabled model was called"); return AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("disabled action was performed") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Legacy cloud switch permitted full-window capture")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        #expect(!captured && fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func totalTimeExceededDuringInferenceStopsBeforeAXWrite() throws {
        let (fake, window, table, status) = try Self.fixture()
        var clock = 0.0
        let runner = AIPlannerReversibleRunner(
            maxDuration: 40,
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                clock = 41
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            },
            now: { clock }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("expired action was performed") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("Expired command acted on a model response")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func gateRevokedDuringAXObservationPreventsScreenshot() throws {
        let (fake, window, table, status) = try Self.fixture()
        var allowed = true, captures = 0, charged = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: { charged += 1 },
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, _, _ in Issue.record("revoked command reached model"); return AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        do {
            _ = try runner.run(method: .conversationRead,
                               gate: { if !allowed { throw GateError.denied } },
                               observe: {
                                   allowed = false
                                   return try Self.round(window: window, table: table)
                               },
                               apply: { _, _ in Issue.record("revoked command wrote AX") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("revoked command was accepted")
        } catch GateError.denied {}
        #expect(captures == 0 && charged == 0)
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func timeSpentInAXObservationPreventsScreenshot() throws {
        let (fake, window, table, status) = try Self.fixture()
        var clock = 0.0, captures = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, _, _ in Issue.record("expired command reached model"); return AIPlannerStepDecision(step: .stop, candidateID: nil) },
            now: { clock }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: {
                                   clock = 41
                                   return try Self.round(window: window, table: table)
                               },
                               apply: { _, _ in Issue.record("expired command wrote AX") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("expired observation was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(captures == 0 && fake.recordedSets.isEmpty)
    }

    @Test func fullWindowRevocationDuringInferencePreventsAXWrite() throws {
        let (fake, window, table, status) = try Self.fixture()
        var settings = try AIPlannerVisionClientTests.settings()
        var captures = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { settings },
            capture: { pid, frame in captures += 1; return Self.capture()(pid, frame) },
            decide: { _, _, _ in
                try settings.setFullWindowEnabled(false)
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("revoked full-window grant wrote AX") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("revoked full-window grant was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .disabled) }
        #expect(captures == 1 && fake.recordedSets.isEmpty)
    }

    @Test func timeSpentCapturingPreventsCloudRequest() throws {
        let (fake, window, table, status) = try Self.fixture()
        var clock = 0.0, captures = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { pid, frame in
                captures += 1
                clock = 41
                return Self.capture()(pid, frame)
            },
            decide: { _, _, _ in Issue.record("expired screenshot was uploaded"); return AIPlannerStepDecision(step: .stop, candidateID: nil) },
            now: { clock }
        )
        do {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in Issue.record("expired capture wrote AX") },
                               verify: { try status.valueString() == "测试会话" })
            Issue.record("expired capture was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .timeout) }
        #expect(captures == 1 && fake.recordedSets.isEmpty)
    }

    @Test func delayedAXHeaderSettlesWithoutSecondUpload() throws {
        let (fake, window, table, status) = try Self.fixture()
        var selected = false, pollsAfterSelection = 0, modelRounds = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                modelRounds += 1
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            }
        )
        let outcome = try runner.run(method: .conversationRead, gate: {},
                                     observe: { try Self.round(window: window, table: table) },
                                     apply: { _, row in
                                         selected = true
                                         try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                                     },
                                     verify: {
                                         if selected {
                                             pollsAfterSelection += 1
                                             if pollsAfterSelection == 3 {
                                                 fake.mutate(status.handle, attribute: AXAttribute.value,
                                                             to: .string("测试会话"))
                                             }
                                         }
                                         return try status.valueString() == "测试会话"
                                     })
        #expect(outcome == .verified && modelRounds == 1)
        #expect(pollsAfterSelection == 3 && fake.recordedSets.count == 1)
    }

    /// Review Focus 1 / B54: every model request is reported once, numbered, with the goal's kind only —
    /// the conversation title never reaches a record or its log line.
    @Test func everyModelRequestIsReportedWithoutTitles() throws {
        let (fake, window, table, status) = try Self.fixture()
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        }
        var calls = 0
        var records: [AIPlannerRoundRecord] = []
        var runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                calls += 1
                return calls == 1 ? AIPlannerStepDecision(step: .reobserve, candidateID: nil)
                                  : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        runner.roundSink = { records.append($0) }
        _ = try runner.run(method: .conversationRead, gate: {},
                           observe: { try Self.round(window: window, table: table) },
                           apply: { _, row in try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle])) },
                           verify: { try status.valueString() == "测试会话" })
        #expect(records.map(\.round) == [1, 2] && records.map(\.outcome) == ["reobserve", "selectRow"])
        #expect(records.allSatisfy { $0.goal == "conversationRow" && $0.phase == .locate && $0.method == .conversationRead && $0.latencyMs >= 0 })
        #expect(records.allSatisfy { !$0.line.contains("测试会话") })
        #expect(records[0].line == "vision round conversation.read conversationRow/locate #1 → reobserve (\(records[0].latencyMs) ms)")
    }

    /// A failed model request is reported by its fixed error name and still thrown.
    @Test func aFailedModelRequestIsReportedByItsErrorName() throws {
        let (_, window, table, status) = try Self.fixture()
        var records: [AIPlannerRoundRecord] = []
        var runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in throw AIPlannerVisionError.timeout })
        runner.roundSink = { records.append($0) }
        #expect(throws: AIPlannerVisionError.timeout) {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in }, verify: { try status.valueString() == "测试会话" })
        }
        #expect(records.map(\.outcome) == ["timeout"] && records.first?.round == 1)
    }

    @Test func fixedNamesForGoalsErrorsAndOutcomes() {
        #expect(AIPlannerGoal.conversationRow(title: "13800000000").logName == "conversationRow")
        #expect(AIPlannerGoal.groupMember(name: "张三").logName == "groupMember")
        #expect(AIPlannerGoal.control(.contactMatch).logName == "contactMatch")
        #expect(AIPlannerVisionError.staleView.logName == "staleView")
        #expect(AIPlannerReversibleOutcome.stopped.logName == "stop")
        #expect(AIPlannerReversibleOutcome.unverified.logName == "unverified")
        let record = AIPlannerRoundRecord(method: .contactAdd, goal: "contactMatch", phase: .verify, round: 2, outcome: "stop", latencyMs: 9)
        #expect(record.ended("stop") == CommandDiagnosis.Visual(goal: "contactMatch", phase: "verify", round: 2, outcome: "stop"))
    }
}

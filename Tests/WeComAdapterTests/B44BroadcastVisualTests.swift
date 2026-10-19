import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B44 passive broadcast confirmation visual checks")
struct B44BroadcastVisualTests {
    private static func handler(_ fake: FakeAXBackend, visual: Bool = true) throws -> WeComCommandHandler {
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b44-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.confirmBroadcast], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .broadcastConfirm
        handler.visualEnabled = { visual }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("a broadcast task must already be globally unique by AX")
            return nil
        }
        handler.configureActions = { action in
            action.verifyTimeout = 0.03
            action.verifyInterval = 0.005
        }
        return handler
    }

    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    private static func model(_ handler: WeComCommandHandler,
                              capture: @escaping (CGRect) -> Void = { _ in },
                              decide: @escaping (AIPlannerStepContext) -> AIPlannerStepDecision) throws {
        let settings = try AIPlannerVisionClientTests.settings()
        handler.visualSettingsForCommit = { settings }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { settings },
                capture: { _, frame in capture(frame); return Self.shot(frame) },
                decide: { _, context, _ in decide(context) })
        }
    }

    @Test func onePassiveRoundBeforeOneFixedPressUsesAXProof() throws {
        let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
        let button = try #require(fake.handle(atPath: [0, 3, 3]))
        let handler = try Self.handler(fake)
        var captures = 0, checkpoints = 0, after = 0
        try Self.model(handler, capture: { _ in captures += 1 }, decide: { context in
            #expect(context.method == .broadcastConfirm)
            #expect(context.phase == .commit)
            #expect(context.allowedSteps == [.verify, .reobserve, .stop])
            #expect(context.goal.description?.contains("Broadcast Assistant") == true)
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        fake.reactions["action:AXPress"] = {
            fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false))
        }
        let result = try handler.confirmBroadcast(msgid: "msg1",
            checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["verified"] == "true" && result["msgid"] == "msg1")
        #expect(captures == 1 && checkpoints == 1 && after == 1)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func reobserveUsesNewFrameAndStillPressesOnce() throws {
        let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
        let button = try #require(fake.handle(atPath: [0, 3, 3]))
        let handler = try Self.handler(fake)
        var captures = 0, rounds = 0
        try Self.model(handler, capture: { _ in captures += 1 }, decide: { _ in
            rounds += 1
            return AIPlannerStepDecision(step: rounds == 1 ? .reobserve : .verify, candidateID: nil)
        })
        fake.reactions["action:AXPress"] = {
            fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false))
        }
        #expect(try handler.confirmBroadcast(msgid: "msg1")["verified"] == "true")
        #expect(captures == 2 && rounds == 2 && fake.recordedActions.count == 1)
    }

    @Test func modelStopOrActionChoiceStopsBeforeCheckpoint() throws {
        for decision in [AIPlannerStepDecision(step: .stop, candidateID: nil),
                         AIPlannerStepDecision(step: .press, candidateID: "C0"),
                         AIPlannerStepDecision(step: .verify, candidateID: "C0")] {
            let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
            let handler = try Self.handler(fake)
            var checkpoints = 0
            try Self.model(handler, decide: { _ in decision })
            #expect(throws: ControlError.self) {
                try handler.confirmBroadcast(msgid: "msg1", checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
        }
    }

    @Test func staleWindowOrPolicyFailsBeforeCheckpoint() throws {
        for drift in ["window", "policy", "permission"] {
            let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
            let handler = try Self.handler(fake)
            var checkpoints = 0, granted = true
            handler.visualScreenRecordingGranted = { granted }
            try Self.model(handler, decide: { _ in
                switch drift {
                case "window":
                    fake.mutate(fake.rootHandle, attribute: AXAttribute.frame,
                                to: .rect(CGRect(x: 8, y: 0, width: 1920, height: 1200)))
                case "policy": handler.policy.enabled.remove(.confirmBroadcast)
                default: granted = false
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
            #expect(throws: ControlError.self) {
                try handler.confirmBroadcast(msgid: "msg1", checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
        }
    }

    @Test func ambiguousTaskAndAXOnlyPathDoNotCapture() throws {
        for ambiguous in [false, true] {
            let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant(extraSend: ambiguous))
            let handler = try Self.handler(fake, visual: ambiguous)
            var captures = 0
            try Self.model(handler, capture: { _ in captures += 1 }, decide: { _ in
                AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
            if ambiguous {
                #expect(throws: ControlError.self) { try handler.confirmBroadcast(msgid: "msg1") }
                #expect(fake.recordedActions.isEmpty)
            } else {
                let button = try #require(fake.handle(atPath: [0, 3, 3]))
                fake.reactions["action:AXPress"] = {
                    fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false))
                }
                #expect(try handler.confirmBroadcast(msgid: "msg1")["verified"] == "true")
            }
            #expect(captures == 0)
        }
    }

    @Test func policyChangeAfterCheckpointNeverReachesAXPress() throws {
        let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
        let handler = try Self.handler(fake)
        try Self.model(handler, decide: { _ in
            AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        var checkpoints = 0
        #expect(throws: ControlError.self) {
            try handler.confirmBroadcast(msgid: "msg1", checkpoint: {
                checkpoints += 1
                handler.policy.enabled.remove(.confirmBroadcast)
            }, afterSubmit: {})
        }
        #expect(checkpoints == 1 && fake.recordedActions.isEmpty)
    }

    @Test func unchangedButtonGetsSecondObservationButNeverVisualSuccess() throws {
        let fake = FakeAXBackend(root: BroadcastConfirmTests.windowWithAssistant())
        let handler = try Self.handler(fake)
        var phases: [AIPlannerPhase] = [], captures = 0
        try Self.model(handler, capture: { _ in captures += 1 }, decide: { context in
            phases.append(context.phase)
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        let result = try handler.confirmBroadcast(msgid: "msg1")
        #expect(result["verified"] == "false")
        #expect(phases == [.commit, .verify] && captures == 2)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }
}

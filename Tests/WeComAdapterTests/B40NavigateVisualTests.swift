import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B40 passive visual checks around fixed client navigation")
struct B40NavigateVisualTests {
    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    private static func harness(enabled: Bool = true) throws ->
        (WeComCommandHandler, FakeAXBackend, String, () -> Void) {
        let fake = try NavigateFixture.app()
        if enabled { NavigateFixture.enableItemsWhenFrontmost(fake) }
        let observed = try WeComReader(window: WeComWindowLocator.mainWindow(from: fake.rootElement))
        let rows = try observed.conversations()
        guard let index = rows.firstIndex(where: { $0.selected }), index + 1 < rows.count else {
            throw AIPlannerVisionError.staleView
        }
        let current = rows[index]
        let next = rows[index + 1]
        let nextTitle = try #require(next.title)
        let header = try #require(observed.layout.activeTitle)
        let move = {
            fake.mutate(current.handle, attribute: AXAttribute.selected, to: .bool(false))
            fake.mutate(next.handle, attribute: AXAttribute.selected, to: .bool(true))
            fake.mutate(header.handle, attribute: AXAttribute.value, to: .string(nextTitle))
        }
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b40-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.navigate], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .clientNavigate
        handler.configureActions = { actions in
            actions.verifyTimeout = 0.03
            actions.verifyInterval = 0.005
            actions.frontmostPid = { nil }
        }
        return (handler, fake, nextTitle, move)
    }

    private static func enableVision(_ handler: WeComCommandHandler,
                                     capture: @escaping (CGRect) -> Void = { _ in },
                                     decide: @escaping (AIPlannerStepContext) -> AIPlannerStepDecision = {
                                         _ in AIPlannerStepDecision(step: .verify, candidateID: nil)
                                     }) throws -> CloudVisionSettings {
        let settings = try AIPlannerVisionClientTests.settings()
        handler.visualEnabled = { true }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSettingsForCommit = { settings }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("navigation must not invoke the actionable AX selector")
            return nil
        }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { settings },
                capture: { _, frame in capture(frame); return Self.shot(frame) },
                decide: { _, context, _ in decide(context) })
        }
        return settings
    }

    @Test func changedSelectionGetsTwoPassiveRoundsAndOneFixedMenuPress() throws {
        let (handler, fake, nextTitle, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        var captures = 0, phases: [AIPlannerPhase] = []
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 }, decide: { context in
            phases.append(context.phase)
            #expect(context.method == .clientNavigate)
            #expect(context.allowedSteps == [.verify, .reobserve, .stop])
            #expect(context.goal.description != nil)
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        let out = try handler.clientNavigate(action: .nextConversation)
        #expect(out["changed"] == "true" && out["after"] == nextTitle)
        #expect(captures == 2 && phases == [.prepare, .verify])
        #expect(fake.recordedActions.count == 1)
        #expect(fake.recordedActions[0].handle == fake.handle(atPath: NavigateFixture.nextItemPath))
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.frontmost])
    }

    @Test func frontmostSelectionChangeUsesFreshVisualAnchorAndBeforeTitle() throws {
        let (handler, fake, _, _) = try Self.harness()
        let observed = try WeComReader(window: WeComWindowLocator.mainWindow(from: fake.rootElement))
        let rows = try observed.conversations()
        let selected = try #require(rows.firstIndex(where: { $0.selected }))
        #expect(selected + 2 < rows.count)
        let activated = rows[selected + 1]
        let destination = rows[selected + 2]
        let activatedTitle = try #require(activated.title)
        let destinationTitle = try #require(destination.title)
        let header = try #require(observed.layout.activeTitle)
        fake.reactions["set:\(AXAttribute.frontmost)"] = {
            for index in 0..<4 {
                if let item = fake.handle(atPath: [1, 1, 0, index]) {
                    fake.mutate(item, attribute: AXAttribute.enabled, to: .bool(true))
                }
            }
            fake.mutate(rows[selected].handle, attribute: AXAttribute.selected, to: .bool(false))
            fake.mutate(activated.handle, attribute: AXAttribute.selected, to: .bool(true))
            fake.mutate(header.handle, attribute: AXAttribute.value, to: .string(activatedTitle))
        }
        fake.reactions["action:AXPress"] = {
            fake.mutate(activated.handle, attribute: AXAttribute.selected, to: .bool(false))
            fake.mutate(destination.handle, attribute: AXAttribute.selected, to: .bool(true))
            fake.mutate(header.handle, attribute: AXAttribute.value, to: .string(destinationTitle))
        }
        var captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 })
        let out = try handler.clientNavigate(action: .nextConversation)
        #expect(out["before"] == activatedTitle && out["after"] == destinationTitle)
        #expect(out["changed"] == "true" && captures == 2)
        #expect(fake.recordedActions.count == 1)
    }

    @Test func disjointMenuBarWindowKeepsUniqueMainWindowProof() throws {
        let fake = try NavigateFixture.app()
        let main = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let currentFrame = try main.frame()
        let frame = try #require(currentFrame)
        let accessory = AXNode(role: AXRole.window,
                               frame: CGRect(x: frame.minX + 12, y: frame.minY - 24,
                                             width: 66, height: 20))
        fake.appendChild(to: fake.rootHandle, node: accessory)
        #expect(try fake.rootElement.elements(AXAttribute.windows).count == 2)
        try WeComCommandHandler.verifyNavigationWindowSet(app: fake.rootElement,
                                                            window: main, pid: fake.pid,
                                                            frame: frame)
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func overlappingOrFocusedAuxiliaryWindowStopsBeforeCapture() throws {
        let fake = try NavigateFixture.app()
        let main = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let currentFrame = try main.frame()
        let frame = try #require(currentFrame)
        let overlap = AXNode(role: AXRole.window,
                             frame: CGRect(x: frame.midX, y: frame.midY,
                                           width: 66, height: 20))
        let other = try #require(fake.appendChild(to: fake.rootHandle, node: overlap))
        #expect(throws: AIPlannerVisionError.staleView) {
            try WeComCommandHandler.verifyNavigationWindowSet(app: fake.rootElement,
                                                                window: main, pid: fake.pid,
                                                                frame: frame)
        }
        fake.mutate(other, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: frame.minX + 12, y: frame.minY - 24,
                                     width: 66, height: 20)))
        fake.mutate(fake.rootHandle, attribute: AXAttribute.focusedWindow,
                    to: .element(other))
        #expect(throws: AIPlannerVisionError.staleView) {
            try WeComCommandHandler.verifyNavigationWindowSet(app: fake.rootElement,
                                                                window: main, pid: fake.pid,
                                                                frame: frame)
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func disabledMenuKeepsFastAXPathWithNoCapture() throws {
        let (handler, fake, _, _) = try Self.harness(enabled: false)
        var captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 })
        let out = try handler.clientNavigate(action: .nextConversation)
        #expect(out["changed"] == "false" && out["enabled"] == "false")
        #expect(captures == 0 && fake.recordedActions.isEmpty)
    }

    @Test func firstModelStopPreventsMenuPress() throws {
        let (handler, fake, _, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        var captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 }, decide: { _ in
            AIPlannerStepDecision(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try handler.clientNavigate(action: .nextConversation) }
        #expect(captures == 1 && fake.recordedActions.isEmpty)
    }

    @Test func permissionRevocationAfterFirstModelRoundPreventsMenuPress() throws {
        let (handler, fake, _, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        var granted = true, captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 }, decide: { _ in
            granted = false
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        handler.visualScreenRecordingGranted = { granted }
        #expect(throws: ControlError.self) { try handler.clientNavigate(action: .nextConversation) }
        #expect(captures == 1 && fake.recordedActions.isEmpty)
    }

    @Test func changedSelectionWithSecondModelStopCannotReportSuccess() throws {
        let (handler, fake, nextTitle, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        var captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 }, decide: { context in
            AIPlannerStepDecision(step: context.phase == .prepare ? .verify : .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try handler.clientNavigate(action: .nextConversation) }
        #expect(captures == 2 && fake.recordedActions.count == 1)
        #expect(try WeComReader(window: WeComWindowLocator.mainWindow(from: fake.rootElement))
            .activeConversationTitle() == nextTitle)
    }

    @Test func noChangeAfterPreflightNeverFakesChangedOrRepeatsMenu() throws {
        let (handler, fake, _, _) = try Self.harness()
        var captures = 0
        _ = try Self.enableVision(handler, capture: { _ in captures += 1 })
        let out = try handler.clientNavigate(action: .nextConversation)
        #expect(out["changed"] == "false")
        // The outcome cannot be predicted perfectly before AXPress. A race
        // may consume the pre-frame; the post-frame is skipped on no change.
        #expect(captures == 1 && fake.recordedActions.count == 1)
    }

    @Test func disabledFullWindowSettingLeavesDeterministicMenuPath() throws {
        let (handler, fake, nextTitle, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        handler.visualEnabled = { false }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("visual selector must be disabled")
            return nil
        }
        let out = try handler.clientNavigate(action: .nextConversation)
        #expect(out["changed"] == "true" && out["after"] == nextTitle)
        #expect(fake.recordedActions.count == 1)
    }

    @Test func policyPauseSettingsModalFrameAndBudgetChangesStopBeforeMenuPress() throws {
        enum Interruption: CaseIterable { case policy, pause, settings, modal, frame, budget }
        for interruption in Interruption.allCases {
            let (handler, fake, _, move) = try Self.harness()
            fake.reactions["action:AXPress"] = move
            let settings = try Self.enableVision(handler, decide: { _ in
                switch interruption {
                case .policy:
                    handler.policy = ActionPolicy(allowedTargets: ["文件传输助手"], phase: .phase1)
                case .pause:
                    break
                case .settings:
                    break
                case .modal:
                    if let window = fake.handle(atPath: [0]) {
                        fake.appendChild(to: window, node: AXNode(role: AXRole.sheet))
                    }
                case .frame:
                    if let window = fake.handle(atPath: [0]) {
                        fake.mutate(window, attribute: AXAttribute.frame,
                                    to: .rect(CGRect(x: 0, y: 0, width: 1000, height: 700)))
                    }
                case .budget:
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
            if interruption == .pause {
                var paused = false
                handler.visualCommandGate = {
                    if paused { throw ControlError.paused([.api]) }
                }
                handler.reversibleRunnerFactory = {
                    AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                        settingsProvider: { settings },
                        capture: { _, frame in Self.shot(frame) },
                        decide: { _, _, _ in
                            paused = true
                            return AIPlannerStepDecision(step: .verify, candidateID: nil)
                        })
                }
            }
            if interruption == .settings {
                var changed = settings
                changed.disable()
                handler.visualSettingsForCommit = { changed }
            }
            if interruption == .budget { handler.maxVisualDuration = 0.01 }
            #expect(throws: ControlError.self) { try handler.clientNavigate(action: .nextConversation) }
            #expect(fake.recordedActions.isEmpty)
        }
    }

    @Test func modelCannotChooseAnAXRowOrTheWindowMenu() throws {
        let (handler, fake, _, move) = try Self.harness()
        fake.reactions["action:AXPress"] = move
        _ = try Self.enableVision(handler, decide: { _ in
            AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
        })
        #expect(throws: ControlError.self) { try handler.clientNavigate(action: .nextConversation) }
        #expect(fake.recordedActions.isEmpty)
    }
}

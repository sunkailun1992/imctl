import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B41 passive contact acceptance visual checks")
struct B41ContactAcceptVisualTests {
    private static func fixture() throws -> (FakeAXBackend, NewCustomerCard) {
        let fake = try ContactsFixture.newCustomers()
        let outline = try #require(try WeComContactsView.exactNewCustomersOutlineRows(window: fake.rootElement).first)
        try outline.outline.setAttribute(AXAttribute.selectedRows, to: .elements([outline.row.handle]))
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let card = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        return (fake, card)
    }

    private static func handler(_ fake: FakeAXBackend, visual: Bool = true) throws -> WeComCommandHandler {
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b41-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.openContacts, .acceptRequest], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .contactRequestAccept
        handler.visualEnabled = { visual }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("already selected New Customers must not select again")
            return nil
        }
        handler.configureActions = { action in
            action.verifyTimeout = 0.05
            action.verifyInterval = 0.005
            action.acceptTimeout = 0.1
            action.frontmostPid = { nil }
            action.postShortcut = { _, _ in }
            action.openURL = { _ in true }
        }
        return handler
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

    private static func installModel(_ handler: WeComCommandHandler,
                                     captures: @escaping () -> Void = {},
                                     decide: @escaping (AIPlannerStepContext) -> AIPlannerStepDecision) throws {
        let settings = try AIPlannerVisionClientTests.settings()
        handler.visualSettingsForCommit = { settings }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { settings },
                capture: { _, frame in captures(); return Self.shot(frame: frame) },
                decide: { _, context, _ in decide(context) })
        }
    }

    private static func remarkPopover() -> AXNode {
        AXNode(role: AXRole.popover, frame: CGRect(x: 600, y: 300, width: 500, height: 420), children: [
            AXNode(role: AXRole.staticText, value: .string("设置备注名"),
                   frame: CGRect(x: 620, y: 320, width: 100, height: 20)),
            AXNode(role: AXRole.button, title: WeComAcceptPopover.doneTitle,
                   frame: CGRect(x: 620, y: 660, width: 460, height: 40), actions: [AXAction.press]),
        ])
    }

    @Test func twoPassiveRoundsBracketExactlyTwoFixedPresses() throws {
        let (fake, card) = try Self.fixture()
        let handler = try Self.handler(fake)
        var captures = 0, phases: [AIPlannerPhase] = [], checkpoints = 0, after = 0, presses = 0
        try Self.installModel(handler, captures: { captures += 1 }, decide: { context in
            #expect(context.method == .contactRequestAccept)
            #expect(context.allowedSteps == [.verify, .reobserve, .stop])
            #expect(context.goal.description?.contains("button") == true)
            phases.append(context.phase)
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        fake.reactions["action:\(AXAction.press)"] = {
            presses += 1
            if presses == 1 {
                _ = fake.appendChild(to: fake.rootHandle, node: Self.remarkPopover())
            } else {
                fake.mutate(card.button.handle, attribute: AXAttribute.title,
                            to: .string(NewCustomersPage.greetTitle))
            }
        }
        let result = try handler.contactRequestAccept(name: card.name,
            checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["accepted"] == "true" && result["status"] == "added")
        #expect(captures == 2 && phases == [.prepare, .commit])
        #expect(checkpoints == 2 && after == 2 && presses == 2)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press, AXAction.press])
    }

    @Test func modelStopBeforeAcceptOrDoneNeverPressesTheStoppedButton() throws {
        for stopAt in [1, 2] {
            let (fake, card) = try Self.fixture()
            let handler = try Self.handler(fake)
            var rounds = 0, checkpoints = 0, presses = 0
            try Self.installModel(handler, decide: { _ in
                rounds += 1
                return AIPlannerStepDecision(step: rounds == stopAt ? .stop : .verify, candidateID: nil)
            })
            fake.reactions["action:\(AXAction.press)"] = {
                presses += 1
                if presses == 1 { _ = fake.appendChild(to: fake.rootHandle, node: Self.remarkPopover()) }
            }
            #expect(throws: ControlError.self) {
                try handler.contactRequestAccept(name: card.name,
                    checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(rounds == stopAt)
            #expect(checkpoints == stopAt - 1 && presses == stopAt - 1)
        }
    }

    @Test func modelCannotChoosePressOrChangeCandidate() throws {
        for decision in [AIPlannerStepDecision(step: .press, candidateID: "C0"),
                         AIPlannerStepDecision(step: .verify, candidateID: "C0")] {
            let (fake, card) = try Self.fixture()
            let handler = try Self.handler(fake)
            var checkpoints = 0
            try Self.installModel(handler, decide: { _ in decision })
            #expect(throws: ControlError.self) {
                try handler.contactRequestAccept(name: card.name,
                    checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
        }
    }

    @Test func permissionPolicyWindowOrCardDriftStopsBeforeFirstCheckpoint() throws {
        enum Drift: CaseIterable { case permission, policy, window, card }
        for drift in Drift.allCases {
            let (fake, card) = try Self.fixture()
            let handler = try Self.handler(fake)
            var granted = true, captures = 0, checkpoints = 0
            handler.visualScreenRecordingGranted = { granted }
            try Self.installModel(handler, captures: { captures += 1 }, decide: { _ in
                switch drift {
                case .permission: granted = false
                case .policy: handler.policy.enabled.remove(.acceptRequest)
                case .window:
                    fake.mutate(fake.rootHandle, attribute: AXAttribute.frame,
                                to: .rect(CGRect(x: 10, y: 0, width: 1920, height: 1200)))
                case .card:
                    fake.mutate(card.button.handle, attribute: AXAttribute.title,
                                to: .string(NewCustomersPage.greetTitle))
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
            #expect(throws: ControlError.self) {
                try handler.contactRequestAccept(name: card.name,
                    checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(captures == 1 && checkpoints == 0 && fake.recordedActions.isEmpty)
        }
    }

    @Test func unrelatedOrAmbiguousPopoverAfterFirstPressCannotReachDone() throws {
        for ambiguous in [false, true] {
            let (fake, card) = try Self.fixture()
            let handler = try Self.handler(fake)
            var checkpoints = 0, presses = 0
            try Self.installModel(handler, decide: { _ in
                AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
            fake.reactions["action:\(AXAction.press)"] = {
                presses += 1
                _ = fake.appendChild(to: fake.rootHandle, node: ambiguous
                    ? Self.remarkPopover()
                    : AXNode(role: AXRole.popover, frame: CGRect(x: 600, y: 300, width: 500, height: 420),
                             children: [AXNode(role: AXRole.button, title: WeComAcceptPopover.doneTitle,
                                               frame: CGRect(x: 620, y: 660, width: 460, height: 40),
                                               actions: [AXAction.press])]))
                if ambiguous { _ = fake.appendChild(to: fake.rootHandle, node: Self.remarkPopover()) }
            }
            #expect(throws: ControlError.self) {
                try handler.contactRequestAccept(name: card.name,
                    checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(checkpoints == 1 && presses == 1)
        }
    }

    @Test func deterministicOrAutomationPathNeverCreatesVisualRunner() throws {
        for automatic in [false, true] {
            let (fake, card) = try Self.fixture()
            let handler = try Self.handler(fake, visual: automatic)
            if automatic { handler.desktopCommandOrigin = .automation }
            handler.reversibleRunnerFactory = {
                Issue.record("AX-only or automatic accept must not create a visual runner")
                return AIPlannerReversibleRunner(beforeRound: {})
            }
            fake.reactions["action:\(AXAction.press)"] = {
                fake.mutate(card.button.handle, attribute: AXAttribute.title,
                            to: .string(NewCustomersPage.greetTitle))
            }
            let result = try handler.contactRequestAccept(name: card.name)
            #expect(result["accepted"] == "true")
            #expect(fake.recordedActions.map(\.action) == [AXAction.press])
        }
    }
}

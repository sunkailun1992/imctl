import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("contact request reversible visual navigation")
struct AIPlannerContactRequestIntegrationTests {
    private static func harness(method: RPCMethod, parserMiss: Bool = false,
                                visual: Bool = true) throws -> (WeComCommandHandler, FakeAXBackend) {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        if parserMiss {
            // A client variant exposes the exact outline-row label as AXTextField.
            // The regular parser only reads AXTextArea / AXStaticText, but the
            // raw, unique AXRow still identifies the fixed navigation target.
            let label = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath + [0, 1]))
            fake.mutate(label, attribute: AXAttribute.role, to: .string(AXRole.textField))
        }
        let checkpoints = try FileCheckpointStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-b23-contact-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.openContacts, .acceptRequest], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = method
        handler.visualEnabled = { visual }
        handler.visualSettingsForCommit = { try AIPlannerVisionClientTests.settings() }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("the bounded runner must not use the one-step selector")
            return nil
        }
        handler.configureActions = { actions in
            actions.verifyTimeout = 0.05
            actions.verifyInterval = 0.01
            actions.frontmostPid = { nil }
            actions.postShortcut = { _, _ in }
            actions.openURL = { _ in true }
        }
        return (handler, fake)
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

    private static func runner(_ handler: WeComCommandHandler,
                               captures: @escaping () -> Void = {},
                               decide: @escaping AIPlannerReversibleRunner.Decide) -> AIPlannerReversibleRunner {
        AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                  settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                  capture: { _, frame in captures(); return shot(frame: frame) },
                                  decide: decide)
    }

    @Test func disabledVisualKeepsBothCommandsOnTheAXPath() throws {
        let (list, listFake) = try Self.harness(method: .contactRequestList, visual: false)
        list.reversibleRunnerFactory = { Issue.record("list fast path uploaded"); return Self.runner(list, decide: { _, _, _ in .init(step: .stop, candidateID: nil) }) }
        #expect(try list.contactRequestList().count == 3)
        #expect(listFake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)

        let (accept, acceptFake) = try Self.harness(method: .contactRequestAccept, visual: false)
        let table = try #require(try WeComContactsView.newCustomersTable(window: acceptFake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        acceptFake.reactions["action:\(AXAction.press)"] = {
            acceptFake.mutate(pending.button.handle, attribute: AXAttribute.title,
                              to: .string(NewCustomersPage.greetTitle))
        }
        accept.reversibleRunnerFactory = { Issue.record("accept fast path uploaded"); return Self.runner(accept, decide: { _, _, _ in .init(step: .stop, candidateID: nil) }) }
        var checkpoints = 0
        let result = try accept.contactRequestAccept(name: pending.name,
                                                     checkpoint: { checkpoints += 1 }, afterSubmit: {})
        #expect(result["accepted"] == "true" && checkpoints == 1)
        #expect(acceptFake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func recordedWideContactsFixtureAlsoProvesTheAXFastPath() throws {
        let fake = try ContactsFixture.newCustomers()
        #expect(try WeComContactsView.exactNewCustomersOutlineRows(window: fake.rootElement).count == 1)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                       enabled: [.openContacts], phase: .phase1),
                                   verifyTimeout: 0.05, verifyInterval: 0.01)
        actions.frontmostPid = { nil }
        actions.postShortcut = { _, _ in }
        actions.openURL = { _ in true }
        #expect(try actions.contactRequestList(app: fake.rootElement, window: fake.rootElement).count == 2)
        #expect(try WeComContactsView.newCustomersSelectionVerified(window: fake.rootElement))
    }

    @Test func mostlyOffscreenRowUsesAXOnlyWithoutUpload() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList)
        let row = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath))
        let label = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath + [0, 1]))
        fake.mutate(row, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 60, y: 1188, width: 250, height: 36)))
        fake.mutate(label, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 104, y: 1190, width: 56, height: 20)))
        handler.reversibleRunnerFactory = {
            Issue.record("offscreen row uploaded")
            return Self.runner(handler, decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(try handler.contactRequestList().count == 3)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)
    }

    @Test func alreadySelectedExactTextFieldRowSkipsReselectionAndVisualUpload() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList, parserMiss: true)
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        let row = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath))
        fake.mutate(outline, attribute: AXAttribute.selectedRows, to: .elements([row]))
        #expect(try WeComContactsView.newCustomersSelectionVerified(window: fake.rootElement))
        #expect(throws: WeComError.region("contacts.newCustomersRow")) {
            try WeComContactsView.selectNewCustomers(window: fake.rootElement)
        }
        handler.reversibleRunnerFactory = {
            Issue.record("an AX-selected exact row must not upload the window")
            return Self.runner(handler, decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(try handler.contactRequestList().count == 3)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.isEmpty)
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func parserMissUsesOneExactAXRowAndTwoModelRoundsThenReadsCards() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList, parserMiss: true)
        #expect(throws: WeComError.region("contacts.newCustomersRow")) {
            try WeComContactsView.selectNewCustomers(window: fake.rootElement)
        }
        var captures = 0, decisions = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, captures: { captures += 1 }, decide: { observation, context, _ in
                decisions += 1
                #expect(context.method == .contactRequestList)
                #expect(observation.candidates.count == 1)
                #expect(observation.candidates[0].kind == .selectRow)
                if context.phase == .verify {
                    #expect(context.lastEvidence == .postconditionPresent)
                    #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                #expect(context.phase == .locate)
                #expect(context.lastEvidence == .exactNewCustomersRowVisible)
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        #expect(try handler.contactRequestList().count == 3)
        #expect(captures == 2 && decisions == 2)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func parsedUniqueAXRowUsesModelAndVisualPostcondition() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList)
        var captures = 0, decisions = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, captures: { captures += 1 }, decide: { _, context, _ in
                decisions += 1
                if context.phase == .verify {
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        #expect(try handler.contactRequestList().count == 3)
        #expect(captures == 2 && decisions == 2)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)
    }

    @Test func droppedFirstVisualSelectionNeedsFreshThirdObservation() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList)
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        var writes = 0, captures = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            writes += 1
            if writes == 1 { fake.mutate(outline, attribute: AXAttribute.selectedRows, to: .elements([])) }
        }
        handler.reversibleRunnerFactory = {
            Self.runner(handler, captures: { captures += 1 }, decide: { _, context, _ in
                #expect(context.method == .contactRequestList)
                if context.phase == .verify { return AIPlannerStepDecision(step: .verify, candidateID: nil) }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        #expect(try handler.contactRequestList().count == 3)
        #expect(writes == 2 && captures == 3)
        #expect(try WeComContactsView.newCustomersSelectionVerified(window: fake.rootElement))
    }

    @Test func acceptVisualNavigationKeepsCheckpointAndPressAfterUniquePendingCard() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestAccept, parserMiss: true)
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        fake.reactions["action:\(AXAction.press)"] = {
            fake.mutate(pending.button.handle, attribute: AXAttribute.title,
                        to: .string(NewCustomersPage.greetTitle))
        }
        var captures = 0, order: [String] = []
        handler.reversibleRunnerFactory = {
            Self.runner(handler, captures: { captures += 1 }, decide: { _, context, _ in
                #expect(context.method == .contactRequestAccept)
                #expect(fake.recordedActions.isEmpty)
                #expect(order.isEmpty)
                if case .control(.requestAcceptButton) = context.goal {
                    #expect(context.phase == .prepare)
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                if context.phase == .verify { return AIPlannerStepDecision(step: .verify, candidateID: nil) }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        let result = try handler.contactRequestAccept(name: pending.name,
                                                      checkpoint: { order.append("checkpoint") },
                                                      afterSubmit: { order.append("after") })
        #expect(result["accepted"] == "true" && captures == 3)
        #expect(order == ["checkpoint", "after"])
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func postSelectionModelStopCannotReachAcceptCheckpoint() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestAccept)
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        var captures = 0, checkpoints = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, captures: { captures += 1 }, decide: { _, context, _ in
                if context.phase == .verify {
                    #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                    return AIPlannerStepDecision(step: .stop, candidateID: nil)
                }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        #expect(throws: ControlError.self) {
            try handler.contactRequestAccept(name: pending.name,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: {})
        }
        #expect(captures == 2 && checkpoints == 0)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func revokedPolicyOrPauseAfterInferenceBlocksAllAXWrites() throws {
        for revokePolicy in [true, false] {
            let (handler, fake) = try Self.harness(method: .contactRequestList, parserMiss: true)
            var paused = false, captures = 0
            handler.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
            handler.reversibleRunnerFactory = {
                Self.runner(handler, captures: { captures += 1 }, decide: { _, _, _ in
                    if revokePolicy { handler.policy.enabled.remove(.openContacts) }
                    else { paused = true }
                    return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                })
            }
            #expect(throws: ControlError.self) { try handler.contactRequestList() }
            #expect(captures == 1)
            #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        }
    }

    @Test func revokedFullWindowGrantAfterInferenceBlocksAXWrite() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestList, parserMiss: true)
        var settings = try AIPlannerVisionClientTests.settings()
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { settings },
                                      capture: { _, frame in Self.shot(frame: frame) },
                                      decide: { _, _, _ in
                                          try settings.setFullWindowEnabled(false)
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try handler.contactRequestList() }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func changedPendingCardAfterVisualNavigationCannotReachCheckpoint() throws {
        let (handler, fake) = try Self.harness(method: .contactRequestAccept, parserMiss: true)
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        var checkpoints = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, decide: { _, context, _ in
                fake.mutate(pending.button.handle, attribute: AXAttribute.title,
                            to: .string(NewCustomersPage.greetTitle))
                if context.phase == .verify { return AIPlannerStepDecision(step: .verify, candidateID: nil) }
                return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        }
        #expect(throws: ControlError.self) {
            try handler.contactRequestAccept(name: pending.name,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: {})
        }
        #expect(checkpoints == 0 && fake.recordedActions.isEmpty)
    }

    @Test func changedWindowOrRowDuringInferenceCannotBeSelected() throws {
        for changeWindow in [true, false] {
            let (handler, fake) = try Self.harness(method: .contactRequestList, parserMiss: true)
            let row = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath))
            handler.reversibleRunnerFactory = {
                Self.runner(handler, decide: { _, _, _ in
                    if changeWindow {
                        fake.mutate(fake.rootHandle, attribute: AXAttribute.frame,
                                    to: .rect(CGRect(x: 20, y: 0, width: 1920, height: 1200)))
                    } else {
                        fake.mutate(row, attribute: AXAttribute.frame,
                                    to: .rect(CGRect(x: 60, y: 150, width: 250, height: 36)))
                    }
                    return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                })
            }
            #expect(throws: ControlError.self) { try handler.contactRequestList() }
            #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        }
    }

    @Test func duplicateExactRowsAndAutomationOriginNeverUpload() throws {
        let (ambiguous, fake) = try Self.harness(method: .contactRequestAccept, parserMiss: true)
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        _ = fake.appendChild(to: outline, node: AXNode(role: AXRole.row,
            frame: CGRect(x: 60, y: 260, width: 250, height: 36), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: 260, width: 250, height: 36), children: [
                    AXNode(role: AXRole.textField, value: .string(WeComContactsView.newCustomersTitle),
                           frame: CGRect(x: 104, y: 268, width: 56, height: 20)),
                ]),
            ]))
        ambiguous.reversibleRunnerFactory = {
            Self.runner(ambiguous, captures: { Issue.record("duplicate rows uploaded") },
                        decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(throws: ControlError.self) { try ambiguous.contactRequestAccept(name: "赵六") }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)

        let (background, backgroundFake) = try Self.harness(method: .contactRequestList, parserMiss: true)
        background.desktopCommandOrigin = .automation
        background.reversibleRunnerFactory = {
            Self.runner(background, captures: { Issue.record("automation uploaded") },
                        decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(throws: ControlError.self) { try background.contactRequestList() }
        #expect(backgroundFake.recordedSets.isEmpty && backgroundFake.recordedActions.isEmpty)
    }
}

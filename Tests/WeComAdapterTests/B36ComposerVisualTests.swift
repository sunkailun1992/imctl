import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B36 passive visual composer preparation")
struct B36ComposerVisualTests {
    private static func checkpoints() throws -> FileCheckpointStore {
        try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b36-\(UUID().uuidString)"))
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

    @Test func passiveRunnerObservesTwoFreshStatesWithoutChoosingAWrite() throws {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let composer = try #require(reader.layout.composer)
        let settings = try AIPlannerVisionClientTests.settings()
        var captures = 0, decisions = 0
        let runner = AIPlannerReversibleRunner(
            beforeRound: {}, settingsProvider: { settings },
            capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
            decide: { _, context, _ in
                decisions += 1
                #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                #expect(context.goal.description == "the current chat message input field")
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            })
        func round(_ phase: AIPlannerPhase) -> AIPlannerReversibleRound {
            AIPlannerReversibleRound(window: reader.layout.window, goal: .control(.messageComposer),
                                    action: .writeText, eligible: [composer],
                                    expectedTitle: GroupFixture.groupTitle, phase: phase,
                                    evidence: phase == .prepare ? .inputReady : .postconditionPresent)
        }
        let first = try runner.observeComposer(method: .messageSend, phase: .prepare,
                                               gate: {}, observe: { round(.prepare) },
                                               verify: { try composer.valueString() == "" })
        #expect(first.outcome == .verified)
        fake.mutate(composer.handle, attribute: AXAttribute.value, to: .string("synthetic"))
        let second = try runner.observeComposer(method: .messageSend, phase: .verify,
                                                expectedSettings: first.settings,
                                                gate: {}, observe: { round(.verify) },
                                                verify: { try composer.valueString() == "synthetic" })
        #expect(second.outcome == .verified)
        #expect(captures == 2 && decisions == 2)
        #expect(fake.recordedActions.isEmpty)
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func firstModelStopNeverStagesTextOrCheckpoint() throws {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let checkpoints = try Self.checkpoints()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.submit], phase: .phase1))
        actions.visualObserveComposer = { _, _, stage, verify in
            #expect(stage == .beforeStaging)
            #expect(try verify())
            throw ActionError.actionUnavailable("composer visual round stopped")
        }
        actions.postReturnKey = { _, _ in Issue.record("model stop must not submit") }
        #expect(throws: ActionError.actionUnavailable("composer visual round stopped")) {
            try actions.submit(text: "synthetic", strategy: .enterKey,
                               reader: reader, checkpoints: checkpoints)
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        #expect(try checkpoints.pending().isEmpty)
    }

    @Test func explicitHandlerSendRequiresTwoModelObservationsBeforeCheckpoint() throws {
        let fake = GroupFixture.backend()
        let checkpoints = try Self.checkpoints()
        let settings = try AIPlannerVisionClientTests.settings()
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                          policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                               enabled: [.submit], phase: .phase1),
                                          checkpoints: checkpoints)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .messageSend
        handler.visualEnabled = { true }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSettingsForCommit = { settings }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("active target must not trigger row selection")
            return nil
        }
        var captures = 0, decisions = 0, returns = 0
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { settings },
                                      capture: { _, frame in
                                          captures += 1
                                          return Self.shot(frame: frame)
                                      }, decide: { _, context, _ in
                                          decisions += 1
                                          #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                                          return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                      })
        }
        handler.configureActions = { actions in
            actions.postReturnKey = { _, _ in returns += 1 }
        }
        #expect(throws: CrashInjected.self) {
            try handler.messageSend(target: GroupFixture.groupTitle, text: "synthetic",
                                    checkpoint: { throw CrashInjected() }, afterSubmit: {})
        }
        let composer = try #require(try WeComReader(window: fake.rootElement).layout.composer)
        #expect(try composer.valueString() == "synthetic")
        #expect(captures == 2 && decisions == 2 && returns == 0)
        #expect(fake.recordedSets.filter { $0.handle == composer.handle && $0.attribute == AXAttribute.value }.count == 1)
        #expect(try checkpoints.pending().count == 1)
    }

    @Test func explicitHandlerSendUsesTwoObservationsAndOneConfirmedAXSubmit() throws {
        let fake = try Fixtures.mainWindow()
        let composerHandle = try #require(fake.handle(atPath: [0, 33, 6, 0, 2, 0]))
        fake.setActions(of: composerHandle, to: [AXAction.confirm])
        try SubmitTests().installSendReaction(on: fake, text: "synthetic", appendRow: true)
        let checkpoints = try Self.checkpoints()
        let settings = try AIPlannerVisionClientTests.settings()
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                          policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                               enabled: [.submit], phase: .phase1),
                                          checkpoints: checkpoints, strategy: .axConfirm,
                                          submitTimeout: 0.2)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .messageSend
        handler.visualEnabled = { true }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSettingsForCommit = { settings }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("active target must not trigger row selection")
            return nil
        }
        var captures = 0, decisions = 0, checkpointsSeen = 0, submitted = 0
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { settings },
                                      capture: { _, frame in
                                          captures += 1
                                          return Self.shot(frame: frame)
                                      }, decide: { _, context, _ in
                                          decisions += 1
                                          #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                                          return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                      })
        }
        let result = try handler.messageSend(target: "文件传输助手", text: "synthetic",
                                             checkpoint: { checkpointsSeen += 1 },
                                             afterSubmit: { submitted += 1 })
        #expect(result.state == .succeeded)
        #expect(result.evidence?.contains("outbound") == true)
        #expect(captures == 2 && decisions == 2)
        #expect(checkpointsSeen == 1 && submitted == 1)
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.count == 1)
    }

    @Test func broadcastChildKeepsExistingAXSendWithoutComposerUploads() throws {
        let fake = try Fixtures.mainWindow()
        let composerHandle = try #require(fake.handle(atPath: [0, 33, 6, 0, 2, 0]))
        fake.setActions(of: composerHandle, to: [AXAction.confirm])
        try SubmitTests().installSendReaction(on: fake, text: "synthetic", appendRow: true)
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                          policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                               enabled: [.submit], phase: .phase1),
                                          checkpoints: try Self.checkpoints(), strategy: .axConfirm,
                                          submitTimeout: 0.2)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .messageSend
        handler.desktopCommandIsBroadcastChild = true
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("already active broadcast child must not select")
            return nil
        }
        var factories = 0
        handler.reversibleRunnerFactory = {
            factories += 1
            return AIPlannerReversibleRunner(beforeRound: {},
                                             capture: { _, _ in
                                                 Issue.record("broadcast child must not capture")
                                                 return nil
                                             })
        }
        let result = try handler.messageSend(target: "文件传输助手", text: "synthetic",
                                             checkpoint: {}, afterSubmit: {})
        #expect(result.state == .succeeded && factories == 0)
    }

    @Test func gateAfterCheckpointReturnsUnknownWithoutClientSubmit() throws {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let checkpoints = try Self.checkpoints()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.submit], phase: .phase1))
        actions.visualObserveComposer = { _, _, _, verify in
            let valid = try verify()
            #expect(valid)
        }
        var gates = 0
        actions.visualComposerCommitGate = {
            gates += 1
            if gates == 3 { throw ActionError.actionUnavailable("stale window") }
        }
        let result = try actions.submit(text: "synthetic", strategy: .axConfirm,
                                        reader: reader, checkpoints: checkpoints)
        #expect(result.state == .unknown && gates == 3)
        #expect(fake.recordedActions.isEmpty)
        #expect(try checkpoints.load(id: result.checkpointID)?.state == .unknown)
    }

    @Test func permissionSettingsModalOrBudgetChangeStopsBeforeTextStaging() throws {
        enum Interruption: CaseIterable { case screenGrant, settings, modal, budget }
        for interruption in Interruption.allCases {
            let fake = GroupFixture.backend()
            let checkpoints = try Self.checkpoints()
            let settings = try AIPlannerVisionClientTests.settings()
            var currentSettings = settings
            var screenGranted = true
            let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                              policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                                   enabled: [.submit], phase: .phase1),
                                              checkpoints: checkpoints)
            handler.desktopCommandOrigin = .external
            handler.desktopCommandMethod = .messageSend
            handler.visualEnabled = { true }
            handler.visualScreenRecordingGranted = { screenGranted }
            handler.visualSettingsForCommit = { currentSettings }
            handler.visualSelect = { _, _, _, _, _, _ in nil }
            if interruption == .budget { handler.maxVisualDuration = 0.01 }
            var captures = 0
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in
                                              captures += 1
                                              return Self.shot(frame: frame)
                                          }, decide: { _, _, _ in
                                              switch interruption {
                                              case .screenGrant: screenGranted = false
                                              case .settings: currentSettings.disable()
                                              case .modal:
                                                  fake.appendChild(to: fake.rootHandle,
                                                                   node: AXNode(role: AXRole.sheet))
                                              case .budget: Thread.sleep(forTimeInterval: 0.02)
                                              }
                                              return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                          })
            }
            handler.configureActions = { actions in
                actions.postReturnKey = { _, _ in Issue.record("interrupted visual round must not submit") }
            }
            #expect(throws: ControlError.self) {
                try handler.messageSend(target: GroupFixture.groupTitle, text: "synthetic",
                                        checkpoint: {}, afterSubmit: {})
            }
            #expect(captures == 1)
            #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
            #expect(try checkpoints.pending().isEmpty)
        }
    }

    @Test func ambiguousComposerNeverCallsVisualObserver() throws {
        let fake = GroupFixture.backend()
        fake.appendChild(to: fake.rootHandle, node: AXNode(
            role: AXRole.textArea, value: .string(""),
            frame: CGRect(x: 311, y: 1036, width: 1609, height: 159),
            settable: [AXAttribute.value]))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(reader.layout.composerAmbiguous)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.submit], phase: .phase1))
        var observations = 0
        actions.visualObserveComposer = { _, _, _, _ in observations += 1 }
        let checkpoints = try Self.checkpoints()
        #expect(throws: ActionError.actionUnavailable("ambiguous composer")) {
            try actions.submit(text: "synthetic", strategy: .enterKey,
                               reader: reader, checkpoints: checkpoints)
        }
        #expect(observations == 0 && fake.recordedSets.isEmpty)
        #expect(try checkpoints.pending().isEmpty)
    }

    @Test func secondModelStopClearsOnlyItsUnchangedTextBeforeCheckpoint() throws {
        for humanEdit in [false, true] {
            let fake = GroupFixture.backend()
            let reader = try WeComReader(window: fake.rootElement)
            let composer = try #require(reader.layout.composer)
            let checkpoints = try Self.checkpoints()
            var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                          enabled: [.submit], phase: .phase1))
            actions.visualComposerStillCurrent = { _, _ in true }
            actions.visualObserveComposer = { _, _, stage, verify in
                if stage == .beforeStaging { #expect(try verify()); return }
                if humanEdit {
                    fake.mutate(composer.handle, attribute: AXAttribute.value,
                                to: .string("human draft"))
                }
                throw ActionError.actionUnavailable("composer visual round stopped")
            }
            actions.postReturnKey = { _, _ in Issue.record("model stop must not submit") }
            #expect(throws: ActionError.actionUnavailable("composer visual round stopped")) {
                try actions.submit(text: "synthetic", strategy: .enterKey,
                                   reader: reader, checkpoints: checkpoints)
            }
            #expect(try composer.valueString() == (humanEdit ? "human draft" : ""))
            #expect(try checkpoints.pending().isEmpty)
        }
    }

    @Test func fileSecondModelStopRestoresClipboardAndNeverPastesTwiceOrSubmits() throws {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let composer = try #require(reader.layout.composer)
        let checkpoints = try Self.checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.frontmostPid = { 4242 }
        var pastes = 0, returns = 0
        actions.postShortcut = { _, _ in
            pastes += 1
            fake.mutate(composer.handle, attribute: AXAttribute.value, to: .string("\u{FFFC}"))
            fake.mutate(composer.handle, attribute: AXAttribute.numberOfCharacters, to: .integer(1))
            fake.appendChild(to: composer.handle, node: AXNode(role: AXRole.unknown))
        }
        actions.postReturnKey = { _, _ in returns += 1 }
        actions.visualObserveComposer = { _, _, stage, verify in
            #expect(try verify())
            if stage == .afterStaging {
                throw ActionError.actionUnavailable("composer visual round stopped")
            }
        }
        let file = FetchedFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("fixture.pdf"),
                               fileName: "fixture.pdf", bytes: 8, kind: "file",
                               contentType: "application/pdf")
        #expect(throws: ActionError.actionUnavailable("composer visual round stopped")) {
            try actions.sendFile(file, reader: reader, checkpoints: checkpoints)
        }
        #expect(pastes == 1 && returns == 0)
        #expect(board.snapshots == 1 && board.restored.count == 1)
        #expect(try checkpoints.pending().isEmpty)
    }
}

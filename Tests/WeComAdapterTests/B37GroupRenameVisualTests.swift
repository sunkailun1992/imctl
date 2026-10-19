import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B37 passive group rename visual preparation")
struct B37GroupRenameVisualTests {
    private static let requested = "合成新群名"

    private static func fixture() throws -> (FakeAXBackend, String, AXElement, AXElementHandle) {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root
            .appendingPathComponent("wecom-5.0.11-external-group.json")))
        let reader = try WeComReader(window: fake.rootElement)
        let old = try #require(try reader.activeConversationTitle())
        let field = try #require(reader.layout.activeTitle)
        let rowTitle = try #require(try reader.activeConversationRow()?.handle.titleTextHandle(in: fake))
        return (fake, old, field, rowTitle)
    }

    private static func handler(_ fake: FakeAXBackend, title: String) throws -> WeComCommandHandler {
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b37-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                          policy: ActionPolicy(allowedTargets: [title],
                                                               enabled: [.renameGroup], phase: .phase1),
                                          checkpoints: checkpoints)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .groupRename
        handler.visualEnabled = { true }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("active group must not reselect a conversation")
            return nil
        }
        handler.configureActions = { actions in
            actions.verifyTimeout = 0.05
            actions.verifyInterval = 0.005
            actions.groupOpenTimeout = 0.2
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

    private static func passiveVision(_ handler: WeComCommandHandler, settings: CloudVisionSettings,
                                      decide: @escaping (AIPlannerStepContext) throws -> AIPlannerStepDecision) {
        handler.visualSettingsForCommit = { settings }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { settings },
                                      capture: { _, frame in Self.shot(frame: frame) },
                                      decide: { _, context, _ in try decide(context) })
        }
    }

    @Test func activeGroupUsesTwoFreshPassiveRoundsBeforeOneConfirm() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        handler.visualSettingsForCommit = { settings }
        var captures = 0, decisions = 0, checkpoints = 0, after = 0
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { settings },
                                      capture: { _, frame in
                                          captures += 1
                                          return Self.shot(frame: frame)
                                      }, decide: { _, context, _ in
                                          decisions += 1
                                          #expect(context.method == .groupRename)
                                          #expect(context.goal.description == "the editable group name field in the current group header")
                                          #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                                          return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                      })
        }
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
        }
        let result = try handler.groupRename(target: old, name: Self.requested,
                                             checkpoint: { checkpoints += 1 },
                                             afterSubmit: { after += 1 })
        #expect(result["renamed"] == "true")
        #expect(captures == 2 && decisions == 2)
        #expect(checkpoints == 1 && after == 1)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.count == 1)
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.count == 1)
    }

    @Test func modelStopBeforeOrAfterStagingCannotConfirm() throws {
        for stopAt in [1, 2] {
            let (fake, old, field, _) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            handler.visualSettingsForCommit = { settings }
            var rounds = 0, checkpoints = 0
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              rounds += 1
                                              return AIPlannerStepDecision(step: rounds == stopAt ? .stop : .verify,
                                                                           candidateID: nil)
                                          })
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(rounds == stopAt && checkpoints == (stopAt == 1 ? 0 : 1))
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
            let fieldWrites = fake.recordedSets.filter {
                $0.handle == field.handle && $0.attribute == AXAttribute.value
            }.map(\.value)
            #expect(fieldWrites == (stopAt == 1 ? [] : [.string(Self.requested), .string(old)]))
            #expect(try field.valueString() == old)
        }
    }

    @Test func targetOrEditorDriftDuringModelRoundStopsBeforeConfirm() throws {
        enum Drift: CaseIterable { case selectedRow, editorValue, policy, screenGrant }
        for drift in Drift.allCases {
            let (fake, old, field, rowTitle) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            handler.visualSettingsForCommit = { settings }
            var screenGranted = true
            handler.visualScreenRecordingGranted = { screenGranted }
            var checkpoints = 0, captures = 0
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                          decide: { _, context, _ in
                                              if context.phase == .verify {
                                                  switch drift {
                                                  case .selectedRow:
                                                      fake.mutate(rowTitle, attribute: AXAttribute.value,
                                                                  to: .string("另一测试群"))
                                                  case .editorValue:
                                                      fake.mutate(field.handle, attribute: AXAttribute.value,
                                                                  to: .string("人工草稿"))
                                                  case .policy:
                                                      handler.policy.enabled.remove(.renameGroup)
                                                  case .screenGrant:
                                                      screenGranted = false
                                                  }
                                              }
                                              return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                          })
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            let rollbackUncertain = drift == .selectedRow || drift == .editorValue
            #expect(captures == 2 && checkpoints == 1)
            if !rollbackUncertain { #expect(try field.valueString() == old) }
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }

    /// Some client builds apply AXValue before AXConfirm. The original list row,
    /// not the editor's echo, proves that this command already changed its group.
    @Test func valueWriteThatAlreadyRenamedTheOriginalRowNeedsNoConfirm() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var rounds = 0, checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { _ in
            rounds += 1
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == field.handle,
                  fake.recordedSets.last?.value == .string(Self.requested) else { return }
            #expect(checkpoints == 1)
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
        }
        let result = try handler.groupRename(target: old, name: Self.requested,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["renamed"] == "true" && result["title"] == Self.requested)
        #expect(rounds == 1 && checkpoints == 1 && after == 1)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested)])
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func originalRowRenamedDuringTheSecondObservationIsVerifiedWithoutConfirm() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var rounds = 0, checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { context in
            rounds += 1
            if context.phase == .verify {
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
            }
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        let result = try handler.groupRename(target: old, name: Self.requested,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["renamed"] == "true" && result["title"] == Self.requested)
        #expect(rounds == 2 && checkpoints == 1 && after == 1)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested)])
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func secondValueWriteThatAppliesTheRequestedNameNeedsNoConfirm() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var rounds = 0, writes = 0, checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { _ in
            rounds += 1
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == field.handle,
                  fake.recordedSets.last?.value == .string(Self.requested) else { return }
            writes += 1
            #expect(checkpoints == 1)
            if writes == 1 {
                fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(old))
            } else {
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
            }
        }
        let result = try handler.groupRename(target: old, name: Self.requested,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["renamed"] == "true" && result["title"] == Self.requested)
        #expect(rounds == 1 && writes == 2 && checkpoints == 1 && after == 1)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested), .string(Self.requested)])
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func nameAppliedAfterTheSecondObservationIsVerifiedWithoutConfirm() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var rounds = 0, checkpoints = 0, after = 0
        var appliedAfterObservation = false
        Self.passiveVision(handler, settings: settings) { _ in
            rounds += 1
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        // This callback is read by the fixed commit gate after both passive
        // observations have returned. Apply the server's row update there.
        handler.visualSettingsForCommit = {
            if rounds == 2 && !appliedAfterObservation {
                appliedAfterObservation = true
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
            }
            return settings
        }
        let result = try handler.groupRename(target: old, name: Self.requested,
                                             checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        #expect(result["renamed"] == "true" && result["title"] == Self.requested)
        #expect(appliedAfterObservation && rounds == 2 && checkpoints == 1 && after == 1)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested)])
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func earlyAppliedNamePropagatesTheAfterSubmitCrashWithoutConfirmOrRollback() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { _ in
            AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == field.handle,
                  fake.recordedSets.last?.value == .string(Self.requested) else { return }
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
        }
        #expect(throws: CrashInjected.self) {
            try handler.groupRename(target: old, name: Self.requested,
                                    checkpoint: { checkpoints += 1 }, afterSubmit: {
                after += 1
                throw CrashInjected()
            })
        }
        #expect(checkpoints == 1 && after == 1)
        #expect(try field.valueString() == Self.requested)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested)])
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func switchingToAnotherRowWithTheOldNameCannotRestoreItsEditor() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let reader = try WeComReader(window: fake.rootElement)
        let originalRow = try #require(try reader.activeConversationRow())
        let otherRow = try #require(try reader.conversations().first { $0.handle != originalRow.handle })
        let otherTitle = try #require(otherRow.handle.titleTextHandle(in: fake))
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var rounds = 0, checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { context in
            rounds += 1
            if context.phase == .verify {
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                fake.mutate(originalRow.handle, attribute: AXAttribute.selected, to: .bool(false))
                fake.mutate(otherTitle, attribute: AXAttribute.value, to: .string(old))
                fake.mutate(otherRow.handle, attribute: AXAttribute.selected, to: .bool(true))
            }
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        #expect(throws: ControlError.self) {
            try handler.groupRename(target: old, name: Self.requested,
                                    checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        }
        #expect(rounds == 2 && checkpoints == 1 && after == 0)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }
            .map(\.value) == [.string(Self.requested)])
        #expect(try field.valueString() == Self.requested)
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func earlyNewNameWithAmbiguousOrChangedOwnershipCannotSucceedOrConfirm() throws {
        enum Drift: CaseIterable { case duplicateName, selectedRow, windowFrame, replacedEditor }
        for drift in Drift.allCases {
            let (fake, old, field, rowTitle) = try Self.fixture()
            let reader = try WeComReader(window: fake.rootElement)
            let originalRow = try #require(try reader.activeConversationRow())
            let otherRow = try #require(try reader.conversations().first { $0.handle != originalRow.handle })
            let otherTitle = try #require(otherRow.handle.titleTextHandle(in: fake))
            let window = reader.layout.window
            let windowFrame = try #require(try window.frame())
            let fieldFrame = try #require(try field.frame())
            let fieldParent = try #require(try field.parent())
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            var rounds = 0, checkpoints = 0, after = 0
            Self.passiveVision(handler, settings: settings) { _ in
                rounds += 1
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            fake.reactions["set:\(AXAttribute.value)"] = {
                guard fake.recordedSets.last?.handle == field.handle,
                      fake.recordedSets.last?.value == .string(Self.requested) else { return }
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                switch drift {
                case .duplicateName:
                    fake.mutate(otherTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                case .selectedRow:
                    fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(old))
                    fake.mutate(originalRow.handle, attribute: AXAttribute.selected, to: .bool(false))
                    fake.mutate(otherTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                    fake.mutate(otherRow.handle, attribute: AXAttribute.selected, to: .bool(true))
                case .windowFrame:
                    fake.mutate(window.handle, attribute: AXAttribute.frame,
                                to: .rect(windowFrame.offsetBy(dx: 20, dy: 0)))
                case .replacedEditor:
                    fake.removeChild(field.handle, from: fieldParent.handle)
                    fake.appendChild(to: fieldParent.handle,
                                     node: AXNode(role: AXRole.textField, value: .string(Self.requested),
                                                  frame: fieldFrame, actions: [AXAction.confirm],
                                                  settable: [AXAttribute.value, AXAttribute.focused]))
                }
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
            }
            #expect(rounds == 1 && checkpoints == 1 && after == 0)
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }

    @Test func ownershipChangedByTheCheckpointStopsBeforeWritingOrConfirming() throws {
        let (fake, old, field, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        let settings = try AIPlannerVisionClientTests.settings()
        var checkpoints = 0, after = 0
        Self.passiveVision(handler, settings: settings) { _ in
            AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        #expect(throws: ControlError.self) {
            try handler.groupRename(target: old, name: Self.requested, checkpoint: {
                checkpoints += 1
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("另一测试群"))
            }, afterSubmit: { after += 1 })
        }
        #expect(checkpoints == 1 && after == 0)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.isEmpty)
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
    }

    @Test func earlyAppliedNameCannotBypassRevokedPolicyGrantOrModelSettings() throws {
        enum Revoked: CaseIterable { case policy, screenGrant, modelSettings }
        for revoked in Revoked.allCases {
            let (fake, old, field, rowTitle) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            var currentSettings = settings
            var screenGranted = true
            var rounds = 0, checkpoints = 0, after = 0
            Self.passiveVision(handler, settings: settings) { _ in
                rounds += 1
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            handler.visualSettingsForCommit = { currentSettings }
            handler.visualScreenRecordingGranted = { screenGranted }
            fake.reactions["set:\(AXAttribute.value)"] = {
                guard fake.recordedSets.last?.handle == field.handle,
                      fake.recordedSets.last?.value == .string(Self.requested) else { return }
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                switch revoked {
                case .policy: handler.policy.enabled.remove(.renameGroup)
                case .screenGrant: screenGranted = false
                case .modelSettings: currentSettings.disable()
                }
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
            }
            #expect(rounds == 1 && checkpoints == 1 && after == 0)
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }

    /// A stale-view gate after the model response must not hide its stop or an
    /// illegal choice and then turn the already-visible new name into success.
    @Test func secondRoundVetoWithANewListNameStillCannotSucceedOrConfirm() throws {
        let vetoes: [(AIPlannerStep, String?)] = [(.stop, nil), (.writeText, "C0"),
                                                (.press, "C0"), (.verify, "C0")]
        for (veto, candidateID) in vetoes {
            let (fake, old, _, rowTitle) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            var rounds = 0, checkpoints = 0, after = 0
            Self.passiveVision(handler, settings: settings) { context in
                rounds += 1
                if context.phase == .verify {
                    fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                    return AIPlannerStepDecision(step: veto, candidateID: candidateID)
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
            }
            #expect(rounds == 2 && checkpoints == 1 && after == 0)
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }

    @Test func noVisualConfigurationPreservesExistingAXPathWithoutCapture() throws {
        let (fake, old, _, rowTitle) = try Self.fixture()
        let handler = try Self.handler(fake, title: old)
        handler.visualEnabled = { false }
        handler.reversibleRunnerFactory = {
            Issue.record("disabled vision must not create a runner")
            return AIPlannerReversibleRunner(beforeRound: {})
        }
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(Self.requested))
        }
        let result = try handler.groupRename(target: old, name: Self.requested)
        #expect(result["renamed"] == "true")
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.count == 1)
    }

    @Test func ambiguousHeaderEditorOrMissingScreenGrantNeverUploadsOrWritesName() throws {
        for ambiguous in [false, true] {
            let (fake, old, field, _) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            if ambiguous {
                fake.appendChild(to: fake.rootHandle,
                                 node: AXNode(role: AXRole.textField, value: .string(old),
                                              frame: CGRect(x: 800, y: 20, width: 180, height: 25),
                                              settable: [AXAttribute.value]))
            } else {
                handler.visualScreenRecordingGranted = { false }
            }
            var captures = 0, checkpoints = 0
            let settings = try AIPlannerVisionClientTests.settings()
            handler.visualSettingsForCommit = { settings }
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              Issue.record("ambiguous field or denied grant must not call model")
                                              return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                          })
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: { checkpoints += 1 }, afterSubmit: {})
            }
            #expect(captures == 0 && checkpoints == 0)
            #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.isEmpty)
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }

    @Test func modelCannotChooseAWriteOrConfirmStep() throws {
        for forbidden in [AIPlannerStep.writeText, .press] {
            let (fake, old, field, _) = try Self.fixture()
            let handler = try Self.handler(fake, title: old)
            let settings = try AIPlannerVisionClientTests.settings()
            handler.visualSettingsForCommit = { settings }
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              AIPlannerStepDecision(step: forbidden, candidateID: "C0")
                                          })
            }
            #expect(throws: ControlError.self) {
                try handler.groupRename(target: old, name: Self.requested,
                                        checkpoint: {}, afterSubmit: {})
            }
            #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.isEmpty)
            #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.isEmpty)
        }
    }
}

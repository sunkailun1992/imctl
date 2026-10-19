import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B60 group-name text may resize only its original header editor")
struct B60GroupNameFieldResizeTests {
    private static let original = "合成原群"
    private static let requested = "合成待验证的新群名"

    private final class Harness {
        let fake: FakeAXBackend
        let backend: ResizeBackend
        let window: AXElement
        let field: AXElement
        let fieldParent: AXElementHandle
        let fieldFrame: CGRect
        let windowFrame: CGRect
        let row: AXElementHandle
        let rowTitle: AXElementHandle
        let otherRow: AXElementHandle
        let otherTitle: AXElementHandle
        let handler: WeComCommandHandler
        let settings: CloudVisionSettings
        var checkpoints = 0
        var afterSubmit = 0
        var captures = 0
        var decisions = 0
        var stages = 0
        var serverName = B60GroupNameFieldResizeTests.original
        var onStage: (() -> Void)?
        var onDecision: ((AIPlannerStepContext) throws -> AIPlannerStepDecision)?

        init() throws {
            var main = try AXNode.load(from: Fixtures.root
                .appendingPathComponent("wecom-5.0.11-external-group.json"))
            main.subrole = "AXStandardWindow"
            let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [main]))
            let backend = ResizeBackend(fake)
            let window = AXElement(handle: try #require(fake.handle(atPath: [0])), backend: backend)
            let reader = try WeComReader(window: window)
            let field = try #require(reader.layout.activeTitle)
            let selected = try #require(try reader.activeConversationRow())
            let other = try #require(try reader.conversations().first { $0.handle != selected.handle })
            self.fake = fake
            self.backend = backend
            self.window = window
            self.field = field
            fieldParent = try #require(try field.parent()?.handle)
            fieldFrame = try #require(try field.frame())
            windowFrame = reader.layout.windowFrame
            row = selected.handle
            rowTitle = try #require(selected.handle.titleTextHandle(in: fake))
            otherRow = other.handle
            otherTitle = try #require(other.handle.titleTextHandle(in: fake))
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(B60GroupNameFieldResizeTests.original))
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(B60GroupNameFieldResizeTests.original))
            let settings = try AIPlannerVisionClientTests.settings()
            self.settings = settings
            let store = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("imctl-b60-\(UUID().uuidString)"))
            let handler = WeComCommandHandler(rootProvider: {
                AXElement(handle: fake.rootHandle, backend: backend)
            }, policy: ActionPolicy(allowedTargets: [B60GroupNameFieldResizeTests.original],
                enabled: [.renameGroup], phase: .phase1), checkpoints: store)
            self.handler = handler
            handler.desktopCommandOrigin = .external
            handler.desktopCommandMethod = .groupRename
            handler.visualEnabled = { true }
            handler.visualScreenRecordingGranted = { true }
            handler.visualSettingsForCommit = { settings }
            handler.visualSelect = { _, _, _, _, _, _ in
                Issue.record("The synthetic group is already active and must not be reselected")
                return nil
            }
            handler.configureActions = { actions in
                actions.verifyTimeout = 0.05
                actions.verifyInterval = 0.005
                actions.groupOpenTimeout = 0.1
                actions.frontmostPid = { Issue.record("A visible fake must not activate an application"); return nil }
                actions.restoreFrontmost = { _ in Issue.record("A visible fake must not restore desktop focus") }
            }
            handler.reversibleRunnerFactory = { [unowned self] in
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                    settingsProvider: { settings }, capture: { _, frame in
                        self.captures += 1
                        return B60GroupNameFieldResizeTests.shot(frame)
                    }, decide: { _, context, _ in
                        self.decisions += 1
                        return try self.onDecision?(context)
                            ?? AIPlannerStepDecision(step: .verify, candidateID: nil)
                    })
            }
            fake.reactions["set:\(AXAttribute.value)"] = { [unowned self] in
                guard let last = fake.recordedSets.last, last.handle == field.handle else { return }
                // Independent server state intentionally does not update the
                // desktop row. B60's phone confirmation proved this can happen.
                if case .string(let name) = last.value { self.serverName = name }
                if last.value == .string(B60GroupNameFieldResizeTests.requested) {
                    self.stages += 1
                    self.onStage?()
                }
            }
            fake.reactions["action:\(AXAction.confirm)"] = { [unowned self] in self.applyRowName() }
        }

        func resize(width: CGFloat) {
            fake.mutate(field.handle, attribute: AXAttribute.frame,
                to: .rect(CGRect(x: fieldFrame.minX, y: fieldFrame.minY,
                                 width: width, height: fieldFrame.height)))
        }

        func applyRowName() {
            fake.mutate(rowTitle, attribute: AXAttribute.value,
                        to: .string(B60GroupNameFieldResizeTests.requested))
        }

        func run() throws -> [String: String] {
            try handler.groupRename(target: B60GroupNameFieldResizeTests.original,
                name: B60GroupNameFieldResizeTests.requested,
                checkpoint: { self.checkpoints += 1 }, afterSubmit: { self.afterSubmit += 1 })
        }

        var fieldWrites: [AXAttributeValue] {
            fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.map(\.value)
        }

        var confirms: Int { fake.recordedActions.filter { $0.action == AXAction.confirm }.count }

        var attemptedValueWrites: [AXAttributeValue] {
            backend.valueWriteAttempts.map(\.value)
        }
    }

    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot? {
        guard let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: frame.size))
        guard let image = context.makeImage() else { return nil }
        return WeComWindowScreenshot(image: image, windowFrame: frame)
    }

    @Test func widthGrowthOrShrinkAfterTheFixedValueStillUsesTwoRoundsAndOneConfirm() throws {
        for delta: CGFloat in [80, -60] {
            let h = try Harness()
            h.onStage = { h.resize(width: h.fieldFrame.width + delta) }
            let result = try h.run()
            #expect(result["renamed"] == "true" && result["title"] == Self.requested)
            #expect(h.captures == 2 && h.decisions == 2)
            #expect(h.stages == 1 && h.checkpoints == 1 && h.afterSubmit == 1 && h.confirms == 1)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            let selected = try WeComReader(window: h.window).conversations().filter(\.selected)
            #expect(selected.count == 1 && selected[0].handle == h.row && selected[0].title == Self.requested)
        }
    }

    @Test func earlyAppliedNameWithWidthGrowthOrShrinkIsVerifiedWithoutConfirmOrRollback() throws {
        for delta: CGFloat in [80, -60] {
            let h = try Harness()
            h.onStage = {
                h.resize(width: h.fieldFrame.width + delta)
                h.applyRowName()
            }
            let result = try h.run()
            #expect(result["renamed"] == "true" && result["title"] == Self.requested)
            #expect(h.captures == 1 && h.decisions == 1)
            #expect(h.stages == 1 && h.checkpoints == 1 && h.afterSubmit == 1 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            #expect(try h.field.valueString() == Self.requested)
        }
    }

    @Test func secondRoundStopKeepsThePotentiallyAppliedNameAndRetainsTheCheckpoint() throws {
        for delta: CGFloat in [80, -60] {
            let h = try Harness()
            h.onStage = { h.resize(width: h.fieldFrame.width + delta) }
            h.onDecision = { context in
                AIPlannerStepDecision(step: context.phase == .verify ? .stop : .verify, candidateID: nil)
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.captures == 2 && h.decisions == 2)
            // The synthetic server has accepted the name while this same old
            // desktop row remains cached. The checkpoint must remain uncertain.
            #expect(h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            #expect(try h.field.valueString() == Self.requested)
            #expect(h.serverName == Self.requested)
            let selected = try WeComReader(window: h.window).conversations().filter(\.selected)
            #expect(selected.count == 1 && selected[0].handle == h.row && selected[0].title == Self.original)
            #expect(h.handler.desktopCommandVisualEnd?.outcome == "stop")
        }
    }

    @Test func aWidthChangeDuringPrepareStillFailsBeforeCheckpointOrNameWrite() throws {
        for delta: CGFloat in [80, -60] {
            let h = try Harness()
            h.onDecision = { _ in
                h.resize(width: h.fieldFrame.width + delta)
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.captures == 1 && h.decisions == 1)
            #expect(h.checkpoints == 0 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites.isEmpty)
        }
    }

    @Test func postWritePositionHeightAndInvalidOrEscapingWidthCannotConfirmOrCompensate() throws {
        enum Drift: CaseIterable { case x, y, height, zero, nan, infinity, outsideHeader }
        for drift in Drift.allCases {
            let h = try Harness()
            h.onStage = {
                let original = h.fieldFrame
                let frame: CGRect
                switch drift {
                case .x: frame = original.offsetBy(dx: 12, dy: 0)
                case .y: frame = original.offsetBy(dx: 0, dy: 12)
                case .height:
                    frame = CGRect(x: original.minX, y: original.minY,
                                   width: original.width, height: original.height + 12)
                case .zero:
                    frame = CGRect(x: original.minX, y: original.minY, width: 0, height: original.height)
                case .nan:
                    frame = CGRect(x: original.minX, y: original.minY, width: CGFloat.nan, height: original.height)
                case .infinity:
                    frame = CGRect(x: original.minX, y: original.minY, width: CGFloat.infinity, height: original.height)
                case .outsideHeader:
                    frame = CGRect(x: original.minX, y: original.minY,
                                   width: h.windowFrame.maxX - original.minX + 1, height: original.height)
                }
                h.fake.mutate(h.field.handle, attribute: AXAttribute.frame, to: .rect(frame))
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
        }
    }

    @Test func changedEditorRowWindowPIDOrCompetingEditorCannotConfirmOrCompensate() throws {
        enum Drift: CaseIterable { case fieldHandle, rowHandle, windowFrame, fieldPID, secondField }
        for drift in Drift.allCases {
            let h = try Harness()
            h.onStage = {
                switch drift {
                case .fieldHandle:
                    h.fake.removeChild(h.field.handle, from: h.fieldParent)
                    h.fake.appendChild(to: h.fieldParent, node: AXNode(role: AXRole.textField,
                        value: .string(Self.requested), frame: h.fieldFrame,
                        actions: [AXAction.confirm], settable: [AXAttribute.value, AXAttribute.focused]))
                case .rowHandle:
                    h.fake.mutate(h.row, attribute: AXAttribute.selected, to: .bool(false))
                    h.fake.mutate(h.otherTitle, attribute: AXAttribute.value, to: .string(Self.original))
                    h.fake.mutate(h.otherRow, attribute: AXAttribute.selected, to: .bool(true))
                case .windowFrame:
                    h.fake.mutate(h.window.handle, attribute: AXAttribute.frame,
                                  to: .rect(h.windowFrame.offsetBy(dx: 12, dy: 0)))
                case .fieldPID: h.backend.processOverrides[h.field.handle] = h.fake.pid + 1
                case .secondField:
                    h.fake.appendChild(to: h.window.handle, node: AXNode(role: AXRole.textField,
                        value: .string(Self.requested), frame: h.fieldFrame.offsetBy(dx: 300, dy: 1),
                        settable: [AXAttribute.value]))
                }
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
        }
    }

    @Test func modelStopWithNewRowEvidenceAndAResizedFieldCannotReconcileToSuccess() throws {
        let h = try Harness()
        h.onStage = { h.resize(width: h.fieldFrame.width + 80) }
        h.onDecision = { context in
            if context.phase == .verify {
                h.applyRowName()
                return AIPlannerStepDecision(step: .stop, candidateID: nil)
            }
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        #expect(throws: ControlError.self) { try h.run() }
        // Keep the existing stop + UI-drift rejection. Neither reconciliation
        // nor draft restoration may turn the row change into a second action.
        #expect(h.decisions == 2 && h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
        #expect(h.fieldWrites == [.string(Self.requested)])
        #expect(h.attemptedValueWrites == [.string(Self.requested)])
    }

    @Test func anEarlyAppliedResizedFieldStillCannotBypassPolicyGrantOrSettings() throws {
        enum Revoked: CaseIterable { case policy, screenGrant, settings }
        for revoked in Revoked.allCases {
            let h = try Harness()
            h.onStage = {
                h.resize(width: h.fieldFrame.width + 80)
                h.applyRowName()
                switch revoked {
                case .policy: h.handler.policy.enabled.remove(.renameGroup)
                case .screenGrant: h.handler.visualScreenRecordingGranted = { false }
                case .settings:
                    var disabled = h.settings
                    disabled.disable()
                    h.handler.visualSettingsForCommit = { disabled }
                }
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.decisions == 1 && h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
        }
    }

    @Test func postWriteVetoOrErrorCannotUndoAServerNameHiddenByTheDesktopCache() throws {
        enum Failure: CaseIterable { case stop, timeout, invalidStep, policy, screenGrant, settings }
        for failure in Failure.allCases {
            let h = try Harness()
            h.onStage = { h.resize(width: h.fieldFrame.width + 80) }
            h.onDecision = { context in
                guard context.phase == .verify else {
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                switch failure {
                case .stop: return AIPlannerStepDecision(step: .stop, candidateID: nil)
                case .timeout: throw AIPlannerVisionError.timeout
                case .invalidStep: return AIPlannerStepDecision(step: .writeText, candidateID: "C0")
                case .policy: h.handler.policy.enabled.remove(.renameGroup)
                case .screenGrant: h.handler.visualScreenRecordingGranted = { false }
                case .settings:
                    var disabled = h.settings
                    disabled.disable()
                    h.handler.visualSettingsForCommit = { disabled }
                }
                return AIPlannerStepDecision(step: .verify, candidateID: nil)
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(h.captures == 2 && h.decisions == 2 && h.checkpoints == 1)
            #expect(h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            #expect(h.serverName == Self.requested)
            #expect(try h.field.valueString() == Self.requested)
            let selected = try WeComReader(window: h.window).conversations().filter(\.selected)
            #expect(selected.count == 1 && selected[0].handle == h.row && selected[0].title == Self.original)
        }
    }

    @Test func confirmAPIErrorCannotWriteTheOriginalNameOverTheAcceptedServerName() throws {
        let h = try Harness()
        h.onStage = { h.resize(width: h.fieldFrame.width + 80) }
        h.fake.injectedFailures["action:\(AXAction.confirm)"] = .apiFailure(
            code: -25200, operation: "perform AXConfirm")
        #expect(throws: ControlError.self) { try h.run() }
        // An API failure does not prove the operation was not accepted. The
        // server already changed on AXValue and its desktop row is still old.
        #expect(h.captures == 2 && h.decisions == 2 && h.checkpoints == 1)
        #expect(h.afterSubmit == 0 && h.backend.confirmAttempts == 1)
        #expect(h.fieldWrites == [.string(Self.requested)])
        #expect(h.attemptedValueWrites == [.string(Self.requested)])
        #expect(h.serverName == Self.requested)
        #expect(try WeComReader(window: h.window).activeConversationRow()?.title == Self.original)
    }

    @Test func aFailingCompensationSetterMustNeverEvenBeAttemptedAfterStop() throws {
        let h = try Harness()
        h.onStage = { h.resize(width: h.fieldFrame.width + 80) }
        h.onDecision = { context in
            if context.phase == .verify {
                h.fake.injectedFailures["set:\(AXAttribute.value)"] = .apiFailure(
                    code: -25200, operation: "set AXValue")
                return AIPlannerStepDecision(step: .stop, candidateID: nil)
            }
            return AIPlannerStepDecision(step: .verify, candidateID: nil)
        }
        #expect(throws: ControlError.self) { try h.run() }
        #expect(h.captures == 2 && h.decisions == 2 && h.checkpoints == 1)
        #expect(h.afterSubmit == 0 && h.confirms == 0)
        // recordedSets alone would miss a rejected compensation attempt. The
        // backend records attempts before it delegates to the failing setter.
        #expect(h.fieldWrites == [.string(Self.requested)])
        #expect(h.attemptedValueWrites == [.string(Self.requested)])
        #expect(h.serverName == Self.requested)
        #expect(h.handler.desktopCommandVisualEnd?.outcome == "stop")
    }

    @Test func earlyAppliedEvidenceCannotSurviveAFieldEscapingTheHeaderAfterTheGate() throws {
        for escapeAt in [1, 2] {
            let h = try Harness()
            h.onStage = {
                h.resize(width: h.fieldFrame.width + 80)
                h.applyRowName()
            }
            var escaped = false, postStageReads = 0
            h.handler.visualSettingsForCommit = {
                if h.stages == 1 {
                    postStageReads += 1
                    if postStageReads == escapeAt {
                        escaped = true
                        h.resize(width: h.windowFrame.maxX - h.fieldFrame.minX + 1)
                    }
                }
                return h.settings
            }
            #expect(throws: ControlError.self) { try h.run() }
            #expect(escaped && h.checkpoints == 1 && h.afterSubmit == 0 && h.confirms == 0)
            #expect(h.captures == 1 && h.decisions == 1)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            #expect(h.serverName == Self.requested)
        }
    }

    @Test func confirmCannotUseAnotherSelectedRowWithTheRequestedNameAsItsOwnSuccessEvidence() throws {
        for originalRowWasRenamed in [false, true] {
            let h = try Harness()
            let table = try WeComReader(window: h.window).layout.conversationTable
            h.fake.reactions["action:\(AXAction.confirm)"] = {
                if originalRowWasRenamed { h.applyRowName() }
                h.fake.mutate(h.row, attribute: AXAttribute.selected, to: .bool(false))
                h.fake.mutate(h.otherTitle, attribute: AXAttribute.value, to: .string(Self.requested))
                h.fake.mutate(h.otherRow, attribute: AXAttribute.selected, to: .bool(true))
            }
            // A matching title on a different selected row cannot prove this
            // command's original group. Do not blur that newly selected group
            // to seek more evidence or compensate the potentially applied name.
            #expect(throws: ControlError.unsupported("action 群名输入框 unavailable")) { try h.run() }
            #expect(h.captures == 2 && h.decisions == 2 && h.checkpoints == 1)
            #expect(h.afterSubmit == 1 && h.confirms == 1 && h.backend.confirmAttempts == 1)
            #expect(h.fieldWrites == [.string(Self.requested)])
            #expect(h.attemptedValueWrites == [.string(Self.requested)])
            #expect(h.serverName == Self.requested)
            #expect(h.fake.recordedSets.filter {
                $0.handle == table.handle && $0.attribute == AXAttribute.focused
            }.isEmpty)
            let selected = try WeComReader(window: h.window).conversations().filter(\.selected)
            #expect(selected.count == 1 && selected[0].handle == h.otherRow && selected[0].title == Self.requested)
        }
    }
}

private final class ResizeBackend: AXBackend {
    let name = "fake"
    let base: FakeAXBackend
    var processOverrides: [AXElementHandle: pid_t] = [:]
    var valueWriteAttempts: [(handle: AXElementHandle, value: AXAttributeValue)] = []
    var confirmAttempts = 0
    init(_ base: FakeAXBackend) { self.base = base }
    func isProcessTrusted(prompt: Bool) -> Bool { base.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { base.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try base.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        try base.attribute(name, of: element)
    }
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        try base.isAttributeSettable(name, of: element)
    }
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        if name == AXAttribute.value { valueWriteAttempts.append((element, value)) }
        try base.setAttribute(name, to: value, of: element)
    }
    func actionNames(of element: AXElementHandle) throws -> [String] { try base.actionNames(of: element) }
    func performAction(_ name: String, on element: AXElementHandle) throws {
        if name == AXAction.confirm { confirmAttempts += 1 }
        try base.performAction(name, on: element)
    }
    func pid(of element: AXElementHandle) throws -> pid_t { try processOverrides[element] ?? base.pid(of: element) }
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try base.makeObserver(pid: pid, handler: handler)
    }
}

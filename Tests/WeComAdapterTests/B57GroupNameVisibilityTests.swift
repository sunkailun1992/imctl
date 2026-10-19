import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B57 group-name visible-window preparation")
struct B57GroupNameVisibilityTests {
    private enum BodyError: Error { case synthetic }

    private final class Harness {
        let fake: FakeAXBackend
        let backend: GroupNameVisibilityBackend
        let app: AXElement
        let window: AXElement
        let indicator: AXElement
        let field: AXElement
        let row: ConversationRow
        let rowTitle: AXElementHandle
        let target: ResolvedTarget
        let handler: WeComCommandHandler
        var settings: CloudVisionSettings
        var granted = true
        var enabled = true
        var paused = false
        var restored: [pid_t] = []

        init(visible: Bool = false, sharingIndicator: Bool = true,
             frontmostSettable: Bool = true) throws {
            var main = try AXNode.load(from: Fixtures.root
                .appendingPathComponent("wecom-5.0.11-external-group.json"))
            main.subrole = "AXStandardWindow"
            let frame = try #require(main.frame?.cgRect)
            let accessory = AXNode(role: AXRole.window, subrole: "AXDialog",
                frame: CGRect(x: frame.minX + 12, y: frame.minY + 4, width: 66, height: 20),
                children: [AXNode(role: AXRole.button, title: "WindowSharingSessionButton",
                    frame: CGRect(x: frame.minX + 11, y: frame.minY + 3, width: 68, height: 22),
                    actions: [AXAction.press], settable: [AXAttribute.focused])])
            let fake = FakeAXBackend(root: AXNode(role: AXRole.application,
                settable: frontmostSettable ? [AXAttribute.frontmost] : [],
                children: [main, accessory]))
            let backend = GroupNameVisibilityBackend(fake)
            backend.visible = visible
            self.fake = fake
            self.backend = backend
            app = AXElement(handle: fake.rootHandle, backend: backend)
            window = AXElement(handle: try #require(fake.handle(atPath: [0])), backend: backend)
            indicator = AXElement(handle: try #require(fake.handle(atPath: [1])), backend: backend)
            if !sharingIndicator {
                fake.mutate(fake.rootHandle, attribute: AXAttribute.windows, to: .elements([window.handle]))
            }
            let reader = try WeComReader(window: window)
            field = try #require(reader.layout.activeTitle)
            row = try #require(try reader.activeConversationRow())
            rowTitle = try #require(row.handle.titleTextHandle(in: fake))
            target = ResolvedTarget(title: try #require(row.title), type: .group)
            let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("imctl-b57-\(UUID().uuidString)"))
            handler = WeComCommandHandler(rootProvider: {
                AXElement(handle: fake.rootHandle, backend: backend.rootBackendOverride ?? backend)
            }, policy: ActionPolicy(allowedTargets: [target.title], enabled: [.renameGroup], phase: .phase1),
               checkpoints: checkpoints)
            settings = try AIPlannerVisionClientTests.settings()
            handler.desktopCommandOrigin = .external
            handler.desktopCommandMethod = .groupRename
            handler.visualEnabled = { [unowned self] in self.enabled }
            handler.visualScreenRecordingGranted = { [unowned self] in self.granted }
            handler.visualSettingsForCommit = { [unowned self] in self.settings }
            handler.visualCommandGate = { [unowned self] in
                if self.paused { throw AIPlannerVisionError.disabled }
            }
            handler.visualSelect = { _, _, _, _, _, _ in
                Issue.record("Visibility preparation must not request a model selection")
                return nil
            }
        }

        func actions(observeGroupName: Bool = true) -> WeComActions {
            var actions = handler.actions(for: target)
            actions.verifyTimeout = 0.03
            actions.verifyInterval = 0.001
            actions.frontmostPid = { 9999 }
            actions.restoreFrontmost = { [unowned self] in self.restored.append($0) }
            if observeGroupName {
                actions.visualObserveGroupName = { _, _, _, _ in
                    Issue.record("The visibility helper must not perform the B37 observation itself")
                }
            }
            return actions
        }

        func verifyExistingWindowGuard(_ supplied: AXElement) throws {
            let reader = try WeComReader(window: supplied)
            try WeComCommandHandler.verifyGroupNameWindowSet(app: app, window: supplied, pid: fake.pid,
                frame: reader.layout.windowFrame, fieldFrame: try #require(try field.frame()),
                conversationTableFrame: try #require(try reader.layout.conversationTable.frame()),
                viewportFrame: try #require(try reader.layout.messageViewportFrame()))
        }

        func expectOnlyFrontmostWrite(_ count: Int) {
            #expect(fake.recordedActions.isEmpty)
            #expect(fake.recordedSets.count == count)
            #expect(fake.recordedSets.allSatisfy {
                $0.handle == app.handle && $0.attribute == AXAttribute.frontmost && $0.value == .bool(true)
            })
        }
    }

    @Test func emptyWindowListBecomesTheSameMainWindowBeforeTheExistingB55Guard() throws {
        for sharingIndicator in [false, true] {
            for provider in [CloudVisionProvider.qwen, .gemini] {
                let h = try Harness(sharingIndicator: sharingIndicator)
                h.settings = try AIPlannerVisionClientTests.settings(provider)
                h.backend.revealAfterReads = 2
                #expect(throws: AIPlannerVisionError.staleView) { try h.verifyExistingWindowGuard(h.window) }
                var bodies = 0
                let result = try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { window in
                    bodies += 1
                    #expect(window.handle == h.window.handle && window.backend === h.backend)
                    #expect(h.backend.activatedWindowReads >= 2)
                    #expect(h.restored.isEmpty)
                    try h.verifyExistingWindowGuard(window)
                    return "body-result"
                }
                #expect(result == "body-result" && bodies == 1)
                #expect(h.backend.activationAttempts == 1 && h.restored == [9999])
                h.expectOnlyFrontmostWrite(1)
            }
        }
    }

    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot? {
        guard let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(origin: .zero, size: frame.size))
        guard let image = context.makeImage() else { return nil }
        return WeComWindowScreenshot(image: image, windowFrame: frame)
    }

    @Test func handlerRestoresVisibilityBeforeItsOriginalB37ObservationAndCheckpoint() throws {
        for stopBeforeStaging in [true, false] {
            let h = try Harness()
            let requested = "B57 synthetic name"
            h.backend.revealAfterReads = 2
            h.handler.configureActions = { actions in
                actions.verifyTimeout = 0.03
                actions.verifyInterval = 0.001
                actions.frontmostPid = { 9999 }
                actions.restoreFrontmost = { h.restored.append($0) }
            }
            var captures = 0, checkpoints = 0, after = 0
            var phases: [AIPlannerPhase] = []
            h.handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try h.handler.beginVisualRound() },
                    settingsProvider: { h.settings }, capture: { _, frame in
                        captures += 1
                        #expect(h.backend.visible && h.backend.activationAttempts == 1)
                        #expect(h.restored.isEmpty)
                        return Self.shot(frame)
                    }, decide: { _, context, _ in
                        try h.verifyExistingWindowGuard(h.window)
                        #expect(context.method == .groupRename && h.restored.isEmpty)
                        phases.append(context.phase)
                        return AIPlannerStepDecision(step: stopBeforeStaging ? .stop : .verify, candidateID: nil)
                    })
            }
            h.fake.reactions["action:\(AXAction.confirm)"] = {
                #expect(checkpoints == 1 && h.restored.isEmpty)
                h.fake.mutate(h.rowTitle, attribute: AXAttribute.value, to: .string(requested))
            }
            let checkpoint = {
                checkpoints += 1
                #expect(h.restored.isEmpty)
                #expect(h.fake.recordedSets.filter {
                    $0.handle == h.field.handle && $0.attribute == AXAttribute.value
                }.isEmpty)
            }
            if stopBeforeStaging {
                #expect(throws: ControlError.self) {
                    try h.handler.groupRename(target: h.target.title, name: requested,
                        checkpoint: checkpoint, afterSubmit: { after += 1 })
                }
                #expect(captures == 1 && phases == [.prepare] && checkpoints == 0 && after == 0)
                #expect(h.handler.desktopCommandVisualEnd?.outcome == "stop")
                #expect(h.handler.desktopCommandVisualEnd?.phase == "prepare")
                #expect(h.fake.recordedSets.filter {
                    $0.handle == h.field.handle && $0.attribute == AXAttribute.value
                }.isEmpty)
                #expect(h.fake.recordedActions.isEmpty)
                #expect(try WeComReader(window: h.window).activeConversationRow()?.title == h.target.title)
            } else {
                let result = try h.handler.groupRename(target: h.target.title, name: requested,
                    checkpoint: checkpoint, afterSubmit: { after += 1 })
                #expect(result["renamed"] == "true" && result["title"] == requested)
                #expect(captures == 2 && phases == [.prepare, .verify] && checkpoints == 1 && after == 1)
                #expect(h.fake.recordedSets.filter {
                    $0.handle == h.field.handle && $0.attribute == AXAttribute.value
                }.map(\.value) == [.string(requested)])
                #expect(h.fake.recordedActions.count == 1)
                #expect(h.fake.recordedActions.first?.handle == h.field.handle)
                #expect(h.fake.recordedActions.first?.action == AXAction.confirm)
                #expect(try WeComReader(window: h.window).activeConversationRow()?.title == requested)
            }
            #expect(h.backend.activationAttempts == 1 && h.restored == [9999])
            #expect(h.fake.recordedSets.first?.handle == h.app.handle)
            #expect(h.fake.recordedSets.first?.attribute == AXAttribute.frontmost)
            #expect(h.fake.recordedSets.filter {
                $0.handle == h.app.handle && $0.attribute == AXAttribute.frontmost && $0.value == .bool(true)
            }.count == 1)
        }
    }

    @Test func handlerSecondRoundStopCannotCompensateTheNameOrRestoreFocus() throws {
        let h = try Harness()
        let requested = "B57 stopped staged name"
        h.backend.revealAfterReads = 2
        h.handler.configureActions = { actions in
            actions.verifyTimeout = 0.03
            actions.verifyInterval = 0.001
            actions.frontmostPid = { 9999 }
            actions.restoreFrontmost = { h.restored.append($0) }
        }
        var captures = 0, checkpoints = 0, after = 0
        var phases: [AIPlannerPhase] = []
        h.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.handler.beginVisualRound() },
                settingsProvider: { h.settings }, capture: { _, frame in
                    captures += 1
                    #expect(h.backend.visible && h.backend.activationAttempts == 1 && h.restored.isEmpty)
                    return Self.shot(frame)
                }, decide: { _, context, _ in
                    try h.verifyExistingWindowGuard(h.window)
                    phases.append(context.phase)
                    return AIPlannerStepDecision(step: context.phase == .prepare ? .verify : .stop,
                                                 candidateID: nil)
                })
        }
        #expect(throws: ControlError.self) {
            try h.handler.groupRename(target: h.target.title, name: requested,
                checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
        }
        #expect(captures == 2 && phases == [.prepare, .verify] && checkpoints == 1 && after == 0)
        #expect(h.handler.desktopCommandVisualEnd?.outcome == "stop")
        #expect(h.handler.desktopCommandVisualEnd?.phase == "verify")
        #expect(try h.field.valueString() == requested)
        #expect(try WeComReader(window: h.window).activeConversationRow()?.title == h.target.title)
        #expect(h.fake.recordedSets.filter {
            $0.handle == h.field.handle && $0.attribute == AXAttribute.value
        }.map(\.value) == [.string(requested)])
        #expect(h.fake.recordedActions.isEmpty)
        #expect(h.backend.activationAttempts == 1 && h.restored.isEmpty)
    }

    @Test func handlerCheckpointCallbackFailureCannotRestoreFocus() throws {
        let h = try Harness()
        let requested = "B57 checkpoint failure name"
        let failure = ControlError.internalError("synthetic checkpoint failure")
        h.backend.revealAfterReads = 2
        h.handler.configureActions = { actions in
            actions.verifyTimeout = 0.03
            actions.verifyInterval = 0.001
            actions.frontmostPid = { 9999 }
            actions.restoreFrontmost = { h.restored.append($0) }
        }
        var captures = 0, checkpoints = 0, after = 0
        var phases: [AIPlannerPhase] = []
        h.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.handler.beginVisualRound() },
                settingsProvider: { h.settings }, capture: { _, frame in
                    captures += 1
                    #expect(h.backend.visible && h.backend.activationAttempts == 1 && h.restored.isEmpty)
                    return Self.shot(frame)
                }, decide: { _, context, _ in
                    try h.verifyExistingWindowGuard(h.window)
                    phases.append(context.phase)
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                })
        }
        #expect(throws: failure) {
            try h.handler.groupRename(target: h.target.title, name: requested, checkpoint: {
                checkpoints += 1
                throw failure
            }, afterSubmit: { after += 1 })
        }
        #expect(captures == 1 && phases == [.prepare] && checkpoints == 1 && after == 0)
        #expect(try h.field.valueString() == h.target.title)
        #expect(try WeComReader(window: h.window).activeConversationRow()?.title == h.target.title)
        #expect(h.fake.recordedSets.filter {
            $0.handle == h.field.handle && $0.attribute == AXAttribute.value
        }.isEmpty)
        #expect(h.fake.recordedActions.isEmpty)
        #expect(h.backend.activationAttempts == 1 && h.restored.isEmpty)
    }

    @Test func handlerAfterSubmitCrashCannotRestoreFocus() throws {
        let h = try Harness()
        let requested = "B57 submitted crash name"
        h.backend.revealAfterReads = 2
        h.handler.configureActions = { actions in
            actions.verifyTimeout = 0.03
            actions.verifyInterval = 0.001
            actions.frontmostPid = { 9999 }
            actions.restoreFrontmost = { h.restored.append($0) }
        }
        var captures = 0, checkpoints = 0, after = 0
        var phases: [AIPlannerPhase] = []
        h.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.handler.beginVisualRound() },
                settingsProvider: { h.settings }, capture: { _, frame in
                    captures += 1
                    #expect(h.backend.visible && h.backend.activationAttempts == 1 && h.restored.isEmpty)
                    return Self.shot(frame)
                }, decide: { _, context, _ in
                    try h.verifyExistingWindowGuard(h.window)
                    phases.append(context.phase)
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                })
        }
        h.fake.reactions["action:\(AXAction.confirm)"] = {
            #expect(checkpoints == 1 && after == 0 && h.restored.isEmpty)
            h.fake.mutate(h.rowTitle, attribute: AXAttribute.value, to: .string(requested))
        }
        #expect(throws: CrashInjected.self) {
            try h.handler.groupRename(target: h.target.title, name: requested,
                checkpoint: { checkpoints += 1 }, afterSubmit: {
                    after += 1
                    throw CrashInjected()
                })
        }
        #expect(captures == 2 && phases == [.prepare, .verify] && checkpoints == 1 && after == 1)
        #expect(try h.field.valueString() == requested)
        #expect(try WeComReader(window: h.window).activeConversationRow()?.title == requested)
        #expect(h.fake.recordedSets.filter {
            $0.handle == h.field.handle && $0.attribute == AXAttribute.value
        }.map(\.value) == [.string(requested)])
        #expect(h.fake.recordedActions.count == 1)
        #expect(h.fake.recordedActions.first?.handle == h.field.handle)
        #expect(h.fake.recordedActions.first?.action == AXAction.confirm)
        #expect(h.backend.activationAttempts == 1 && h.restored.isEmpty)
    }

    @Test func alreadyVisibleWindowDoesNotChangeFrontmostOrRestoreFocus() throws {
        let h = try Harness(visible: true)
        var bodies = 0
        try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { window in
            bodies += 1
            try h.verifyExistingWindowGuard(window)
        }
        #expect(bodies == 1 && h.backend.activationAttempts == 0 && h.restored.isEmpty)
        h.expectOnlyFrontmostWrite(0)
    }

    @Test func nonB37CommandsKeepTheirExistingPathWithoutActivation() throws {
        enum Scope: CaseIterable { case automation, otherMethod, missingObservation }
        for scope in Scope.allCases {
            let h = try Harness()
            var actions = h.actions()
            switch scope {
            case .automation: h.handler.desktopCommandOrigin = .automation
            case .otherMethod: h.handler.desktopCommandMethod = .groupCreate
            case .missingObservation: actions.visualObserveGroupName = nil
            }
            var bodies = 0
            try h.handler.withVisibleGroupNameWindow(target: h.target, actions: actions) { window in
                bodies += 1
                #expect(window.handle == h.window.handle)
            }
            #expect(bodies == 1 && h.backend.activationAttempts == 0 && h.restored.isEmpty)
            h.expectOnlyFrontmostWrite(0)
        }
    }

    @Test func legacyWindowOnlyFixtureDoesNotActivateTheApplication() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root
            .appendingPathComponent("wecom-5.0.11-external-group.json")))
        let reader = try WeComReader(window: fake.rootElement)
        let target = ResolvedTarget(title: try #require(try reader.activeConversationTitle()), type: .group)
        let store = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b57-window-only-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [target.title], enabled: [.renameGroup], phase: .phase1),
            checkpoints: store)
        handler.desktopCommandOrigin = .external
        handler.desktopCommandMethod = .groupRename
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in nil }
        var actions = handler.actions(for: target)
        actions.visualObserveGroupName = { _, _, _, _ in Issue.record("No model observation expected") }
        actions.frontmostPid = { Issue.record("Window-only fixtures must not inspect workspace focus"); return nil }
        actions.restoreFrontmost = { _ in Issue.record("Window-only fixtures must not restore workspace focus") }
        var bodies = 0
        try handler.withVisibleGroupNameWindow(target: target, actions: actions) { window in
            bodies += 1
            #expect(window.handle == fake.rootHandle)
        }
        #expect(bodies == 1 && fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func aWindowListThatRemainsEmptyNeverCallsTheBodyAndRestoresFocus() throws {
        let h = try Harness()
        h.backend.neverReveal = true
        var bodies = 0
        #expect(throws: (any Error).self) {
            try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
        }
        #expect(bodies == 0 && h.backend.activationAttempts == 1 && h.restored == [9999])
        h.expectOnlyFrontmostWrite(1)
    }

    @Test func unsettableOrFailedFrontmostNeverCallsTheBody() throws {
        for settable in [false, true] {
            let h = try Harness(frontmostSettable: settable)
            if settable { h.fake.injectedFailures["set:\(AXAttribute.frontmost)"] = .cannotComplete("synthetic frontmost failure") }
            var bodies = 0
            #expect(throws: (any Error).self) {
                try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
            }
            #expect(bodies == 0 && h.backend.activationAttempts <= 1)
            h.expectOnlyFrontmostWrite(0)
            if settable { #expect(h.restored == [9999]) }
        }
    }

    @Test func onlyAnExplicitEmptyAXWindowsArrayCanTriggerActivation() throws {
        for reply in GroupNameVisibilityBackend.InvalidWindows.allCases {
            let h = try Harness()
            h.backend.invalidWindows = reply
            var bodies = 0
            #expect(throws: (any Error).self) {
                try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
            }
            #expect(bodies == 0 && h.backend.activationAttempts == 0 && h.restored.isEmpty)
            h.expectOnlyFrontmostWrite(0)
        }
    }

    @Test func unknownOrMalformedWindowRepliesWhileWaitingAreRejected() throws {
        for reply in GroupNameVisibilityBackend.InvalidWindows.allCases {
            let h = try Harness()
            h.backend.onActivatedWindowRead = { _ in h.backend.invalidWindows = reply }
            var bodies = 0
            #expect(throws: (any Error).self) {
                try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
            }
            #expect(bodies == 0 && h.backend.activationAttempts == 1 && h.restored == [9999])
            h.expectOnlyFrontmostWrite(1)
        }
    }

    @Test func missingVisualActionGateCannotActivateAnEmptyWindowList() throws {
        let h = try Harness()
        var actions = h.actions()
        actions.visualActionGate = nil
        var bodies = 0
        #expect(throws: (any Error).self) {
            try h.handler.withVisibleGroupNameWindow(target: h.target, actions: actions) { _ in bodies += 1 }
        }
        #expect(bodies == 0 && h.backend.activationAttempts == 0)
        h.expectOnlyFrontmostWrite(0)
    }

    private enum Drift: CaseIterable {
        case mainWindow, focusedWindow, selectedHandle, selectedTitle, headerTitle, windowFrame
        case appPID, windowPID, selectedPID, backend
    }

    private static func drift(_ drift: Drift, in h: Harness) throws {
        switch drift {
        case .mainWindow:
            h.fake.mutate(h.app.handle, attribute: AXAttribute.mainWindow, to: .element(h.indicator.handle))
        case .focusedWindow:
            h.fake.mutate(h.app.handle, attribute: AXAttribute.focusedWindow, to: .element(h.indicator.handle))
        case .selectedHandle:
            let table = try WeComReader(window: h.window).layout.conversationTable
            let replacement = AXNode(role: AXRole.row, frame: h.row.frame, selected: true,
                children: [AXNode(role: AXRole.cell, frame: h.row.frame,
                    children: [AXNode(role: AXRole.staticText, value: .string(h.target.title),
                        frame: CGRect(x: h.row.frame.minX + 40, y: h.row.frame.minY + 8, width: 100, height: 20))])])
            h.fake.mutate(h.row.handle, attribute: AXAttribute.selected, to: .bool(false))
            _ = try #require(h.fake.appendChild(to: table.handle, node: replacement))
        case .selectedTitle:
            h.fake.mutate(h.rowTitle, attribute: AXAttribute.value, to: .string("Other synthetic group"))
        case .headerTitle:
            h.fake.mutate(h.field.handle, attribute: AXAttribute.value, to: .string("Other synthetic group(3)"))
        case .windowFrame:
            let frame = try #require(try h.window.frame())
            h.fake.mutate(h.window.handle, attribute: AXAttribute.frame, to: .rect(frame.offsetBy(dx: 10, dy: 0)))
        case .appPID: h.backend.pidOverrides[h.app.handle] = h.fake.pid + 1
        case .windowPID: h.backend.pidOverrides[h.window.handle] = h.fake.pid + 1
        case .selectedPID: h.backend.pidOverrides[h.row.handle] = h.fake.pid + 1
        case .backend: h.backend.rootBackendOverride = h.fake
        }
    }

    @Test func activationAndVisibilityWaitBothRejectFrozenWindowOrTargetDrift() throws {
        for drift in Drift.allCases {
            for changeAt in [1, 2] {
                let h = try Harness()
                h.backend.revealAfterReads = 2
                h.backend.onActivatedWindowRead = { count in
                    if count == changeAt { try Self.drift(drift, in: h) }
                }
                var bodies = 0
                #expect(throws: (any Error).self) {
                    try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
                }
                #expect(bodies == 0 && h.backend.activationAttempts == 1 && h.restored == [9999])
                h.expectOnlyFrontmostWrite(1)
            }
        }
    }

    private enum Revocation: CaseIterable {
        case policy, targetAllowlist, permission, screenGrant, enabled, selector, cloud, fullWindow
        case provider, key, pause, budget
    }

    private static func revoke(_ revocation: Revocation, in h: Harness) throws {
        switch revocation {
        case .policy: h.handler.policy.enabled.remove(.renameGroup)
        case .targetAllowlist: h.handler.policy.allowedTargets.remove(h.target.title)
        case .permission: h.fake.trusted = false
        case .screenGrant: h.granted = false
        case .enabled: h.enabled = false
        case .selector: h.handler.visualSelect = nil
        case .cloud: h.settings.disable()
        case .fullWindow: try h.settings.setFullWindowEnabled(false)
        case .provider: h.settings = try AIPlannerVisionClientTests.settings(.gemini)
        case .key: h.settings.removeAPIKey(for: .qwen)
        case .pause: h.paused = true
        case .budget: h.handler.maxVisualDuration = -1
        }
    }

    @Test func authorizationRevokedDuringEitherWaitReadCannotReachTheBody() throws {
        for revocation in Revocation.allCases {
            for changeAt in [1, 2] {
                let h = try Harness()
                h.backend.revealAfterReads = 2
                h.backend.onActivatedWindowRead = { count in
                    if count == changeAt { try Self.revoke(revocation, in: h) }
                }
                var bodies = 0
                #expect(throws: (any Error).self) {
                    try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { _ in bodies += 1 }
                }
                #expect(bodies == 0 && h.backend.activationAttempts == 1 && h.restored == [9999])
                h.expectOnlyFrontmostWrite(1)
            }
        }
    }

    @Test func initialRevocationRejectsBeforeTheFrontmostWrite() throws {
        // A different, valid provider at entry is a new snapshot, not a revocation.
        for revocation in Revocation.allCases where revocation != .provider {
            let h = try Harness()
            let actions = h.actions()
            try Self.revoke(revocation, in: h)
            var bodies = 0
            #expect(throws: (any Error).self) {
                try h.handler.withVisibleGroupNameWindow(target: h.target, actions: actions) { _ in bodies += 1 }
            }
            #expect(bodies == 0 && h.backend.activationAttempts == 0 && h.restored.isEmpty)
            h.expectOnlyFrontmostWrite(0)
        }
    }

    @Test func bodyFailureStillRestoresTheOriginalFrontmostApplication() throws {
        let h = try Harness()
        var bodies = 0
        #expect(throws: BodyError.self) {
            try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { window in
                bodies += 1
                try h.verifyExistingWindowGuard(window)
                #expect(h.restored.isEmpty)
                throw BodyError.synthetic
            }
        }
        #expect(bodies == 1 && h.backend.activationAttempts == 1 && h.restored == [9999])
        h.expectOnlyFrontmostWrite(1)
    }

    @Test func newlyVisibleUnknownDialogsStillFailTheOriginalWindowSetGuard() throws {
        for sharingIndicator in [false, true] {
            let h = try Harness(sharingIndicator: sharingIndicator)
            h.backend.onActivatedWindowRead = { count in
                guard count == 1 else { return }
                let dialog = AXNode(role: AXRole.window, subrole: "AXDialog",
                    frame: CGRect(x: 300, y: 200, width: 500, height: 400),
                    children: [AXNode(role: AXRole.button, title: "Unknown synthetic dialog")])
                let extra = try #require(h.fake.appendChild(to: h.app.handle, node: dialog))
                let windows = [h.window.handle] + (sharingIndicator ? [h.indicator.handle] : []) + [extra]
                h.fake.mutate(h.app.handle, attribute: AXAttribute.windows, to: .elements(windows))
            }
            #expect(throws: (any Error).self) {
                try h.handler.withVisibleGroupNameWindow(target: h.target, actions: h.actions()) { window in
                    try h.verifyExistingWindowGuard(window)
                }
            }
            #expect(h.backend.activationAttempts == 1 && h.restored == [9999])
            h.expectOnlyFrontmostWrite(1)
        }
    }
}

/// Models a main window on another Space without any workspace or live AX use.
private final class GroupNameVisibilityBackend: AXBackend {
    enum InvalidWindows: CaseIterable { case missing, unsupported, string, scalarElement, failure }
    let name = "fake"
    let base: FakeAXBackend
    var visible = false
    var neverReveal = false
    var revealAfterReads = 1
    var invalidWindows: InvalidWindows?
    var activationAttempts = 0
    var activatedWindowReads = 0
    var onActivatedWindowRead: ((Int) throws -> Void)?
    var pidOverrides: [AXElementHandle: pid_t] = [:]
    var rootBackendOverride: AXBackend?

    init(_ base: FakeAXBackend) { self.base = base }
    func isProcessTrusted(prompt: Bool) -> Bool { base.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { base.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try base.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        guard element == base.rootHandle, name == AXAttribute.windows else {
            return try base.attribute(name, of: element)
        }
        if activationAttempts > 0 {
            activatedWindowReads += 1
            try onActivatedWindowRead?(activatedWindowReads)
            if !neverReveal && activatedWindowReads >= revealAfterReads { visible = true }
        }
        switch invalidWindows {
        case .missing: return nil
        case .unsupported: throw AXKitError.attributeUnsupported(AXAttribute.windows)
        case .string: return .string("synthetic invalid AXWindows")
        case .scalarElement: return .element(base.rootHandle)
        case .failure: throw AXKitError.cannotComplete("synthetic AXWindows failure")
        case nil: return visible ? try base.attribute(name, of: element) : .elements([])
        }
    }
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        try base.isAttributeSettable(name, of: element)
    }
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        if element == base.rootHandle && name == AXAttribute.frontmost { activationAttempts += 1 }
        try base.setAttribute(name, to: value, of: element)
    }
    func actionNames(of element: AXElementHandle) throws -> [String] { try base.actionNames(of: element) }
    func performAction(_ name: String, on element: AXElementHandle) throws { try base.performAction(name, on: element) }
    func pid(of element: AXElementHandle) throws -> pid_t { try pidOverrides[element] ?? base.pid(of: element) }
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try base.makeObserver(pid: pid, handler: handler)
    }
}

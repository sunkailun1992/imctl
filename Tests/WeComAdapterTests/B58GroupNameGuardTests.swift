import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B58 fixed group-name guard diagnostics")
struct B58GroupNameGuardTests {
    private static let mainFrame = CGRect(x: 0, y: 30, width: 1920, height: 1170)
    private static let fieldFrame = CGRect(x: 326, y: 50, width: 223, height: 24)
    private static let tableFrame = CGRect(x: 59, y: 93, width: 252, height: 1108)
    private static let viewport = CGRect(x: 310, y: 109, width: 1450, height: 892)
    private static let targetMarker = "B58-target-private-marker"
    private static let requestedMarker = "B58-request-private-marker"
    private static let keyMarker = "B58-key-private-marker"
    private static let rowMarker = "B58-row-private-marker"

    private final class WindowHarness {
        let fake: FakeAXBackend
        let backend: GuardDiagnosticBackend
        let app: AXElement
        let window: AXElement
        let indicator: AXElement
        let button: AXElement

        init(includeIndicator: Bool = true) throws {
            let frame = B58GroupNameGuardTests.mainFrame
            let main = AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: frame)
            let accessory = AXNode(role: AXRole.window, subrole: "AXDialog",
                frame: CGRect(x: 12, y: 34, width: 66, height: 20),
                children: [AXNode(role: AXRole.button, title: "WindowSharingSessionButton",
                    frame: CGRect(x: 11, y: 33, width: 68, height: 22))])
            let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [main, accessory]))
            let backend = GuardDiagnosticBackend(fake)
            self.fake = fake
            self.backend = backend
            app = AXElement(handle: fake.rootHandle, backend: backend)
            window = AXElement(handle: try #require(fake.handle(atPath: [0])), backend: backend)
            indicator = AXElement(handle: try #require(fake.handle(atPath: [1])), backend: backend)
            button = AXElement(handle: try #require(fake.handle(atPath: [1, 0])), backend: backend)
            fake.mutate(fake.rootHandle, attribute: AXAttribute.windows,
                to: .elements([window.handle] + (includeIndicator ? [indicator.handle] : [])))
        }

        func verify(window override: AXElement? = nil, field: CGRect = B58GroupNameGuardTests.fieldFrame,
                    onRejection: ((GroupNameVisualGuard) -> Void)? = nil) throws {
            try WeComCommandHandler.verifyGroupNameWindowSet(app: app, window: override ?? window,
                pid: fake.pid, frame: B58GroupNameGuardTests.mainFrame, fieldFrame: field,
                conversationTableFrame: B58GroupNameGuardTests.tableFrame,
                viewportFrame: B58GroupNameGuardTests.viewport, onRejection: onRejection)
        }

        func expectReadOnly() {
            #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        }
    }

    @Test func successfulWindowChecksDoNotEmitRejectionsOrAXMutations() throws {
        for includeIndicator in [false, true] {
            let h = try WindowHarness(includeIndicator: includeIndicator)
            var reasons: [GroupNameVisualGuard] = []
            try h.verify(onRejection: { reasons.append($0) })
            try h.verify()
            #expect(reasons.isEmpty)
            h.expectReadOnly()
        }
    }

    @Test func existingB55RejectionsKeepStaleViewAndEmitOneFixedReason() throws {
        enum Drift: CaseIterable {
            case process, backend, frame, windowsEmpty, windowsExtra, mainWindow, focusedWindow
            case indicatorRole, indicatorFrame, childCount, buttonTitle, overlap
            var reason: GroupNameVisualGuard {
                switch self {
                case .process, .backend, .frame, .focusedWindow: return .identity
                case .windowsEmpty, .windowsExtra, .mainWindow: return .windowSetCount
                case .indicatorRole, .indicatorFrame: return .indicatorShape
                case .childCount, .buttonTitle: return .indicatorButton
                case .overlap: return .accessoryOverlap
                }
            }
        }
        for drift in Drift.allCases {
            let h = try WindowHarness()
            var window: AXElement?
            var field = Self.fieldFrame
            switch drift {
            case .process: h.backend.processOverrides[h.window.handle] = h.fake.pid + 1
            case .backend: window = AXElement(handle: h.window.handle, backend: h.fake)
            case .frame: h.fake.mutate(h.window.handle, attribute: AXAttribute.frame, to: .rect(.zero))
            case .windowsEmpty: h.fake.mutate(h.app.handle, attribute: AXAttribute.windows, to: .elements([]))
            case .windowsExtra:
                let extra = try #require(h.fake.appendChild(to: h.app.handle,
                    node: AXNode(role: AXRole.window, frame: CGRect(x: 500, y: 300, width: 200, height: 100))))
                h.fake.mutate(h.app.handle, attribute: AXAttribute.windows,
                    to: .elements([h.window.handle, h.indicator.handle, extra]))
            case .mainWindow:
                h.fake.mutate(h.app.handle, attribute: AXAttribute.mainWindow, to: .element(h.indicator.handle))
            case .focusedWindow:
                h.fake.mutate(h.app.handle, attribute: AXAttribute.focusedWindow, to: .element(h.indicator.handle))
            case .indicatorRole: h.fake.mutate(h.indicator.handle, attribute: AXAttribute.role, to: .string(AXRole.group))
            case .indicatorFrame:
                h.fake.mutate(h.indicator.handle, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 12, y: 34, width: 100, height: 20)))
            case .childCount:
                h.fake.appendChild(to: h.indicator.handle, node: AXNode(role: AXRole.button, title: Self.rowMarker))
            case .buttonTitle: h.fake.mutate(h.button.handle, attribute: AXAttribute.title, to: .string(Self.rowMarker))
            case .overlap: field = CGRect(x: 50, y: 40, width: 100, height: 20)
            }
            var reasons: [GroupNameVisualGuard] = []
            #expect(throws: AIPlannerVisionError.staleView) {
                try h.verify(window: window, field: field, onRejection: { reasons.append($0) })
            }
            #expect(reasons == [drift.reason])
            h.expectReadOnly()
        }
    }

    @Test func AXReadFailuresRetainTheirOriginalErrorWithoutAClassifierCallback() throws {
        let h = try WindowHarness()
        let failure = AXKitError.cannotComplete("synthetic AXWindows read failure")
        h.fake.injectedFailures["get:\(AXAttribute.windows)"] = failure
        var reasons: [GroupNameVisualGuard] = []
        #expect(throws: failure) { try h.verify(onRejection: { reasons.append($0) }) }
        #expect(reasons.isEmpty)
        h.expectReadOnly()
    }

    private final class HandlerHarness {
        let fake: FakeAXBackend
        let backend: GuardDiagnosticBackend
        let app: AXElement
        let window: AXElement
        let field: AXElement
        let fieldFrame: CGRect
        let handler: WeComCommandHandler
        var beforeFirstGate: (() -> Void)?
        var injected = false
        var captures = 0
        var decisions = 0

        init() throws {
            var main = try AXNode.load(from: Fixtures.root
                .appendingPathComponent("wecom-5.0.11-external-group.json"))
            main.subrole = "AXStandardWindow"
            let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [main]))
            let backend = GuardDiagnosticBackend(fake)
            self.fake = fake
            self.backend = backend
            app = AXElement(handle: fake.rootHandle, backend: backend)
            window = AXElement(handle: try #require(fake.handle(atPath: [0])), backend: backend)
            let reader = try WeComReader(window: window)
            field = try #require(reader.layout.activeTitle)
            fieldFrame = try #require(try field.frame())
            let selected = try #require(try reader.activeConversationRow())
            let title = try #require(selected.handle.titleTextHandle(in: fake))
            fake.mutate(title, attribute: AXAttribute.value, to: .string(B58GroupNameGuardTests.targetMarker))
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(B58GroupNameGuardTests.targetMarker))
            fake.appendChild(to: window.handle,
                node: AXNode(role: AXRole.staticText, value: .string(B58GroupNameGuardTests.rowMarker),
                    frame: CGRect(x: 700, y: 500, width: 100, height: 20)))
            let store = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("imctl-b58-\(UUID().uuidString)"))
            handler = WeComCommandHandler(rootProvider: {
                AXElement(handle: fake.rootHandle, backend: backend)
            }, policy: ActionPolicy(allowedTargets: [B58GroupNameGuardTests.targetMarker],
                enabled: [.renameGroup], phase: .phase1), checkpoints: store)
            handler.desktopCommandOrigin = .external
            handler.desktopCommandMethod = .groupRename
            handler.visualEnabled = { true }
            handler.visualSelect = { _, _, _, _, _, _ in
                Issue.record("This already-active synthetic group must not be reselected")
                return nil
            }
            var settings = CloudVisionSettings()
            try settings.setAPIKey(B58GroupNameGuardTests.keyMarker, for: .qwen)
            try settings.enable()
            try settings.setFullWindowEnabled(true)
            handler.visualSettingsForCommit = { settings }
            handler.visualScreenRecordingGranted = { [unowned self] in
                if !self.injected {
                    self.injected = true
                    self.beforeFirstGate?()
                }
                return true
            }
            handler.configureActions = { actions in
                actions.frontmostPid = { Issue.record("Visible fixtures must not activate the app"); return nil }
                actions.restoreFrontmost = { _ in Issue.record("Visible fixtures must not restore workspace focus") }
            }
            handler.reversibleRunnerFactory = { [unowned self] in
                AIPlannerReversibleRunner(beforeRound: { try self.handler.beginVisualRound() },
                    settingsProvider: { settings }, capture: { _, _ in
                        self.captures += 1
                        Issue.record("Rejected guard must stop before capture")
                        return nil
                    }, decide: { _, _, _ in
                        self.decisions += 1
                        Issue.record("Rejected guard must stop before a provider request")
                        return AIPlannerStepDecision(step: .stop, candidateID: nil)
                    })
            }
        }
    }

    @Test func handlerGuardFailuresUseFixedReasonsWithoutEchoingPrivateInputs() throws {
        enum Drift: CaseIterable {
            case candidatesZero, candidatesTwo, replacementField, fieldFrame, windowFrame
            case directDialog, windowsEmpty, extraWindow
            var reason: GroupNameVisualGuard {
                switch self {
                case .candidatesZero, .candidatesTwo, .replacementField: return .headerCandidate
                case .fieldFrame: return .headerField
                case .windowFrame: return .context
                case .directDialog: return .directDialog
                case .windowsEmpty: return .windowSetCount
                case .extraWindow: return .indicatorShape
                }
            }
        }
        for drift in Drift.allCases {
            let h = try HandlerHarness()
            let parent = try #require(try h.field.parent())
            let windowFrame = try #require(try h.window.frame())
            h.beforeFirstGate = {
                switch drift {
                case .candidatesZero: h.backend.nonWritable.insert(h.field.handle)
                case .candidatesTwo:
                    h.fake.appendChild(to: h.window.handle,
                        node: AXNode(role: AXRole.textField, value: .string(Self.rowMarker),
                            frame: h.fieldFrame.offsetBy(dx: 250, dy: 1), settable: [AXAttribute.value]))
                case .replacementField:
                    h.fake.removeChild(h.field.handle, from: parent.handle)
                    h.fake.appendChild(to: parent.handle,
                        node: AXNode(role: AXRole.textField, value: .string(Self.targetMarker),
                            frame: h.fieldFrame, actions: [AXAction.confirm], settable: [AXAttribute.value]))
                case .fieldFrame:
                    h.fake.mutate(h.field.handle, attribute: AXAttribute.frame,
                        to: .rect(h.fieldFrame.offsetBy(dx: 5, dy: 0)))
                case .windowFrame:
                    h.fake.mutate(h.window.handle, attribute: AXAttribute.frame,
                        to: .rect(windowFrame.offsetBy(dx: 8, dy: 0)))
                case .directDialog:
                    h.fake.appendChild(to: h.window.handle,
                        node: AXNode(role: "AXDialog", frame: CGRect(x: 700, y: 300, width: 200, height: 100)))
                case .windowsEmpty:
                    h.fake.mutate(h.app.handle, attribute: AXAttribute.windows, to: .elements([]))
                case .extraWindow:
                    h.fake.appendChild(to: h.app.handle,
                        node: AXNode(role: AXRole.window, subrole: "AXStandardWindow",
                            frame: CGRect(x: 700, y: 300, width: 200, height: 100)))
                }
            }
            var checkpoints = 0, after = 0
            var caught: ControlError?
            do {
                _ = try h.handler.groupRename(target: Self.targetMarker, name: Self.requestedMarker,
                    checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
                Issue.record("A changed guard unexpectedly allowed the rename")
            } catch let error as ControlError { caught = error }
            let error = try #require(caught)
            #expect(error.code == "UNSUPPORTED" && error.message.contains("staleView"))
            #expect(error.message.contains("[guardReason=\(drift.reason.rawValue)]"))
            for marker in [Self.targetMarker, Self.requestedMarker, Self.keyMarker, Self.rowMarker] {
                #expect(!error.message.contains(marker))
            }
            #expect(h.captures == 0 && h.decisions == 0 && checkpoints == 0 && after == 0)
            #expect(h.handler.desktopCommandVisualEnd?.goal == "groupNameField")
            #expect(h.handler.desktopCommandVisualEnd?.phase == "prepare")
            #expect(h.handler.desktopCommandVisualEnd?.outcome == "staleView")
            #expect(h.fake.recordedActions.isEmpty)
            #expect(h.fake.recordedSets.allSatisfy {
                $0.handle == h.field.handle && $0.attribute == AXAttribute.focused
            })
        }
    }

    @Test func staleValidationAfterSyntheticCaptureDoesNotReuseASuccessfulGuardReason() throws {
        let h = try HandlerHarness()
        let settings = try h.handler.visualSettingsForCommit()
        h.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.handler.beginVisualRound() },
                settingsProvider: { settings }, capture: { _, frame in
                    h.captures += 1
                    h.fake.mutate(h.window.handle, attribute: AXAttribute.frame,
                        to: .rect(frame.offsetBy(dx: 8, dy: 0)))
                    guard let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
                    context.fill(CGRect(origin: .zero, size: frame.size))
                    guard let image = context.makeImage() else { return nil }
                    return WeComWindowScreenshot(image: image, windowFrame: frame)
                }, decide: { _, _, _ in
                    h.decisions += 1
                    Issue.record("Post-capture validation must stop before a provider request")
                    return AIPlannerStepDecision(step: .stop, candidateID: nil)
                })
        }
        var checkpoints = 0, after = 0
        var caught: ControlError?
        do {
            _ = try h.handler.groupRename(target: Self.targetMarker, name: Self.requestedMarker,
                checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
            Issue.record("Changed post-capture window unexpectedly allowed the rename")
        } catch let error as ControlError { caught = error }
        let error = try #require(caught)
        #expect(error.code == "UNSUPPORTED" && error.message.contains("staleView"))
        #expect(error.message.contains("[guardReason=unclassified]"))
        for marker in [Self.targetMarker, Self.requestedMarker, Self.keyMarker, Self.rowMarker] {
            #expect(!error.message.contains(marker))
        }
        #expect(h.captures == 1 && h.decisions == 0 && checkpoints == 0 && after == 0)
        #expect(h.fake.recordedActions.isEmpty)
        #expect(h.fake.recordedSets.allSatisfy {
            $0.handle == h.field.handle && $0.attribute == AXAttribute.focused
        })
    }
}

private final class GuardDiagnosticBackend: AXBackend {
    let name = "fake"
    let base: FakeAXBackend
    var processOverrides: [AXElementHandle: pid_t] = [:]
    var nonWritable: Set<AXElementHandle> = []
    init(_ base: FakeAXBackend) { self.base = base }
    func isProcessTrusted(prompt: Bool) -> Bool { base.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { base.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try base.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? { try base.attribute(name, of: element) }
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        if name == AXAttribute.value && nonWritable.contains(element) { return false }
        return try base.isAttributeSettable(name, of: element)
    }
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        try base.setAttribute(name, to: value, of: element)
    }
    func actionNames(of element: AXElementHandle) throws -> [String] { try base.actionNames(of: element) }
    func performAction(_ name: String, on element: AXElementHandle) throws { try base.performAction(name, on: element) }
    func pid(of element: AXElementHandle) throws -> pid_t { try processOverrides[element] ?? base.pid(of: element) }
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try base.makeObserver(pid: pid, handler: handler)
    }
}

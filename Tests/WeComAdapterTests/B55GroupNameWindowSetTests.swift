import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("B55 group-name sharing-indicator window set")
struct B55GroupNameWindowSetTests {
    private static let sharingTitle = "WindowSharingSessionButton"
    private static let mainFrame = CGRect(x: 0, y: 30, width: 1920, height: 1170)
    private static let fieldFrame = CGRect(x: 326, y: 50, width: 223, height: 24)
    private static let tableFrame = CGRect(x: 59, y: 93, width: 252, height: 1108)
    private static let viewportFrame = CGRect(x: 310, y: 109, width: 1450, height: 892)

    private static func indicator(in frame: CGRect) -> AXNode {
        AXNode(role: AXRole.window, subrole: "AXDialog",
               frame: CGRect(x: frame.minX + 12, y: frame.minY + 4, width: 66, height: 20),
               children: [AXNode(role: AXRole.button, title: sharingTitle,
                                 frame: CGRect(x: frame.minX + 11, y: frame.minY + 3, width: 68, height: 22),
                                 actions: [AXAction.press], settable: [AXAttribute.focused])])
    }

    private struct Harness {
        let fake: FakeAXBackend
        let backend: WindowSetBackend
        let app: AXElement
        let window: AXElement
        let indicator: AXElement?
        let button: AXElement?

        init(includeIndicator: Bool = true, origin: CGPoint = CGPoint(x: 0, y: 30)) throws {
            let frame = CGRect(origin: origin, size: B55GroupNameWindowSetTests.mainFrame.size)
            let main = AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: frame)
            let children = [main] + (includeIndicator ? [B55GroupNameWindowSetTests.indicator(in: frame)] : [])
            fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: children))
            backend = WindowSetBackend(fake)
            let elementBackend = backend
            app = AXElement(handle: fake.rootHandle, backend: backend)
            window = AXElement(handle: try #require(fake.handle(atPath: [0])), backend: backend)
            indicator = fake.handle(atPath: [1]).map { AXElement(handle: $0, backend: elementBackend) }
            button = fake.handle(atPath: [1, 0]).map { AXElement(handle: $0, backend: elementBackend) }
            // Explicit AXWindows preserves malformed window entries for negative role tests.
            fake.mutate(fake.rootHandle, attribute: AXAttribute.windows,
                        to: .elements([window.handle] + (indicator.map { [$0.handle] } ?? [])))
        }

        func verify(field: CGRect = B55GroupNameWindowSetTests.fieldFrame,
                    table: CGRect = B55GroupNameWindowSetTests.tableFrame,
                    viewport: CGRect = B55GroupNameWindowSetTests.viewportFrame,
                    expectedFrame: CGRect? = nil) throws {
            let currentFrame = try #require(try window.frame())
            try WeComCommandHandler.verifyGroupNameWindowSet(
                app: app, window: window, pid: fake.pid,
                frame: expectedFrame ?? currentFrame, fieldFrame: field,
                conversationTableFrame: table, viewportFrame: viewport)
        }

        func expectNoActions() {
            #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
        }
    }

    @Test func exactIndicatorAndTranslatedMainWindowAreReadOnly() throws {
        for offset in [CGPoint.zero, CGPoint(x: 700, y: 250)] {
            let h = try Harness(origin: CGPoint(x: Self.mainFrame.minX + offset.x, y: Self.mainFrame.minY + offset.y))
            try h.verify(field: Self.fieldFrame.offsetBy(dx: offset.x, dy: offset.y),
                         table: Self.tableFrame.offsetBy(dx: offset.x, dy: offset.y),
                         viewport: Self.viewportFrame.offsetBy(dx: offset.x, dy: offset.y))
            h.expectNoActions()
        }
    }

    @Test func singleWindowKeepsItsExistingSubroleAndOptionalFocusedWindowSemantics() throws {
        let h = try Harness(includeIndicator: false)
        h.fake.mutate(h.window.handle, attribute: AXAttribute.subrole, to: nil)
        h.fake.mutate(h.app.handle, attribute: AXAttribute.focusedWindow, to: .elements([]))
        try h.verify()
        h.expectNoActions()
    }

    @Test func narrowRailIndicatorAboveTheTableAndAnIndicatorLeftOfTheTableAreReadOnly() throws {
        let h = try Harness()
        let indicatorFrame = try #require(try h.indicator?.frame())
        let buttonFrame = try #require(try h.button?.frame())
        let accessory = indicatorFrame.union(buttonFrame)
        // The real 59 pt rail is narrower than the 79 pt accessory edge. Its
        // bottom is above the conversation table, so no row is covered.
        #expect(accessory.maxX > Self.tableFrame.minX && accessory.maxY <= Self.tableFrame.minY)
        try h.verify()
        let tableToTheRight = CGRect(x: 160, y: 33, width: 252, height: 1108)
        #expect(accessory.maxX <= tableToTheRight.minX && accessory.maxY > tableToTheRight.minY)
        try h.verify(table: tableToTheRight)
        h.expectNoActions()
    }

    @Test func ordinaryOrMalformedIndicatorsAreRejected() throws {
        enum Drift: CaseIterable {
            case windowRole, windowSubrole, buttonRole, buttonSubrole, title, valueOnlyTitle
            case movedWindow, resizedWindow, movedButton, resizedButton, extraChild, nestedButton
            case standardMain, missingMain, duplicateMain, focusedIndicator, thirdWindow
        }
        for drift in Drift.allCases {
            let h = try Harness()
            let indicator = try #require(h.indicator)
            let button = try #require(h.button)
            switch drift {
            case .windowRole: h.fake.mutate(indicator.handle, attribute: AXAttribute.role, to: .string(AXRole.group))
            case .windowSubrole: h.fake.mutate(indicator.handle, attribute: AXAttribute.subrole, to: .string("AXStandardWindow"))
            case .buttonRole: h.fake.mutate(button.handle, attribute: AXAttribute.role, to: .string(AXRole.textField))
            case .buttonSubrole: h.fake.mutate(button.handle, attribute: AXAttribute.subrole, to: .string("AXCloseButton"))
            case .title: h.fake.mutate(button.handle, attribute: AXAttribute.title, to: .string("OrdinaryDialogButton"))
            case .valueOnlyTitle:
                h.fake.mutate(button.handle, attribute: AXAttribute.title, to: nil)
                h.fake.mutate(button.handle, attribute: AXAttribute.value, to: .string(Self.sharingTitle))
            case .movedWindow:
                h.fake.mutate(indicator.handle, attribute: AXAttribute.frame,
                              to: .rect(CGRect(x: 20, y: 34, width: 66, height: 20)))
            case .resizedWindow:
                h.fake.mutate(indicator.handle, attribute: AXAttribute.frame,
                              to: .rect(CGRect(x: 12, y: 34, width: 100, height: 20)))
            case .movedButton:
                h.fake.mutate(button.handle, attribute: AXAttribute.frame,
                              to: .rect(CGRect(x: 18, y: 33, width: 68, height: 22)))
            case .resizedButton:
                h.fake.mutate(button.handle, attribute: AXAttribute.frame,
                              to: .rect(CGRect(x: 11, y: 33, width: 68, height: 28)))
            case .extraChild:
                h.fake.appendChild(to: indicator.handle, node: AXNode(role: AXRole.button, title: "Other"))
            case .nestedButton:
                h.fake.appendChild(to: button.handle, node: AXNode(role: AXRole.textField))
            case .standardMain: h.fake.mutate(h.window.handle, attribute: AXAttribute.subrole, to: .string("AXDialog"))
            case .missingMain: h.fake.mutate(h.app.handle, attribute: AXAttribute.mainWindow, to: .element(indicator.handle))
            case .duplicateMain:
                h.fake.mutate(h.app.handle, attribute: AXAttribute.windows,
                              to: .elements([h.window.handle, h.window.handle]))
            case .focusedIndicator:
                h.fake.mutate(h.app.handle, attribute: AXAttribute.focusedWindow, to: .element(indicator.handle))
            case .thirdWindow:
                let extra = try #require(h.fake.appendChild(to: h.app.handle, node: Self.indicator(in: Self.mainFrame)))
                h.fake.mutate(h.app.handle, attribute: AXAttribute.windows,
                              to: .elements([h.window.handle, indicator.handle, extra]))
            }
            #expect(throws: AIPlannerVisionError.staleView) { try h.verify() }
            h.expectNoActions()
        }
    }

    @Test func wrongPIDOnAnyLayerIsRejected() throws {
        for layer in 0..<4 {
            let h = try Harness()
            let handles = [h.app.handle, h.window.handle, try #require(h.indicator).handle, try #require(h.button).handle]
            h.backend.pidOverrides[handles[layer]] = h.fake.pid + 1
            #expect(throws: AIPlannerVisionError.staleView) { try h.verify() }
            h.expectNoActions()
        }
    }

    @Test func differentBackendMissingMainWindowAndAXReadFailureNeverPass() throws {
        let h = try Harness()
        let foreignWindow = AXElement(handle: h.window.handle, backend: h.fake)
        #expect(throws: AIPlannerVisionError.staleView) {
            try WeComCommandHandler.verifyGroupNameWindowSet(
                app: h.app, window: foreignWindow, pid: h.fake.pid,
                frame: Self.mainFrame, fieldFrame: Self.fieldFrame,
                conversationTableFrame: Self.tableFrame, viewportFrame: Self.viewportFrame)
        }
        h.fake.injectedFailures["get:\(AXAttribute.mainWindow)"] = .attributeUnsupported(AXAttribute.mainWindow)
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify() }
        h.fake.injectedFailures.removeAll()
        h.fake.injectedFailures["get:\(AXAttribute.windows)"] = .cannotComplete("synthetic AXWindows failure")
        #expect(throws: AXKitError.self) { try h.verify() }
        h.expectNoActions()
    }

    @Test func indicatorGeometryAcceptsOnlyTheTwoPointTolerance() throws {
        for delta in [CGFloat(-2), 2, 2.01] {
            let h = try Harness()
            let indicator = try #require(h.indicator)
            let button = try #require(h.button)
            let indicatorFrame = try #require(try indicator.frame())
            let buttonFrame = try #require(try button.frame())
            h.fake.mutate(indicator.handle, attribute: AXAttribute.frame,
                          to: .rect(indicatorFrame.offsetBy(dx: delta, dy: delta)))
            h.fake.mutate(button.handle, attribute: AXAttribute.frame,
                          to: .rect(buttonFrame.offsetBy(dx: delta, dy: delta)))
            if abs(delta) <= 2 { try h.verify() }
            else { #expect(throws: AIPlannerVisionError.staleView) { try h.verify() } }
            h.expectNoActions()
        }
    }

    @Test func indicatorCannotCoverAnyCommandRegionOrLeaveTheSafeTopOrLeftRegion() throws {
        let h = try Harness()
        let overlap = CGRect(x: 50, y: 40, width: 100, height: 20)
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(field: overlap) }
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(viewport: overlap) }
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(table: overlap) }
        #expect(throws: AIPlannerVisionError.staleView) {
            try h.verify(table: CGRect(x: 70, y: 40, width: 250, height: 800))
        }
        // A disjoint rectangle is insufficient when the accessory is neither
        // completely left of nor completely above the conversation table.
        #expect(throws: AIPlannerVisionError.staleView) {
            try h.verify(table: CGRect(x: 0, y: 30, width: 5, height: 2))
        }
        h.expectNoActions()
    }

    @Test func missingNonfiniteOrNonpositiveFramesAndStaleMainFrameAreRejected() throws {
        let invalid = [CGRect.zero, CGRect(x: CGFloat.infinity, y: 34, width: 66, height: 20),
                       CGRect(x: 12, y: 34, width: CGFloat.nan, height: 20)]
        for frame in invalid {
            let h = try Harness()
            h.fake.mutate(try #require(h.indicator).handle, attribute: AXAttribute.frame, to: .rect(frame))
            #expect(throws: AIPlannerVisionError.staleView) { try h.verify() }
            h.expectNoActions()
        }
        let h = try Harness()
        #expect(throws: AIPlannerVisionError.staleView) {
            try h.verify(expectedFrame: Self.mainFrame.offsetBy(dx: 10, dy: 0))
        }
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(field: .zero) }
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(table: .null) }
        #expect(throws: AIPlannerVisionError.staleView) { try h.verify(viewport: .infinite) }
        h.expectNoActions()
        let missing = try Harness()
        let indicator = try #require(missing.indicator)
        for attribute in [AXAttribute.frame, AXAttribute.position, AXAttribute.size] {
            missing.fake.mutate(indicator.handle, attribute: attribute, to: nil)
        }
        #expect(throws: AIPlannerVisionError.staleView) { try missing.verify() }
        missing.expectNoActions()
    }

    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(origin: .zero, size: frame.size))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    @Test func appRootedGroupRenameChecksTheIndicatorBeforeAndAfterStaging() throws {
        for driftAt in [AIPlannerPhase?.none, .prepare, .verify] {
            var main = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json"))
            main.subrole = "AXStandardWindow"
            let mainFrame = try #require(main.frame?.cgRect)
            let fake = FakeAXBackend(root: AXNode(role: AXRole.application,
                                                 children: [main, Self.indicator(in: mainFrame)]))
            let window = try #require(fake.element(atPath: [0]))
            let button = try #require(fake.element(atPath: [1, 0]))
            let reader = try WeComReader(window: window)
            let old = try #require(try reader.activeConversationTitle())
            let field = try #require(reader.layout.activeTitle)
            let rowTitle = try #require(try reader.activeConversationRow()?.handle.titleTextHandle(in: fake))
            let store = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("imctl-b55-\(UUID().uuidString)"))
            let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
                                              policy: ActionPolicy(allowedTargets: [old], enabled: [.renameGroup], phase: .phase1),
                                              checkpoints: store)
            handler.desktopCommandOrigin = .external
            handler.desktopCommandMethod = .groupRename
            handler.visualEnabled = { true }
            handler.visualScreenRecordingGranted = { true }
            handler.visualSelect = { _, _, _, _, _, _ in Issue.record("active group must not reselect"); return nil }
            let settings = try AIPlannerVisionClientTests.settings()
            handler.visualSettingsForCommit = { settings }
            var rounds = 0, checkpoints = 0, after = 0
            handler.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                          settingsProvider: { settings }, capture: { _, frame in Self.shot(frame) },
                                          decide: { _, context, _ in
                    rounds += 1
                    if context.phase == driftAt {
                        fake.mutate(button.handle, attribute: AXAttribute.title, to: .string("OrdinaryDialogButton"))
                    }
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                })
            }
            fake.reactions["action:\(AXAction.confirm)"] = {
                fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("B55 synthetic name"))
            }
            if let driftAt {
                #expect(throws: ControlError.self) {
                    try handler.groupRename(target: old, name: "B55 synthetic name",
                                            checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
                }
                #expect(rounds == (driftAt == .prepare ? 1 : 2))
                #expect(checkpoints == (driftAt == .prepare ? 0 : 1) && after == 0)
                #expect(fake.recordedActions.isEmpty)
            } else {
                let result = try handler.groupRename(target: old, name: "B55 synthetic name",
                                                     checkpoint: { checkpoints += 1 }, afterSubmit: { after += 1 })
                #expect(result["renamed"] == "true" && rounds == 2 && checkpoints == 1 && after == 1)
                #expect(fake.recordedActions.count == 1 && fake.recordedActions[0].handle == field.handle
                        && fake.recordedActions[0].action == AXAction.confirm)
            }
            #expect(fake.recordedSets.allSatisfy { $0.handle != button.handle })
            #expect(fake.recordedActions.allSatisfy { $0.handle != button.handle })
        }
    }
}

/// Lets a malformed app/window/button PID be tested without querying a real process.
private final class WindowSetBackend: AXBackend {
    let name = "fake"
    let base: FakeAXBackend
    var pidOverrides: [AXElementHandle: pid_t] = [:]
    init(_ base: FakeAXBackend) { self.base = base }
    func isProcessTrusted(prompt: Bool) -> Bool { base.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { base.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try base.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? { try base.attribute(name, of: element) }
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool { try base.isAttributeSettable(name, of: element) }
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws { try base.setAttribute(name, to: value, of: element) }
    func actionNames(of element: AXElementHandle) throws -> [String] { try base.actionNames(of: element) }
    func performAction(_ name: String, on element: AXElementHandle) throws { try base.performAction(name, on: element) }
    func pid(of element: AXElementHandle) throws -> pid_t { try pidOverrides[element] ?? base.pid(of: element) }
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try base.makeObserver(pid: pid, handler: handler)
    }
}

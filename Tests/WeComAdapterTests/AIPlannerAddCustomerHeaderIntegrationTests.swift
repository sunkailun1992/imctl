import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

/// Synthetic New Customers page plus a redacted Add Customer panel. Every
/// command is a dry run: a match is read, but no invite or checkpoint occurs.
@Suite("contact add-customer header visual rounds")
struct AIPlannerAddCustomerHeaderIntegrationTests {
    private static let phone = "13800000000"

    private final class Box {
        let fake: FakeAXBackend
        let handler: WeComCommandHandler
        let main: AXElement
        let headerButtons: [AXElement]
        var panelHandle: AXElementHandle?
        var headerPresses = 0
        var opened: [String] = ["customer"]

        init(ambiguous: Bool = true) throws {
            fake = FakeAXBackend(root: AXNode(role: AXRole.application,
                                               children: [ContactsFixture.collapsedRail()]))
            main = try #require(try fake.rootElement.elements(AXAttribute.windows).first)
            let original = try #require(main.descendants(maxDepth: 14, maxNodes: 8000).first {
                (try? $0.role()) == AXRole.button && (try? $0.title()) == "添加"
            })
            fake.setActions(of: original.handle, to: [AXAction.press])
            if ambiguous {
                // A second 添加 beside the same 新的客户 heading, in the pane's own group: AX alone cannot
                // tell which one opens 添加客户, so the visual rounds choose between the two.
                let pane = try #require(try original.parent())
                _ = fake.appendChild(to: pane.handle, node: AXNode(
                    role: AXRole.button, title: "添加", frame: CGRect(x: 1730, y: 55, width: 55, height: 19),
                    actions: [AXAction.press]))
            }
            headerButtons = try WeComActions.addCustomerHeaderCandidates(window: main)
            let policy = ActionPolicy(allowedTargets: ["文件传输助手"],
                                      enabled: [.openContacts, .addContact], phase: .phase1)
            let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("imctl-b26-contact-\(UUID().uuidString)"))
            handler = WeComCommandHandler(rootProvider: { [fake] in fake.rootElement },
                                          policy: policy, checkpoints: checkpoints)
            handler.desktopCommandMethod = .contactAdd
            handler.visualEnabled = { true }
            handler.visualScreenRecordingGranted = { true }
            handler.visualSettingsForCommit = { try AIPlannerVisionClientTests.settings() }
            handler.visualSelect = { _, _, _, _, _, _ in
                Issue.record("B26 must not use the one-step selector")
                return nil
            }
            handler.configureActions = { actions in
                actions.verifyTimeout = 0.05
                actions.verifyInterval = 0.005
                actions.frontmostPid = { nil }
                actions.postShortcut = { _, _ in }
                actions.postReturnKey = { _, _ in }
                actions.openURL = { _ in true }
                actions.windowIdentities = { _ in [] }   // never the real window server for the fake pid
            }
            fake.reactions["action:\(AXAction.press)"] = { [weak self] in
                guard let self, let last = self.fake.recordedActions.last?.handle else { return }
                if self.headerButtons.contains(where: { $0.handle == last }) {
                    self.headerPresses += 1
                    let next = self.opened.isEmpty ? "drop" : self.opened.removeFirst()
                    switch next {
                    case "customer":
                        if let panel = try? Self.customerPanel() {
                            self.panelHandle = self.fake.appendChild(to: self.fake.rootHandle, node: panel)
                        } else { Issue.record("synthetic Add Customer panel could not load") }
                    case "wrong": self.panelHandle = self.fake.appendChild(to: self.fake.rootHandle, node: Self.wrongPanel())
                    case "sheet": _ = self.fake.appendChild(to: self.main.handle, node: Self.wrongSheet())
                    default: break
                    }
                } else if let panel = self.panelHandle,
                          let e = try? AXElement(handle: last, backend: self.fake).subrole(),
                          e == "AXCloseButton" {
                    self.fake.mutate(panel, attribute: AXAttribute.role, to: .string(AXRole.group))
                } else if (try? AXElement(handle: last, backend: self.fake).title()) == "取消" {
                    let sheets = self.main.descendants(maxDepth: 3, maxNodes: 100).filter {
                        (try? $0.role()) == AXRole.sheet
                    }
                    if let sheet = sheets.first { self.fake.mutate(sheet.handle, attribute: AXAttribute.role, to: .string(AXRole.group)) }
                }
            }
        }

        static func customerPanel() throws -> AXNode {
            let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-customer.json"))
            var panel = try #require(root.children.first)
            func clear(_ node: inout AXNode) -> Bool {
                if node.role == AXRole.textField { node.value = .string(""); return true }
                for i in node.children.indices where clear(&node.children[i]) { return true }
                return false
            }
            _ = clear(&panel)
            return panel
        }

        static func wrongPanel() -> AXNode {
            AXNode(role: AXRole.window, frame: CGRect(x: 300, y: 100, width: 600, height: 400), children: [
                AXNode(role: AXRole.staticText, value: .string("其它面板"), frame: CGRect(x: 330, y: 130, width: 100, height: 25)),
                AXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 305, y: 105, width: 20, height: 20),
                       actions: [AXAction.press]),
            ])
        }

        private static func wrongSheet() -> AXNode {
            AXNode(role: AXRole.sheet, frame: CGRect(x: 500, y: 300, width: 400, height: 300), children: [
                AXNode(role: AXRole.staticText, value: .string("添加客户"),
                       frame: CGRect(x: 600, y: 330, width: 100, height: 25)),
                AXNode(role: AXRole.button, title: "取消", frame: CGRect(x: 810, y: 540, width: 70, height: 30),
                       actions: [AXAction.press]),
            ])
        }

        func dryRun() throws -> [String: String] {
            try handler.contactAdd(phone: AIPlannerAddCustomerHeaderIntegrationTests.phone,
                                   source: "wechat", greeting: nil, dryRun: true,
                                   checkpoint: { Issue.record("dry-run reached checkpoint") },
                                   afterSubmit: { Issue.record("dry-run reached afterSubmit") })
        }
    }

    private static func shot(_ frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    private static func installRunner(_ box: Box, captures: @escaping () -> Void = {},
                                      captured: @escaping (CGRect) -> Void = { _ in },
                                      passive: @escaping (AIPlannerStepContext) -> AIPlannerStepDecision = { _ in
                                          AIPlannerStepDecision(step: .verify, candidateID: nil)
                                      },
                                      decide: @escaping (AIPlannerObservation, AIPlannerStepContext) -> AIPlannerStepDecision) {
        box.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { try box.handler.beginVisualRound() },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in captures(); captured(frame); return shot(frame) },
                decide: { observation, context, _ in
                    if context.allowedSteps == [.verify, .reobserve, .stop] {
                        return passive(context)
                    }
                    return decide(observation, context)
                })
        }
    }

    private static func choose(_ observation: AIPlannerObservation) -> AIPlannerStepDecision {
        AIPlannerStepDecision(step: .press, candidateID: observation.candidates.first?.id)
    }

    @Test func ambiguousHeaderOpensBlankPanelAndKeepsInviteOutOfRunner() throws {
        let box = try Box()
        var captures = 0, decisions = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { observation, context in
            decisions += 1
            #expect(context.method == .contactAdd)
            #expect(context.allowedSteps == [.press, .reobserve, .verify, .stop])
            #expect(observation.candidates.count == 2)
            if case .control(.addContact) = context.goal {} else { Issue.record("wrong goal") }
            return Self.choose(observation)
        })
        let result = try box.dryRun()
        #expect(result["status"] == "matched" && captures == 3 && decisions == 1)
        #expect(box.headerPresses == 1)
        #expect(box.fake.recordedActions.filter { $0.action == AXAction.press }.count == 2) // header, then panel close
    }

    @Test func uniqueHeaderUsesAXThenPassivelyObservesSearchAndResult() throws {
        let box = try Box(ambiguous: false)
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { _, _ in
            Issue.record("unique header should not need a model choice")
            return .init(step: .stop, candidateID: nil)
        })
        #expect(try box.dryRun()["status"] == "matched")
        #expect(captures == 2 && box.headerPresses == 1)
    }

    @Test func preexistingSecondWindowStopsBeforeCaptureOrPress() throws {
        let box = try Box()
        _ = box.fake.appendChild(to: box.fake.rootHandle, node: Box.wrongPanel())
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { observation, _ in Self.choose(observation) })
        #expect(throws: ControlError.self) { try box.dryRun() }
        #expect(captures == 0 && box.headerPresses == 0)
    }

    @Test func preexistingRealSearchWindowIsNeverAdopted() throws {
        let box = try Box(ambiguous: false)
        let alreadyOpen = try Box.customerPanel()
        _ = box.fake.appendChild(to: box.fake.rootHandle, node: alreadyOpen)
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { _, _ in
            Issue.record("pre-existing search window reached model")
            return .init(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try box.dryRun() }
        #expect(box.headerPresses == 0 && captures == 0)
        #expect(box.fake.recordedSets.allSatisfy { $0.attribute != AXAttribute.value })
    }

    @Test func modelStopAtSearchClosesOnlyOwnedBlankWindowBeforePhoneWrite() throws {
        let box = try Box(ambiguous: false)
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, passive: { context in
            if case .control(.contactSearch) = context.goal {
                return .init(step: .stop, candidateID: nil)
            }
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) { try box.dryRun() }
        #expect(captures == 1 && box.headerPresses == 1)
        #expect(box.fake.recordedSets.allSatisfy { $0.attribute != AXAttribute.value })
    }

    @Test func modelStopAtUniqueSourceMatchNeverPressesResult() throws {
        let box = try Box(ambiguous: false)
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, passive: { context in
            if case .control(.contactMatch) = context.goal {
                return .init(step: .stop, candidateID: nil)
            }
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) { try box.dryRun() }
        #expect(captures == 2 && box.headerPresses == 1)
        #expect(box.fake.recordedActions.filter { $0.action == AXAction.press }.count == 2) // header, owned close
    }

    /// Live 2026-09-29: the invite of a WeCom user comes as a separate 发送验证申请 window. The command's
    /// third passive round observes that window itself, a checkpoint precedes the one 发送 press, and
    /// the window closing makes the add `requested`.
    @Test func separateVerificationWindowGoesThroughItsOwnInviteRound() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var verification: AXElementHandle?
        var sends = 0
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }) else { return }
            let title = (try? AXElement(handle: last, backend: box.fake).title()) ?? nil
            if title == "添加", box.panelHandle != nil, verification == nil {
                verification = box.fake.appendChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow())
            } else if title == "发送", let window = verification {
                sends += 1
                box.fake.mutate(window, attribute: AXAttribute.role, to: .string(AXRole.group))
            }
        }
        var frames: [CGRect] = []
        var checkpoints = 0
        Self.installRunner(box, captured: { frames.append($0) }, decide: { _, _ in
            Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil)
        })
        let result = try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                                checkpoint: { checkpoints += 1 }, afterSubmit: {})
        // One checkpoint before the match's 添加, one before 发送: both are irreversible.
        #expect(result["status"] == "requested" && result["confirmed"] == "发送" && sends == 1 && checkpoints == 2)
        #expect(result["inviteWindow"] == "separate" && result["inviteDialog"] == "closed")
        #expect(frames.count == 3 && frames.last == CGRect(x: 780, y: 414, width: 360, height: 403))
    }

    /// The handler tolerates only the one window this command saw appear after its match press: a
    /// second 发送验证申请-shaped window that shows up while the 发送 checkpoint is written is refused by
    /// the handler's own gate, the first check after that checkpoint, and 发送 is never pressed.
    @Test func aSecondVerificationWindowAtTheSendCheckpointStopsInTheHandlerGate() throws {
        let box = try Box(ambiguous: false)
        let verification = Self.opensVerificationWindowOnMatchPress(box)
        var intruder: AXElementHandle?
        var checkpoints = 0
        Self.installRunner(box, decide: { _, _ in
            Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil)
        })
        var thrown: (any Error)?
        do {
            _ = try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false, checkpoint: {
                checkpoints += 1
                if checkpoints == 2 { intruder = box.fake.appendChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow()) }
            }, afterSubmit: {})
        } catch { thrown = error }
        #expect(verification() != nil && intruder != nil && checkpoints == 2)
        #expect(String(describing: thrown ?? ControlError.internalError("no error")).contains("visual gate"))
        #expect(!box.fake.recordedActions.contains {
            (try? AXElement(handle: $0.handle, backend: box.fake).title()) == "发送"
        })
    }

    /// The handler's own capture choice (not a test capture): each panel stage names the panel's proved
    /// number and the invite stage the number proved new at the match press — the separate window alone.
    @Test func theInviteWindowIsCapturedOnlyByItsProvedNumber() throws {
        let box = try Box(ambiguous: false)
        let verification = Self.opensVerificationWindowOnMatchPress(box)
        Self.numberWindows(box)
        var captured: [(frame: CGRect, windowID: CGWindowID?)] = []
        box.handler.windowCapture = { _, frame, _, windowID in captured.append((frame, windowID)); return Self.shot(frame) }
        Self.installHandlerCaptureRunner(box)
        var checkpoints = 0
        let result = try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                                checkpoint: { checkpoints += 1 }, afterSubmit: {})
        #expect(result["status"] == "requested" && result["inviteWindow"] == "separate" && checkpoints == 2)
        let panelNumber = try #require(box.panelHandle.flatMap { Self.number(of: $0) })
        let inviteNumber = try #require(verification().flatMap { Self.number(of: $0) })
        #expect(captured.map(\.windowID) == [panelNumber, panelNumber, inviteNumber])
        #expect(captured.last?.frame == CGRect(x: 780, y: 414, width: 360, height: 403))
    }

    /// When the window server never lists the separate window as new, its number is unproved and the
    /// capture refuses: nothing of it is taken, no geometric fallback, and 发送 is never pressed.
    @Test func anUnprovedInviteWindowIsNeverCaptured() throws {
        let box = try Box(ambiguous: false)
        let verification = Self.opensVerificationWindowOnMatchPress(box)
        Self.numberWindows(box, hiding: verification)
        var captured: [(frame: CGRect, windowID: CGWindowID?)] = []
        box.handler.windowCapture = { _, frame, _, windowID in captured.append((frame, windowID)); return Self.shot(frame) }
        Self.installHandlerCaptureRunner(box)
        var checkpoints = 0
        #expect(throws: (any Error).self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: { checkpoints += 1 }, afterSubmit: {})
        }
        #expect(verification() != nil && checkpoints == 1)
        #expect(captured.count == 2 && captured.allSatisfy { $0.windowID != nil && $0.frame.width != 360 })
        #expect(!box.fake.recordedActions.contains {
            (try? AXElement(handle: $0.handle, backend: box.fake).title()) == "发送"
        })
    }

    /// The invite number is proved only against a pre-press snapshot that also lists the main window B50
    /// proved: in a snapshot without it every window would look new, so the number stays unproved, the
    /// capture refuses and 发送 is never pressed.
    @Test func anInviteNumberNeedsTheProvedMainWindowInThePrePressSnapshot() throws {
        let box = try Box(ambiguous: false)
        let verification = Self.opensVerificationWindowOnMatchPress(box)
        var blind = false
        Self.numberWindows(box, blind: { blind })
        let opening = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = { blind = false; opening?() }
        var captured: [CGWindowID?] = []
        box.handler.windowCapture = { _, frame, _, windowID in captured.append(windowID); return Self.shot(frame) }
        Self.installHandlerCaptureRunner(box)
        var checkpoints = 0
        #expect(throws: (any Error).self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: { checkpoints += 1; blind = true }, afterSubmit: {})
        }
        let panelNumber = try #require(box.panelHandle.flatMap { Self.number(of: $0) })
        #expect(verification() != nil && checkpoints == 1 && captured == [panelNumber, panelNumber])
        #expect(!box.fake.recordedActions.contains {
            (try? AXElement(handle: $0.handle, backend: box.fake).title()) == "发送"
        })
    }

    /// The panel's 添加 opens the recorded 发送验证申请 window (newest first, as live); its 发送 closes it.
    private static func opensVerificationWindowOnMatchPress(_ box: Box) -> () -> AXElementHandle? {
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var verification: AXElementHandle?
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }) else { return }
            let title = (try? AXElement(handle: last, backend: box.fake).title()) ?? nil
            if title == "添加", box.panelHandle != nil, verification == nil {
                verification = box.fake.prependChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow())
            } else if title == "发送", let window = verification {
                box.fake.removeChild(window, from: box.fake.rootHandle)
            }
        }
        return { verification }
    }

    /// Window numbers as the window server would list the fake's windows: one on-screen layer-0 entry per
    /// listed AX window, numbered after its handle — except a hidden one, which the server never lists.
    private static func numberWindows(_ box: Box, hiding hidden: @escaping () -> AXElementHandle? = { nil },
                                      blind: @escaping () -> Bool = { false }) {
        let configure = box.handler.configureActions
        box.handler.configureActions = { actions in
            configure(&actions)
            actions.windowIdentities = { _ in
                if blind() { return [] }
                return ((try? box.fake.rootElement.elements(AXAttribute.windows)) ?? []).compactMap { window in
                    guard window.handle != hidden(), let number = Self.number(of: window.handle),
                          let frame = (try? window.frame()) ?? nil else { return nil }
                    return WeComWindowIdentity(id: number, layer: 0, bounds: frame, onScreen: true)
                }
            }
        }
    }

    private static func number(of handle: AXElementHandle) -> CGWindowID? {
        (handle.id as? Int).map { CGWindowID(70000 + $0) }
    }

    /// A runner that keeps the handler's own capture; every round is a passive verify.
    private static func installHandlerCaptureRunner(_ box: Box) {
        box.handler.contactAddRunnerFactory = { capture in
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { try box.handler.beginVisualRound() },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: capture,
                decide: { _, context, _ in
                    guard context.allowedSteps == [.verify, .reobserve, .stop] else {
                        Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil)
                    }
                    return .init(step: .verify, candidateID: nil)
                })
        }
    }

    @Test func modelStopAtInviteNeverPressesConfirmation() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var inviteHandle: AXElementHandle?
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  let panel = box.panelHandle,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            inviteHandle = box.fake.appendChild(to: panel, node: AXNode(
                role: AXRole.button, title: "发送添加邀请",
                frame: CGRect(x: 884, y: 702, width: 222, height: 40),
                actions: [AXAction.press]))
        }
        var captures = 0, checkpoints = 0
        Self.installRunner(box, captures: { captures += 1 }, passive: { context in
            if case .control(.contactInvite) = context.goal {
                return .init(step: .stop, candidateID: nil)
            }
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: { checkpoints += 1 }, afterSubmit: {})
        }
        #expect(captures == 3 && checkpoints == 1)
        #expect(inviteHandle != nil && !box.fake.recordedActions.contains { $0.handle == inviteHandle })
    }

    @Test func headerButtonWithConfirmSemanticsIsNotOffered() throws {
        let box = try Box()
        let first = try #require(box.headerButtons.first)
        box.fake.mutate(first.handle, attribute: AXAttribute.help, to: .string("发送添加邀请"))
        #expect(try WeComActions.addCustomerHeaderCandidates(window: box.main).count == 1)
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { _, _ in
            Issue.record("single safe AX button uploaded")
            return .init(step: .stop, candidateID: nil)
        })
        #expect(try box.dryRun()["status"] == "matched")
        #expect(captures == 2 && box.headerPresses == 1)
        #expect(box.fake.recordedActions.first?.handle != first.handle)
    }

    @Test func droppedFirstPressGetsFreshSecondObservation() throws {
        let box = try Box()
        box.opened = ["drop", "customer"]
        var captures = 0
        Self.installRunner(box, captures: { captures += 1 }, decide: { observation, _ in Self.choose(observation) })
        #expect(try box.dryRun()["status"] == "matched")
        #expect(box.headerPresses == 2 && captures == 4)
    }

    @Test func unrelatedNewWindowIsLeftOpenAndStopsBeforeRetry() throws {
        let box = try Box()
        box.opened = ["wrong", "customer"]
        Self.installRunner(box, decide: { observation, _ in Self.choose(observation) })
        #expect(throws: ControlError.self) { try box.dryRun() }
        #expect(box.headerPresses == 1)
        #expect(box.fake.recordedActions.filter { $0.action == AXAction.press }.count == 1)
    }

    @Test func wrongSheetIsCancelledBeforeSecondPress() throws {
        let box = try Box()
        box.opened = ["sheet", "customer"]
        Self.installRunner(box, decide: { observation, _ in Self.choose(observation) })
        #expect(try box.dryRun()["status"] == "matched")
        #expect(box.headerPresses == 2)
    }

    @Test func revokedPolicyOrPermissionStopsBeforePress() throws {
        for drift in 0..<4 {
            let box = try Box()
            var enabled = true
            box.handler.visualEnabled = { enabled }
            Self.installRunner(box, decide: { observation, _ in
                switch drift {
                case 0: box.handler.policy.enabled.remove(.addContact)
                case 1: box.handler.policy.sendPolicy.contactAdd.maxAddsPerHour = 1  // any policy edit
                case 2: enabled = false
                default: box.handler.desktopCommandMethod = .groupAddMembers
                }
                return Self.choose(observation)
            })
            #expect(throws: ControlError.self) { try box.dryRun() }
            #expect(box.headerPresses == 0)
        }
    }

    @Test func candidateOrWindowFrameDriftStopsBeforePress() throws {
        for drift in 0..<2 {
            let box = try Box()
            Self.installRunner(box, decide: { observation, _ in
                if drift == 0, let candidate = observation.candidates.first {
                    box.fake.mutate(candidate.element.handle, attribute: AXAttribute.frame,
                                    to: .rect(candidate.frame.offsetBy(dx: 20, dy: 0)))
                } else if let frame = try? box.main.frame() {
                    box.fake.mutate(box.main.handle, attribute: AXAttribute.frame,
                                    to: .rect(frame.offsetBy(dx: 20, dy: 0)))
                }
                return Self.choose(observation)
            })
            #expect(throws: ControlError.self) { try box.dryRun() }
            #expect(box.headerPresses == 0)
        }
    }

    @Test func genericRunnerCannotPressContactHeader() throws {
        let box = try Box()
        let runner = AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
            beforeRound: {}, settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { _, frame in Self.shot(frame) },
            decide: { _, _, _ in AIPlannerStepDecision(step: .press, candidateID: "C0") })
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try runner.run(method: .contactAdd, gate: {}, observe: {
                AIPlannerReversibleRound(window: box.main, goal: .control(.addContact),
                                         action: .press, eligible: box.headerButtons,
                                         expectedTitle: nil, phase: .locate, evidence: .targetVisible)
            }, apply: { _, _ in Issue.record("generic runner pressed") }, verify: { false })
        }
        #expect(box.headerPresses == 0)
    }

    /// B54: a model stop at the invite records where it stopped, and each round reaches the log as fixed
    /// categories only — no phone number.
    @Test func aStopAtTheInviteRecordsWhereItStopped() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  let panel = box.panelHandle,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            _ = box.fake.appendChild(to: panel, node: AXNode(
                role: AXRole.button, title: "发送添加邀请",
                frame: CGRect(x: 884, y: 702, width: 222, height: 40),
                actions: [AXAction.press]))
        }
        var lines: [String] = []
        box.handler.visualRoundLog = { lines.append($0) }
        Self.installRunner(box, passive: { context in
            if case .control(.contactInvite) = context.goal { return .init(step: .stop, candidateID: nil) }
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "contactInvite", phase: "commit", round: 1, outcome: "stop"))
        #expect(lines.count == 3 && lines.last?.contains("contact.add contactInvite/commit #1 → stop") == true)
        #expect(!lines.contains { $0.contains(Self.phone) })
    }

    /// Review Focus 3: a command whose visual part ends before any model round names no round (round 0 at the
    /// step it was in) — never one left over from an earlier command.
    @Test func aVisualEndBeforeAnyRoundNamesNoRound() throws {
        let box = try Box(ambiguous: false)
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactAdd, goal: "contactMatch", phase: .verify,
                                                         round: 1, outcome: "verify", latencyMs: 5))
        box.handler.desktopCommandVisualEnd = nil  // what the executor does before each command
        box.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { throw AIPlannerVisionError.disabled },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in Self.shot(frame) },
                decide: { _, _, _ in Issue.record("no model request expected"); return .init(step: .stop, candidateID: nil) })
        }
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: true,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "contactSearch", phase: "prepare", round: 0, outcome: "disabled"))
        // The next command starts clean as well: an end before its first visual step names none — neither this
        // command's step nor its last round.
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactAdd, goal: "contactSearch", phase: .prepare,
                                                         round: 1, outcome: "verify", latencyMs: 5))
        box.handler.desktopCommandVisualEnd = nil
        box.handler.markVisualEnd("disabled")
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "none", phase: "none", round: 0, outcome: "disabled"))
    }

    /// A stop the handler then rethrows as a vision error keeps the stop; a new round lets the next end replace it.
    @Test func theFirstEndAfterARoundStands() throws {
        let box = try Box(ambiguous: false)
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactRequestAccept, goal: "requestAcceptButton",
                                                         phase: .commit, round: 1, outcome: "stop", latencyMs: 5))
        box.handler.markVisualEnd("stop")
        box.handler.markVisualEnd("invalidChoice")
        #expect(box.handler.desktopCommandVisualEnd?.outcome == "stop")
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactRequestAccept, goal: "requestAcceptButton",
                                                         phase: .commit, round: 2, outcome: "verify", latencyMs: 5))
        box.handler.markVisualEnd("timeout")
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "requestAcceptButton", phase: "commit", round: 2, outcome: "timeout"))
    }

    /// B54: the standalone window's round uses its own goal; the result round carries the chosen source.
    @Test func theStandaloneWindowRoundUsesItsOwnGoalAndTheMatchCarriesTheSource() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var verification: AXElementHandle?
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }) else { return }
            let title = (try? AXElement(handle: last, backend: box.fake).title()) ?? nil
            if title == "添加", box.panelHandle != nil, verification == nil {
                verification = box.fake.appendChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow())
            } else if title == "发送", let window = verification {
                box.fake.mutate(window, attribute: AXAttribute.role, to: .string(AXRole.group))
            }
        }
        var purposes: [AIPlannerControlPurpose] = []
        var sources: [AIPlannerContactSource?] = []
        var lines: [String] = []
        box.handler.visualRoundLog = { lines.append($0) }
        Self.installRunner(box, passive: { context in
            if case .control(let purpose) = context.goal { purposes.append(purpose) }
            sources.append(context.contactSource)
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        let result = try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                                checkpoint: {}, afterSubmit: {})
        #expect(result["status"] == "requested" && result["inviteWindow"] == "separate")
        #expect(purposes == [.contactSearch, .contactMatch, .contactSendVerification])
        #expect(sources == [nil, .wechat, nil])
        // Review M1: the result-row round's log line names the chosen source (a fixed category), and only it.
        #expect(lines.count == 3 && lines[1].contains("contactMatch/verify #1 → verify") && lines[1].hasSuffix(" source=wechat"))
        #expect(!lines[0].contains("source=") && !lines[2].contains("source="))
    }

    /// An invite inside the Add Customer panel keeps the original goal.
    @Test func anInPanelInviteKeepsTheInviteGoal() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  let panel = box.panelHandle,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            _ = box.fake.appendChild(to: panel, node: AXNode(
                role: AXRole.button, title: "发送添加邀请",
                frame: CGRect(x: 884, y: 702, width: 222, height: 40),
                actions: [AXAction.press]))
        }
        var purposes: [AIPlannerControlPurpose] = []
        Self.installRunner(box, passive: { context in
            guard case .control(let purpose) = context.goal else { return .init(step: .stop, candidateID: nil) }
            purposes.append(purpose)
            return .init(step: purpose == .contactInvite ? .stop : .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(purposes == [.contactSearch, .contactMatch, .contactInvite])
    }

    /// Review I3a: an invite in a popover of the main window keeps the original goal too.
    @Test func aMainWindowPopoverInviteKeepsTheInviteGoal() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  box.panelHandle != nil,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            _ = box.fake.appendChild(to: box.main.handle, node: AXNode(
                role: AXRole.popover, frame: CGRect(x: 800, y: 600, width: 360, height: 180), children: [
                    AXNode(role: AXRole.button, title: "发送添加邀请",
                           frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press]),
                ]))
        }
        var purposes: [AIPlannerControlPurpose] = []
        Self.installRunner(box, passive: { context in
            guard case .control(let purpose) = context.goal else { return .init(step: .stop, candidateID: nil) }
            purposes.append(purpose)
            return .init(step: purpose == .contactInvite ? .stop : .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(purposes == [.contactSearch, .contactMatch, .contactInvite])
    }

    /// Review I1: an invite round that ends before its first model request (here the command's round budget)
    /// names its own step on the command record — never the result-row round before it — through the executor,
    /// with the irreversible point and the command.state fields.
    @Test func anInviteRoundEndingBeforeItsFirstRequestNamesItsOwnStep() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var verification: AXElementHandle?
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  box.panelHandle != nil, verification == nil,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            verification = box.fake.appendChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow())
        }
        var runners = 0
        box.handler.reversibleRunnerFactory = {
            runners += 1
            let budgetSpent = runners == 3  // search, result row, then the invite
            return AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { if budgetSpent { throw AIPlannerVisionError.timeout } },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in Self.shot(frame) },
                decide: { _, _, _ in .init(step: .verify, candidateID: nil) })
        }
        let store = try ControlStore(path: ":memory:")
        var clock: Int64 = 1_000
        let executor = CommandExecutor(store: store, handler: box.handler, now: { clock += 1; return clock },
                                       rateLimiter: nil)
        let record = try executor.submit(method: .contactAdd,
                                         paramsJSON: #"{"phone":"\#(Self.phone)","source":"wechat","idempotencyKey":"b54-i1"}"#,
                                         idempotencyKey: "b54-i1")
        #expect(record.state == .unknown && verification != nil)
        let diagnosis = try #require(record.diagnosisJSON.flatMap {
            try? JSONDecoder().decode(CommandDiagnosis.self, from: Data($0.utf8))
        })
        #expect(diagnosis == CommandDiagnosis(visual: .init(goal: "contactSendVerification", phase: "commit",
                                                            round: 0, outcome: "timeout"),
                                              irreversibleSteps: 1))
        let last = try #require(try store.events(after: 0, limit: 100).last { $0.kind == .commandState })
        #expect(last.payloadJSON.contains(#""visualGoal":"contactSendVerification""#)
                && last.payloadJSON.contains(#""visualRound":"0""#) && last.payloadJSON.contains(#""irreversibleSteps":"1""#))
    }
}

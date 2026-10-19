import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("WeComActions.submit on fake")
struct SubmitTests {
    let composerPath = [0, 33, 6, 0, 2, 0]
    let messageTablePath = [0, 33, 6, 0, 0, 0]

    func store() throws -> FileCheckpointStore {
        try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-submit-\(UUID().uuidString)"))
    }

    func actions(phase: ActionPolicy.Phase = .phase1, allowedTargets: [String] = ["文件传输助手"]) -> WeComActions {
        WeComActions(policy: ActionPolicy(allowedTargets: Set(allowedTargets), enabled: [.submit], phase: phase),
                     verifyTimeout: 0.3, verifyInterval: 0.02)
    }

    /// Simulates the client sending: appends an outbound row with `text` and clears the composer.
    func installSendReaction(on fake: FakeAXBackend, text: String, appendRow: Bool,
                             direction: MessageDirection = .outbound) throws {
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        fake.reactions["action:AXConfirm"] = {
            if appendRow {
                var rows = existing.children
                let body: CGRect
                switch direction {
                case .inbound: body = CGRect(x: 370, y: 160, width: 94, height: 15)
                case .outbound: body = CGRect(x: 1800, y: 160, width: 94, height: 15)
                case .unknown: body = CGRect(x: 650, y: 160, width: 900, height: 15)
                }
                rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                        AXNode(role: AXRole.textArea, value: .string(text), frame: body),
                    ]),
                ]), at: rows.count - 1)
                fake.replaceChildren(of: table, with: rows)
            }
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
    }

    @Test func axConfirmUnsupportedFailsAndClears() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.3)
        #expect(out.state == .failed)
        #expect(out.reason?.contains("unsupported") == true)
        #expect(fake.recordedSets.map { $0.value } == [.string("p1"), .string("")])
        #expect(fake.recordedActions.isEmpty)
        #expect(try cps.load(id: out.checkpointID)?.state == .failed)
        #expect(try cps.pending().isEmpty)
    }

    @Test func axConfirmWithBubbleSucceeds() throws {
        let fake = try Fixtures.mainWindow()
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.setActions(of: composer, to: [AXAction.showMenu, AXAction.confirm])
        try installSendReaction(on: fake, text: "p1", appendRow: true)
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 1)
        #expect(out.state == .succeeded)
        #expect(out.evidence?.contains("dir=outbound") == true)
        #expect(fake.recordedActions.map(\.action) == [AXAction.confirm])
        #expect((out.latencyMs ?? -1) >= 0)
        #expect(out.composerAfter == 0)
        #expect(try cps.load(id: out.checkpointID)?.state == .succeeded)
    }

    @Test(arguments: [MessageDirection.inbound, .unknown])
    func sameTextWithoutOutboundEvidenceStaysUnknown(direction: MessageDirection) throws {
        let fake = try Fixtures.mainWindow()
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("imctl测试群"))
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.setActions(of: composer, to: [AXAction.confirm])
        try installSendReaction(on: fake, text: "p1", appendRow: true, direction: direction)
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions(allowedTargets: ["imctl测试群"]).submit(
            text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.1, pollInterval: 0.02)
        #expect(out.state == .unknown)
        #expect(out.evidence == nil)
        #expect(try cps.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func renumberedOldTextCannotConfirmOurSend() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        let body = try #require(fake.handle(atPath: messageTablePath + [0, 0, 1]))
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.mutate(body, attribute: AXAttribute.value, to: .string("p1"))
        fake.setActions(of: composer, to: [AXAction.confirm])
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        fake.reactions["action:AXConfirm"] = {
            let empty = AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 140, width: 1609, height: 10),
                               children: [AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 140, width: 1609, height: 10))])
            var rows = existing.children
            rows.insert(empty, at: 0)
            // Keep the edited old row while shifting only its table index.
            rows[1].children[0].children[1].value = .string("p1")
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader,
                                       checkpoints: try store(), timeout: 0.1, pollInterval: 0.02)
        #expect(out.state == .unknown)
    }

    @Test func prependedIdenticalTextCannotConfirmOurSend() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        let body = try #require(fake.handle(atPath: messageTablePath + [0, 0, 1]))
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.mutate(body, attribute: AXAttribute.value, to: .string("p1"))
        fake.setActions(of: composer, to: [AXAction.confirm])
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        fake.reactions["action:AXConfirm"] = {
            var rows = existing.children
            rows[0].children[0].children[1].value = .string("p1")
            rows.insert(rows[0], at: 0)
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader,
                                       checkpoints: try store(), timeout: 0.1, pollInterval: 0.02)
        #expect(out.state == .unknown)
    }

    @Test func partialBaselineStopsBeforeComposerWrite() throws {
        let fake = try Fixtures.mainWindow()
        let body = try #require(fake.handle(atPath: messageTablePath + [0, 0, 1]))
        fake.onRead = { handle, attribute in
            guard attribute == AXAttribute.value else { return }
            fake.injectedFailures["get:AXValue"] = handle == body
                ? .apiFailure(code: -25201, operation: "get AXValue") : nil
        }
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        #expect(throws: ActionError.actionUnavailable("incomplete message baseline")) {
            try actions().submit(text: "p1", strategy: .axConfirm, reader: reader,
                                 checkpoints: cps, timeout: 0.1, pollInterval: 0.02)
        }
        #expect(fake.recordedSets.isEmpty)
        #expect(try cps.pending().isEmpty)
    }

    @Test func switchedConversationAfterSubmitCannotConfirmTheOldTarget() throws {
        let fake = try Fixtures.mainWindow()
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.setActions(of: composer, to: [AXAction.confirm])
        try installSendReaction(on: fake, text: "p1", appendRow: true)
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let hooks = SubmitHooks(afterIrreversible: {
            fake.mutate(title, attribute: AXAttribute.value, to: .string("imctl测试群"))
        })
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader,
                                       checkpoints: cps, timeout: 0.1, pollInterval: 0.02, hooks: hooks)
        #expect(out.state == .unknown)
        #expect(out.reason?.contains("active conversation changed") == true)
        #expect(try cps.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func composerEmptiedWithoutBubbleIsUnknownAndLeftAlone() throws {
        let fake = try Fixtures.mainWindow()
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.setActions(of: composer, to: [AXAction.confirm])
        try installSendReaction(on: fake, text: "p1", appendRow: false)
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.3)
        #expect(out.state == .unknown)
        #expect(fake.recordedSets.count == 1)
        #expect(try cps.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func newlineWithoutEffectFailsAndClears() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions().submit(text: "p1", strategy: .newline, reader: reader, checkpoints: cps, timeout: 0.3)
        #expect(out.state == .failed)
        #expect(fake.recordedSets.map { $0.value } == [.string("p1"), .string("p1\n"), .string("")])
        #expect(try reader.composerValue() == "")
    }

    @Test func targetDriftBetweenComposeAndSubmitAbortsBeforeIrreversibleStep() throws {
        let fake = try Fixtures.mainWindow()
        let composer = try #require(fake.handle(atPath: composerPath))
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.setActions(of: composer, to: [AXAction.confirm])
        // The human switches conversation right after our text lands in the composer.
        fake.reactions["set:AXValue"] = { fake.mutate(title, attribute: AXAttribute.value, to: .string("someone")) }
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions().submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.3)
        #expect(out.state == .failed)
        #expect(out.reason?.contains("drifted") == true)
        #expect(fake.recordedActions.isEmpty)
        // The active conversation changed: clearing the stale handle could erase
        // a human draft. Leave the staged text for manual inspection.
        #expect(fake.recordedSets.map { $0.value } == [.string("p1")])
        #expect(try cps.load(id: out.checkpointID)?.state == .failed)
    }

    @Test func draftBlocksSubmitBeforeCheckpoint() throws {
        let fake = try Fixtures.mainWindow()
        let composer = try #require(fake.handle(atPath: composerPath))
        fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        #expect(throws: ActionError.localGuard("composer not empty")) {
            try actions().submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.3)
        }
        #expect(try cps.pending().isEmpty)
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func phase0PolicyForbidsSubmit() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        #expect(throws: PolicyError.phaseForbids(.submit)) {
            try actions(phase: .phase0).submit(text: "p1", strategy: .axConfirm, reader: reader, checkpoints: cps, timeout: 0.3)
        }
    }
}

@Suite("WeComActions.submit context-menu / send-button on fake")
struct SubmitDiscoveryTests {
    let composerPath = [0, 33, 6, 0, 2, 0]
    let messageTablePath = [0, 33, 6, 0, 0, 0]

    func store() throws -> FileCheckpointStore {
        try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-submit2-\(UUID().uuidString)"))
    }

    func actions() -> WeComActions {
        WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.submit], phase: .phase1),
                     verifyTimeout: 0.3, verifyInterval: 0.02)
    }

    func bubbleRows(text: String) throws -> [AXNode] {
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var rows = existing.children
        rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.textArea, value: .string(text), frame: CGRect(x: 1800, y: 160, width: 94, height: 15)),
            ]),
        ]), at: rows.count - 1)
        return rows
    }

    @Test func contextMenuWithoutSendItemIsCancelledAndFails() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        fake.reactions["action:AXShowMenu"] = {
            let menu = AXNode(role: AXRole.menu, actions: [AXAction.cancel], children: [
                AXNode(role: AXRole.menuItem, title: "复制", actions: [AXAction.press]),
                AXNode(role: AXRole.menuItem, title: "粘贴", actions: [AXAction.press]),
            ])
            fake.appendChild(to: window, node: menu)
        }
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .contextMenu, reader: reader, checkpoints: try store(), timeout: 0.3)
        #expect(out.state == .failed)
        #expect(out.reason?.contains("no send item") == true)
        #expect(out.details["menuItems"] == "复制 | 粘贴")
        #expect(fake.recordedActions.map(\.action) == [AXAction.showMenu, AXAction.cancel])
        #expect(try reader.composerValue() == "")
    }

    @Test func contextMenuWithSendItemPressesItAndConfirms() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let rows = try bubbleRows(text: "p1")
        fake.reactions["action:AXShowMenu"] = {
            let menu = AXNode(role: AXRole.menu, actions: [AXAction.cancel], children: [
                AXNode(role: AXRole.menuItem, title: "发送", actions: [AXAction.press]),
            ])
            fake.appendChild(to: window, node: menu)
        }
        fake.reactions["action:AXPress"] = {
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .contextMenu, reader: reader, checkpoints: try store(), timeout: 1)
        #expect(out.state == .succeeded)
        #expect(out.details["menuItems"] == "发送")
        #expect(fake.recordedActions.map(\.action) == [AXAction.showMenu, AXAction.press])
    }

    @Test func sendButtonAppearingAfterComposeIsPressed() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let rows = try bubbleRows(text: "p1")
        var added = false
        fake.reactions["set:AXValue"] = {
            guard !added else { return }
            added = true
            let button = AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 1850, y: 1150, width: 60, height: 30), actions: [AXAction.press])
            fake.appendChild(to: window, node: button)
        }
        fake.reactions["action:AXPress"] = {
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .sendButton, reader: reader, checkpoints: try store(), timeout: 1)
        #expect(out.state == .succeeded, "\(out.reason ?? "")")
        #expect(out.details["pressed"]?.hasPrefix("发送") == true)
    }

    @Test func sendButtonAbsentFails() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let out = try actions().submit(text: "p1", strategy: .sendButton, reader: reader, checkpoints: try store(), timeout: 0.3)
        #expect(out.state == .failed)
        #expect(out.reason?.contains("no send button") == true)
        #expect(try reader.composerValue() == "")
    }

    @Test func ambiguousSendButtonsRequireAConstrainedVisualChoice() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let rows = try bubbleRows(text: "p1")
        var buttons: [AXElementHandle] = []
        fake.reactions["set:AXValue"] = {
            guard buttons.isEmpty else { return }
            for x in [1780.0, 1850.0] {
                if let handle = fake.appendChild(to: window, node: AXNode(
                    role: AXRole.button, title: "发送", frame: CGRect(x: x, y: 1150, width: 60, height: 30),
                    actions: [AXAction.press]
                )) { buttons.append(handle) }
            }
        }
        fake.reactions["action:AXPress"] = {
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        var actions = actions()
        var calls = 0
        actions.visualSelect = { _, goal, kinds, title, eligible, _ in
            calls += 1
            if case .control(.sendButton) = goal {} else { Issue.record("wrong send goal") }
            #expect(kinds == [.press] && title == "文件传输助手")
            #expect(eligible.count == 2)
            let element = AXElement(handle: try #require(buttons.last), backend: fake)
            return AIPlannerCandidate(id: "C1", kind: .press, element: element,
                                      role: AXRole.button, frame: try #require(try element.frame()))
        }
        let out = try actions.submit(text: "p1", strategy: .sendButton, reader: reader,
                                     checkpoints: try store(), timeout: 1)
        #expect(out.state == .succeeded && calls == 1)
        #expect(fake.recordedActions.map(\.handle) == [try #require(buttons.last)])
    }

    @Test func uncertainSendButtonSelectionFailsBeforePress() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        var added = false
        fake.reactions["set:AXValue"] = {
            guard !added else { return }
            added = true
            for x in [1780.0, 1850.0] {
                fake.appendChild(to: window, node: AXNode(role: AXRole.button, title: "发送",
                    frame: CGRect(x: x, y: 1150, width: 60, height: 30), actions: [AXAction.press]))
            }
        }
        let reader = try WeComReader(window: fake.rootElement)
        var actions = actions()
        actions.visualSelect = { _, _, _, _, _, _ in nil }
        let cps = try store()
        let out = try actions.submit(text: "p1", strategy: .sendButton, reader: reader,
                                     checkpoints: cps, timeout: 0.1)
        #expect(out.state == .failed && out.reason == "send button visual selection unavailable")
        #expect(fake.recordedActions.isEmpty)
        #expect(try cps.load(id: out.checkpointID)?.state == .failed)
    }

    @Test func revokedVisualSendGateNeverPressesOrSubmits() throws {
        let fake = try Fixtures.mainWindow()
        let window = fake.rootHandle
        var buttons: [AXElementHandle] = []
        fake.reactions["set:AXValue"] = {
            guard buttons.isEmpty else { return }
            for x in [1780.0, 1850.0] {
                if let handle = fake.appendChild(to: window, node: AXNode(
                    role: AXRole.button, title: "发送", frame: CGRect(x: x, y: 1150, width: 60, height: 30),
                    actions: [AXAction.press]
                )) { buttons.append(handle) }
            }
        }
        let reader = try WeComReader(window: fake.rootElement)
        var actions = actions()
        var revoked = false
        actions.visualActionGate = { kind, title in
            #expect(kind == .submit && title == "文件传输助手")
            if revoked { throw AIPlannerVisionError.disabled }
        }
        actions.visualSelect = { _, _, _, _, _, _ in
            revoked = true
            let button = AXElement(handle: try #require(buttons.last), backend: fake)
            return AIPlannerCandidate(id: "C1", kind: .press, element: button,
                                      role: AXRole.button, frame: try #require(try button.frame()))
        }
        let checkpoints = try store()
        let outcome = try actions.submit(text: "p1", strategy: .sendButton, reader: reader,
                                         checkpoints: checkpoints, timeout: 0.1)
        #expect(outcome.state == .failed)
        #expect(fake.recordedActions.isEmpty)
        #expect(try checkpoints.load(id: outcome.checkpointID)?.state == .failed)
    }
}

@Suite("WeComActions.submit enter strategies on fake")
struct SubmitEnterTests {
    let composerPath = [0, 33, 6, 0, 2, 0]
    let messageTablePath = [0, 33, 6, 0, 0, 0]

    func store() throws -> FileCheckpointStore {
        try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-submit-enter-\(UUID().uuidString)"))
    }

    @Test func enterPostsOneReturnToClientPidAndSucceedsWithBubble() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: messageTablePath))
        let composer = try #require(fake.handle(atPath: composerPath))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var posted: [(pid_t, Bool)] = []
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.submit], phase: .phase1),
                                   verifyTimeout: 0.3, verifyInterval: 0.02)
        actions.postReturnKey = { pid, control in
            posted.append((pid, control))
            var rows = existing.children
            rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.textArea, value: .string("p1"), frame: CGRect(x: 1800, y: 160, width: 94, height: 15)),
                ]),
            ]), at: rows.count - 1)
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions.submit(text: "p1", strategy: .enterKey, reader: reader, checkpoints: cps, timeout: 1)
        #expect(out.state == .succeeded)
        #expect(posted.count == 1 && posted[0].0 == 4242 && posted[0].1 == false)
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.value, AXAttribute.focused])
        #expect(try cps.load(id: out.checkpointID)?.state == .succeeded)
    }

    /// Shared shape of the front tests: another app (999) is active; setting AXFrontmost (and, when
    /// `focusActivates`, AXFocused on the composer) makes the client (4242) active; a key only lands
    /// while the client is active, and then produces the bubble.
    func frontFixture(focusActivates: Bool) throws -> (WeComActions, FakeAXBackend, AXElement, FrontLog, () -> Int) {
        let windowNode = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, settable: [AXAttribute.frontmost], children: [windowNode]))
        let window = try #require(fake.element(atPath: [0]))
        let table = try #require(fake.handle(atPath: [0] + messageTablePath))
        let composer = try #require(fake.handle(atPath: [0] + composerPath))
        let existing = try #require(windowNode.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        let front = FrontLog(current: 999)
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.submit], phase: .phase1),
                                   verifyTimeout: 0.3, verifyInterval: 0.02)
        actions.frontmostPid = { front.current }
        actions.restoreFrontmost = { front.restored.append($0) }
        fake.reactions["set:\(AXAttribute.frontmost)"] = { front.current = 4242 }
        if focusActivates { fake.reactions["set:\(AXAttribute.focused)"] = { front.current = 4242 } }
        actions.postReturnKey = { _, _ in
            guard front.current == 4242 else { return }          // an inactive client drops the key
            front.delivered += 1
            var rows = existing.children
            rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                    AXNode(role: AXRole.textArea, value: .string("p2"), frame: CGRect(x: 1800, y: 160, width: 94, height: 15)),
                ]),
            ]), at: rows.count - 1)
            fake.replaceChildren(of: table, with: rows)
            fake.mutate(composer, attribute: AXAttribute.value, to: .string(""))
        }
        return (actions, fake, window, front, { fake.recordedSets.filter { $0.attribute == AXAttribute.frontmost }.count })
    }

    /// Live 2026-09-15 15:56: a console send failed with the text still in the composer because the
    /// Return was posted while another app was active. The client is brought to front first, then given back.
    @Test func enterBringsTheClientToFrontFirstAndHandsFocusBack() throws {
        let (actions, _, window, front, frontSets) = try frontFixture(focusActivates: false)
        let out = try actions.submit(text: "p2", strategy: .enterKey, reader: try WeComReader(window: window), checkpoints: try store(), timeout: 1)
        #expect(out.state == .succeeded && front.delivered == 1 && out.details["front"] == "brought")
        #expect(frontSets() == 1 && front.restored == [999])
    }

    /// Live 2026-09-16: focusing the composer already activates the client, so the "previous" app must
    /// be read before that — read afterwards it named the client itself and nothing was handed back.
    @Test func enterHandsFocusBackEvenWhenFocusingTheComposerActivatedTheClient() throws {
        let (actions, _, window, front, frontSets) = try frontFixture(focusActivates: true)
        let out = try actions.submit(text: "p2", strategy: .enterKey, reader: try WeComReader(window: window), checkpoints: try store(), timeout: 1)
        #expect(out.state == .succeeded && front.delivered == 1 && out.details["front"] == "kept")
        #expect(frontSets() == 0 && front.restored == [999])
    }

    @Test func ctrlEnterSetsControlFlagAndFailsWithoutBubble() throws {
        let fake = try Fixtures.mainWindow()
        var posted: [(pid_t, Bool)] = []
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.submit], phase: .phase1),
                                   verifyTimeout: 0.3, verifyInterval: 0.02)
        actions.postReturnKey = { pid, control in posted.append((pid, control)) }
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try store()
        let out = try actions.submit(text: "p1", strategy: .ctrlEnterKey, reader: reader, checkpoints: cps, timeout: 0.3)
        #expect(out.state == .failed)
        #expect(posted.count == 1 && posted[0].1 == true)
        #expect(try reader.composerValue() == "")
    }
}

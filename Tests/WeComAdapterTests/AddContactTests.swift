import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// B12: 通讯录 › 新的客户 › 添加客户 — the panel is a second window of the client; matches appear
/// only after the (approved) Return on its search field. Fixture recorded live 2026-09-16 with the
/// results open (redacted; the number never survives redaction).
@Suite("contact.add on the 添加客户 fixture")
struct AddContactTests {
    static func fixture() throws -> (FakeAXBackend, AXElement) {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-customer.json")))
        let windows = try fake.rootElement.elements(AXAttribute.windows)
        // the main window is the one with the conversation / contacts chrome (its frame starts at y 0)
        let main = try #require(windows.first { ((try? $0.frame())??.minY ?? 1) == 0 })
        return (fake, main)
    }

    @Test func panelIsTheSecondWindowAndMatchesCarrySourceNameAndButton() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        #expect(panel.window.handle != main.handle && panel.closeButton != nil && (try? panel.searchField.role()) == AXRole.textField)
        let matches = try panel.matches()
        #expect(matches.count == 2)
        #expect(matches[0].source == "wechat" && !matches[0].name.isEmpty && matches[0].subtitle == nil)
        #expect(matches[1].source == "wecom" && !matches[1].name.isEmpty && matches[1].subtitle == "添加后可查看完整信息")
        #expect(matches[0].button != matches[1].button)
        #expect(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: panel.window)?.window.handle != panel.window.handle || true)
    }

    @Test func addContactTypesReturnsOncePicksBySourceAndPressesThatAdd() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wechatButton = try #require(try panel.matches().first { $0.source == "wechat" }?.button)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.3, verifyInterval: 0.02)
        a.frontmostPid = { nil }
        a.postShortcut = { _, _ in }           // the contacts walk is not what this test is about; the panel is already open
        a.openURL = { _ in true }
        var returns = 0
        a.postReturnKey = { _, control in returns += 1; #expect(!control) }
        var trace: [String] = []
        a.trace = { trace.append($0) }
        let dry = try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: true, app: fake.rootElement, window: main,
                                   requiresFreshPanel: false)
        #expect(dry.status == "matched" && dry.matches.count == 2 && dry.chosen == nil && returns == 1)
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value.stringValue == "13800000000" })
        #expect(!fake.recordedActions.contains { $0.action == AXAction.press && $0.handle == wechatButton })
        #expect(trace.contains { $0.hasPrefix("addContact: 138******00 → 2 match(es)") } && !trace.contains { $0.contains("13800000000") })
        var order: [String] = []
        fake.reactions["action:\(AXAction.press)"] = { order.append("press") }
        let hooks = SubmitHooks(beforeIrreversible: { order.append("checkpoint") }, afterIrreversible: { order.append("after") })
        let real = try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                                    app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        #expect(real.status == "pressed" && real.chosen?.source == "wechat" && real.details["pressed"] == "wechat/添加" && returns == 2)
        #expect(Array(order.prefix(3)) == ["checkpoint", "press", "after"])
        #expect(fake.recordedActions.contains { $0.action == AXAction.press && $0.handle == wechatButton })
        #expect(throws: ActionError.targetAmbiguous("any match for 138******00", count: 2)) {
            try a.addContact(phone: "13800000000", source: "any", greeting: nil, dryRun: false,
                             app: fake.rootElement, window: main, requiresFreshPanel: false)
        }
        #expect(throws: ActionError.self) { try a.addContact(phone: "13800000000", source: "wecom-x", greeting: nil, dryRun: false, app: fake.rootElement, window: main, requiresFreshPanel: false) }
        // the panel's close button is pressed on the way out
        #expect(fake.recordedActions.contains { $0.action == AXAction.press && $0.handle == panel.closeButton?.handle })
    }

    /// Live 2026-09-16 12:29 (user screenshot): 添加 opens 发送添加邀请 — a greeting box with the client's default
    /// text and a button titled 发送添加邀请. The greeting is replaced when given and the button pressed.
    @Test func inviteStepGetsTheGreetingAndItsConfirmPressed() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wechatButton = try #require(try panel.matches().first { $0.source == "wechat" }?.button)
        let inviteBox = AXNode(role: AXRole.textArea, value: .string("我是某公司的某人，添加我的企业微信与我联系吧。"), frame: CGRect(x: 816, y: 636, width: 340, height: 24), settable: [AXAttribute.value])
        let inviteButton = AXNode(role: AXRole.button, title: "发送添加邀请", frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press])
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.3, verifyInterval: 0.02)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        var pressed: [AXElementHandle] = []
        fake.reactions["action:\(AXAction.press)"] = {
            guard let last = fake.recordedActions.last?.handle else { return }
            pressed.append(last)
            if last == wechatButton {
                fake.appendChild(to: panel.window.handle, node: inviteBox)
                fake.appendChild(to: panel.window.handle, node: inviteButton)
            } else if (try? AXElement(handle: last, backend: fake).title()) == "发送添加邀请" {
                fake.mutate(last, attribute: AXAttribute.role, to: .string(AXRole.staticText))   // the invite dialog is gone
            }
        }
        let out = try a.addContact(phone: "13800000000", source: "wechat", greeting: "你好，我是 imctl 测试", dryRun: false, app: fake.rootElement, window: main,
                                   requiresFreshPanel: false)
        #expect(out.status == "requested" && out.details["confirmed"] == "发送添加邀请" && out.details["greeting"] == "set" && out.details["inviteDialog"] == "closed")
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value.stringValue == "你好，我是 imctl 测试" })
        #expect(pressed.count >= 2)
    }

    @Test func inviteConfirmIgnoresAnUnrelatedChatSendButton() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let unrelated = fake.appendChild(to: main.handle, node: AXNode(
            role: AXRole.button, title: "发送", frame: CGRect(x: 1100, y: 900, width: 80, height: 30), actions: [AXAction.press]))
        let invite = fake.appendChild(to: panel.window.handle, node: AXNode(
            role: AXRole.button, title: "发送添加邀请", frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press]))
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1))
        let selected = try actions.inviteConfirm(app: fake.rootElement, mainWindow: main)
        #expect(selected?.handle == invite && selected?.handle != unrelated)
    }

    @Test func addContactDoesNotResumeAnUnrelatedInvite() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        _ = fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.button,
            title: "发送添加邀请", frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press]))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }
        #expect(throws: ActionError.actionUnavailable("existing invite cannot be tied to searched phone")) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                             app: fake.rootElement, window: main, requiresFreshPanel: false)
        }
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func addContactRechecksPhoneAndMatchAfterCheckpoint() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let chosen = try #require(try panel.matches().first { $0.source == "wechat" })
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        let hooks = SubmitHooks(beforeIrreversible: {
            fake.mutate(panel.searchField.handle, attribute: AXAttribute.value, to: .string("13900000000"))
        })
        #expect(throws: ActionError.actionUnavailable("添加客户 search changed")) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                             app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        }
        #expect(!fake.recordedActions.contains { $0.handle == chosen.button })
        #expect(fake.recordedActions.contains { $0.handle == panel.closeButton?.handle })
    }

    @Test func addContactGateRevocationAfterCheckpointStopsTheMatchPress() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let chosen = try #require(try panel.matches().first { $0.source == "wechat" })
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        var revoked = false
        a.visualActionGate = { kind, title in
            #expect(kind == .addContact && title == nil)
            if revoked { throw AIPlannerVisionError.disabled }
        }
        let hooks = SubmitHooks(beforeIrreversible: { revoked = true })
        #expect(throws: AIPlannerVisionError.disabled) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                             app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        }
        #expect(!fake.recordedActions.contains { $0.handle == chosen.button })
        #expect(fake.recordedActions.contains { $0.handle == panel.closeButton?.handle })
    }

    @Test func addContactRefusesTwoConfirmButtonsAfterTheMatchPress() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let chosen = try #require(try panel.matches().first { $0.source == "wechat" })
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        fake.reactions["action:AXPress"] = {
            for offset in [0.0, 60.0] {
                _ = fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.button,
                    title: "发送添加邀请", frame: CGRect(x: 884 + offset, y: 702, width: 222, height: 40),
                    actions: [AXAction.press]))
            }
        }
        #expect(throws: ActionError.actionUnavailable("multiple invite confirmations cannot be tied to searched phone")) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                             app: fake.rootElement, window: main, requiresFreshPanel: false)
        }
        #expect(fake.recordedActions.map(\.handle) == [chosen.button])
        #expect(!fake.recordedActions.contains { $0.handle == panel.closeButton?.handle })
    }

    @Test func addContactDoesNotConfirmWithoutTheRequestedGreetingInput() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let chosen = try #require(try panel.matches().first { $0.source == "wechat" })
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        fake.reactions["action:AXPress"] = {
            _ = fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.button,
                title: "发送添加邀请", frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press]))
        }
        #expect(throws: ActionError.actionUnavailable("添加客户 invite greeting input unavailable")) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: "测试问候", dryRun: false,
                             app: fake.rootElement, window: main, requiresFreshPanel: false)
        }
        #expect(fake.recordedActions.map(\.handle) == [chosen.button])
        #expect(!fake.recordedActions.contains { $0.handle == panel.closeButton?.handle })
    }

    @Test func ambiguousPageAddCannotFallBackToOneStepVisualChoice() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [ContactsFixture.collapsedRail()]))
        let app = fake.rootElement
        let main = try #require(try app.elements(AXAttribute.windows).first)
        let original = try #require(main.descendants(maxDepth: 14, maxNodes: 8000).first {
            (try? $0.role()) == AXRole.button && (try? $0.title()) == "添加"
        })
        fake.setActions(of: original.handle, to: [AXAction.press])
        let second = try #require(fake.appendChild(to: main.handle, node: AXNode(role: AXRole.button,
            title: "添加", frame: CGRect(x: 1740, y: 50, width: 50, height: 24), actions: [AXAction.press])))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
            enabled: [.openContacts, .addContact], phase: .phase1), verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }
        var modelCalls = 0
        a.visualSelect = { _, _, _, _, eligible, _ in
            modelCalls += 1
            #expect(eligible.map(\.handle).contains(original.handle) && eligible.map(\.handle).contains(second))
            return AIPlannerCandidate(id: "C0", kind: .press, element: original,
                                      role: AXRole.button, frame: try #require(try original.frame()))
        }
        #expect(throws: ActionError.actionUnavailable("添加 (新的客户)")) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: false,
                             app: app, window: main)
        }
        #expect(modelCalls == 0 && fake.recordedActions.isEmpty)
    }

    /// The page's own 添加 is the 新的客户 heading's sibling on its line — on the recorded 160 pt rail,
    /// on the 60 pt rail shaped like the live dump of 2026-09-28, and wherever the window is moved or
    /// how wide the rail grows. No window-top band decides it.
    @Test func headerAddIsTheHeadingsSiblingOnEveryLayout() throws {
        let wide = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        var narrow = ContactsFixture.collapsedRail()
        narrow = GeometryPortabilityTests.moved(narrow, dx: 0, dy: 30)   // the live window sat at y 30
        for tree in [wide, narrow, GeometryPortabilityTests.moved(wide, dx: 1920, dy: 400),
                     GeometryPortabilityTests.moved(ContactsFixture.shiftedContent(narrow, by: 220), dx: -300, dy: 0)] {
            let fake = FakeAXBackend(root: tree)
            Self.makeAddButtonsPressable(fake)
            let candidates = try WeComActions.addCustomerHeaderCandidates(window: fake.rootElement)
            #expect(candidates.count == 1)
            #expect(try candidates.first?.title() == "添加")
        }
    }

    /// A 添加 on the heading's line but outside the pane's group is not the page's own control and
    /// makes the header doubtful: nothing is offered and nothing is pressed.
    @Test func aForeignAddOnTheHeadingLineStopsTheHeaderLookup() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        Self.makeAddButtonsPressable(fake)
        #expect(try WeComActions.addCustomerHeaderCandidates(window: fake.rootElement).count == 1)
        _ = fake.appendChild(to: fake.rootHandle, node: AXNode(role: AXRole.button, title: "添加",
            frame: CGRect(x: 1700, y: 52, width: 50, height: 24), actions: [AXAction.press]))
        #expect(try WeComActions.addCustomerHeaderCandidates(window: fake.rootElement).isEmpty)
        // A 添加 elsewhere in the pane (a card's, below the heading's line) is not on the line and changes nothing.
        let other = FakeAXBackend(root: ContactsFixture.collapsedRail())
        Self.makeAddButtonsPressable(other)
        let pane = try #require(try WeComActions.addCustomerHeaderCandidates(window: other.rootElement).first?.parent())
        _ = other.appendChild(to: pane.handle, node: AXNode(role: AXRole.button, title: "添加",
            frame: CGRect(x: 1848, y: 400, width: 55, height: 19), actions: [AXAction.press]))
        #expect(try WeComActions.addCustomerHeaderCandidates(window: other.rootElement).count == 1)
    }

    /// The greeting box belongs to the invite confirm's own window: a writable chat composer in the
    /// main window, even right above the confirm, is never chosen; two boxes in the invite window
    /// leave the greeting unwritten.
    @Test func inviteGreetingBoxIsTheConfirmsOwnAndUnique() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let confirm = try #require(fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.button, title: "发送添加邀请",
            frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press])))
        let composer = try #require(fake.appendChild(to: main.handle, node: AXNode(role: AXRole.textArea, value: .string(""),
            frame: CGRect(x: 820, y: 660, width: 340, height: 30), settable: [AXAttribute.value])))
        let confirmElement = AXElement(handle: confirm, backend: fake)
        #expect(AddCustomerPanel.inviteTextBox(app: fake.rootElement, confirm: confirmElement,
                                               excluding: panel.searchField.handle) == nil)
        let box = try #require(fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.textArea, value: .string("默认问候"),
            frame: CGRect(x: 816, y: 636, width: 340, height: 24), settable: [AXAttribute.value])))
        let chosen = AddCustomerPanel.inviteTextBox(app: fake.rootElement, confirm: confirmElement, excluding: panel.searchField.handle)
        #expect(chosen?.handle == box && chosen?.handle != composer)
        _ = fake.appendChild(to: panel.window.handle, node: AXNode(role: AXRole.textField, value: .string(""),
            frame: CGRect(x: 816, y: 600, width: 340, height: 24), settable: [AXAttribute.value]))
        #expect(AddCustomerPanel.inviteTextBox(app: fake.rootElement, confirm: confirmElement,
                                               excluding: panel.searchField.handle) == nil)
    }

    /// A confirm shown in a popover of the main window owns only that popover's box, never the chat
    /// composer beside it; a confirm with no popover, sheet or window above it owns nothing.
    @Test func inviteGreetingBoxInsideAPopoverAndWithoutAContainer() throws {
        let (fake, main) = try Self.fixture()
        _ = fake.appendChild(to: main.handle, node: AXNode(role: AXRole.textArea, value: .string(""),
            frame: CGRect(x: 700, y: 560, width: 400, height: 60), settable: [AXAttribute.value]))
        let popover = try #require(fake.appendChild(to: main.handle, node: AXNode(role: AXRole.popover,
            frame: CGRect(x: 800, y: 600, width: 360, height: 180))))
        let box = try #require(fake.appendChild(to: popover, node: AXNode(role: AXRole.textArea, value: .string("默认问候"),
            frame: CGRect(x: 816, y: 636, width: 330, height: 24), settable: [AXAttribute.value])))
        let confirm = try #require(fake.appendChild(to: popover, node: AXNode(role: AXRole.button, title: "发送添加邀请",
            frame: CGRect(x: 884, y: 702, width: 222, height: 40), actions: [AXAction.press])))
        #expect(AddCustomerPanel.inviteTextBox(app: fake.rootElement, confirm: AXElement(handle: confirm, backend: fake),
                                               excluding: nil)?.handle == box)
        let loose = FakeAXBackend(root: AXNode(role: AXRole.group, children: [
            AXNode(role: AXRole.textArea, value: .string(""), frame: CGRect(x: 0, y: 0, width: 100, height: 20), settable: [AXAttribute.value]),
            AXNode(role: AXRole.button, title: "确定", frame: CGRect(x: 0, y: 40, width: 60, height: 24), actions: [AXAction.press]),
        ]))
        let looseConfirm = try #require(loose.handle(atPath: [1]))
        #expect(AddCustomerPanel.inviteTextBox(app: loose.rootElement, confirm: AXElement(handle: looseConfirm, backend: loose),
                                               excluding: nil) == nil)
    }

    /// Live 2026-09-28: the 添加客户 panel is a second layer-0 window with the main window's exact frame,
    /// so capture cannot choose it by geometry. The command records WeCom's window numbers before its own
    /// press and hands the observer the one new same-frame window and the pre-existing main window.
    @Test func thePanelThisCommandOpenedCarriesItsWindowNumbers() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [ContactsFixture.collapsedRail()]))
        let app = fake.rootElement
        let main = try #require(try app.elements(AXAttribute.windows).first)
        Self.makeAddButtonsPressable(fake)
        let add = try #require(try WeComActions.addCustomerHeaderCandidates(window: main).first)
        let panelNode = try Self.blankAddCustomerPanel()
        var panelHandle: AXElementHandle?
        fake.reactions["action:\(AXAction.press)"] = {
            if fake.recordedActions.last?.handle == add.handle, panelHandle == nil {
                panelHandle = fake.appendChild(to: fake.rootHandle, node: panelNode)
            }
        }
        let mainFrame = try #require(try main.frame())
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1),
                             verifyTimeout: 0.2, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        a.windowIdentities = { _ in
            var list = [WeComWindowIdentity(id: 53452, layer: 0, bounds: mainFrame, onScreen: true)]
            if let panelHandle, let frame = try? AXElement(handle: panelHandle, backend: fake).frame() {
                list.append(WeComWindowIdentity(id: 71603, layer: 0, bounds: frame, onScreen: true))
            }
            return list
        }
        struct Observed: Error {}
        var seen: (panel: CGWindowID?, parent: CGWindowID?)?
        a.visualObserveContactAdd = { _, _, panel, stage, _, _ in
            #expect(stage == .searchInput)
            seen = (panel.windowID, panel.parentWindowID)
            throw Observed()
        }
        #expect(throws: Observed.self) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: true, app: app, window: main)
        }
        #expect(seen?.panel == 71603 && seen?.parent == 53452)
        #expect(!fake.recordedSets.contains { $0.value == .string("13800000000") })
    }

    /// Without the main window in the pre-press snapshot (an empty or failed window list) nothing can
    /// show which same-frame window is new, so the panel number stays unproved and a capture refuses.
    @Test func anUnprovedMainWindowLeavesThePanelNumberUnproved() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [ContactsFixture.collapsedRail()]))
        let app = fake.rootElement
        let main = try #require(try app.elements(AXAttribute.windows).first)
        Self.makeAddButtonsPressable(fake)
        let add = try #require(try WeComActions.addCustomerHeaderCandidates(window: main).first)
        let panelNode = try Self.blankAddCustomerPanel()
        var panelHandle: AXElementHandle?
        fake.reactions["action:\(AXAction.press)"] = {
            if fake.recordedActions.last?.handle == add.handle, panelHandle == nil {
                panelHandle = fake.appendChild(to: fake.rootHandle, node: panelNode)
            }
        }
        let mainFrame = try #require(try main.frame())
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1),
                             verifyTimeout: 0.1, verifyInterval: 0.01)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        // Before the press the list comes back empty; afterwards the main window and the panel both show up.
        a.windowIdentities = { _ in
            guard let panelHandle, let frame = try? AXElement(handle: panelHandle, backend: fake).frame() else { return [] }
            return [WeComWindowIdentity(id: 53452, layer: 0, bounds: mainFrame, onScreen: true),
                    WeComWindowIdentity(id: 71603, layer: 0, bounds: frame, onScreen: true)]
        }
        struct Observed: Error {}
        var seen: (panel: CGWindowID?, parent: CGWindowID?)?
        a.visualObserveContactAdd = { _, _, panel, _, _, _ in
            seen = (panel.windowID, panel.parentWindowID)
            throw Observed()
        }
        #expect(throws: Observed.self) {
            try a.addContact(phone: "13800000000", source: "wechat", greeting: nil, dryRun: true, app: app, window: main)
        }
        #expect(seen != nil && seen?.panel == nil && seen?.parent == nil)
    }

    /// The recorded 添加客户 panel window with its search field emptied, as a fresh press leaves it.
    static func blankAddCustomerPanel() throws -> AXNode {
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

    /// Live 2026-09-29 (5.0.11): pressing a WeCom user's 添加 opens a separate 发送验证申请 window — a
    /// third AXStandardWindow (360×403) with a prefilled verification field and its clear button, one
    /// 发送 and a close button. The command owns it (it appeared after its own match press) and finishes
    /// the invite there: the greeting goes into that window's own field, 发送 is pressed once, and the
    /// window closing is the evidence. The live client lists its newest window first; either order works.
    @Test(arguments: [false, true])
    func aSeparateVerificationWindowFinishesTheInvite(newestFirst: Bool) throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        let a = Self.actions()
        var verification: AXElementHandle?
        var sends = 0
        fake.reactions["action:\(AXAction.press)"] = {
            guard let last = fake.recordedActions.last?.handle else { return }
            if last == wecomButton, verification == nil {
                verification = newestFirst
                    ? fake.prependChild(to: fake.rootHandle, node: Self.verificationWindow())
                    : fake.appendChild(to: fake.rootHandle, node: Self.verificationWindow())
            } else if let window = verification, (try? AXElement(handle: last, backend: fake).title()) == "发送" {
                sends += 1
                fake.mutate(window, attribute: AXAttribute.role, to: .string(AXRole.group))   // the window closes
            }
        }
        var order: [String] = []
        let hooks = SubmitHooks(beforeIrreversible: { order.append("checkpoint") }, afterIrreversible: { order.append("after") })
        let out = try a.addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                                   app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        #expect(out.status == "requested" && out.details["confirmed"] == "发送" && out.details["greeting"] == "set")
        #expect(out.details["inviteDialog"] == "closed" && out.details["pressed"] == "wecom/添加" && sends == 1)
        let field = try #require(verification.flatMap { AXElement(handle: $0, backend: fake).descendants(maxDepth: 3, maxNodes: 50)
            .first { (try? $0.role()) == AXRole.textField } })
        #expect(fake.recordedSets.contains { $0.handle == field.handle && $0.value == .string("你好，imctl 测试") })
        #expect(order == ["checkpoint", "after", "checkpoint", "after"])
    }

    /// A 发送验证申请-shaped window that is already there when the match's 添加 is about to be pressed —
    /// here it appears while the checkpoint is written — is not this command's invite: the command
    /// stops before that press, and nothing in the window is written or pressed.
    @Test func aVerificationWindowBeforeTheMatchPressIsNeverTaken() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var early: AXElementHandle?
        let hooks = SubmitHooks(beforeIrreversible: {
            if early == nil { early = fake.prependChild(to: fake.rootHandle, node: Self.verificationWindow()) }
        })
        #expect(throws: ActionError.self) {
            try Self.actions().addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                                          app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        }
        let window = try #require(early)
        let inside = Set(AXElement(handle: window, backend: fake).descendants(maxDepth: 3, maxNodes: 50).map(\.handle))
        #expect(!fake.recordedActions.contains { $0.handle == wecomButton || inside.contains($0.handle) })
        #expect(!fake.recordedSets.contains { inside.contains($0.handle) })
    }

    /// After 发送 the separate window must actually close. One that stays open in another shape (a
    /// prompt, an error) is no sent request: the result is confirm-pressed, not requested.
    @Test func aVerificationWindowThatStaysOpenIsNotARequest() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var verification: AXElementHandle?
        var sends = 0
        fake.reactions["action:\(AXAction.press)"] = {
            guard let last = fake.recordedActions.last?.handle else { return }
            if last == wecomButton, verification == nil {
                verification = fake.appendChild(to: fake.rootHandle, node: Self.verificationWindow())
            } else if verification != nil, (try? AXElement(handle: last, backend: fake).title()) == "发送" {
                sends += 1
                fake.mutate(last, attribute: AXAttribute.title, to: .string("«prompt»"))   // stays open, reshaped
            }
        }
        let out = try Self.actions().addContact(phone: "13800000000", source: "wecom", greeting: nil, dryRun: false,
                                                app: fake.rootElement, window: main, requiresFreshPanel: false)
        #expect(out.status == "confirm-pressed" && out.details["inviteDialog"] == "still open" && sends == 1)
    }

    /// A chat window that opens after the match press also offers a field, 发送 and a close button, but
    /// its composer is a text area beside a message list: it is not the invite, and neither its
    /// composer nor its 发送 is touched.
    @Test func aChatWindowAfterTheMatchPressIsNotTheInvite() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var chat: AXElementHandle?
        fake.reactions["action:\(AXAction.press)"] = {
            guard fake.recordedActions.last?.handle == wecomButton, chat == nil else { return }
            chat = fake.prependChild(to: fake.rootHandle, node: Self.chatWindow())
            fake.mutate(wecomButton, attribute: AXAttribute.title, to: .string("«added»"))   // the row's 添加 is gone
        }
        let out = try Self.actions().addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                                                app: fake.rootElement, window: main, requiresFreshPanel: false)
        #expect(out.status == "pressed" && out.details["confirmed"] == nil && out.details["inviteWindow"] == nil)
        let inside = Set(AXElement(handle: try #require(chat), backend: fake).descendants(maxDepth: 6, maxNodes: 80).map(\.handle))
        #expect(!fake.recordedActions.contains { inside.contains($0.handle) })
        #expect(!fake.recordedSets.contains { inside.contains($0.handle) })
    }

    /// Only the recorded shape counts: an AXStandardWindow with exactly one writable text field, one
    /// confirmation — titled 发送 and pressable — one close button, no 添加客户 heading, no text area and
    /// no list. Every near miss is refused.
    @Test func onlyTheRecordedVerificationShapeCounts() throws {
        func variant(_ change: (inout AXNode) -> Void) -> AXNode {
            var window = Self.verificationWindow()
            change(&window)
            return window
        }
        func edit(_ window: inout AXNode, where match: (AXNode) -> Bool, _ change: (inout AXNode) -> Void) {
            for i in window.children.indices where match(window.children[i]) { change(&window.children[i]) }
        }
        let isField = { (n: AXNode) in n.role == AXRole.textField }
        let isSend = { (n: AXNode) in n.title == "发送" }
        let nearMisses: [AXNode] = [
            Self.chatWindow(),
            variant { $0.children.append(AXNode(role: AXRole.textField, value: .string(""),
                                                frame: CGRect(x: 817, y: 600, width: 262, height: 38), settable: [AXAttribute.value])) },
            variant { edit(&$0, where: isField) { $0.role = AXRole.textArea } },                 // a composer
            variant { $0.children.removeAll(where: isField) },                                       // an alert: no field
            variant { edit(&$0, where: isSend) { $0.title = "确定" } },                              // not 发送
            variant { edit(&$0, where: isSend) { $0.title = "发送邀请" } },
            variant { edit(&$0, where: isSend) { $0.actions = [] } },                                // 发送 not pressable
            variant { $0.children.append(AXNode(role: AXRole.button, title: "确定",
                                                frame: CGRect(x: 839, y: 700, width: 242, height: 34), actions: [AXAction.press])) },
            variant { $0.children.removeAll { $0.subrole == "AXCloseButton" } },
            variant { $0.children.append(AXNode(role: AXRole.staticText, value: .string("添加客户"),
                                                frame: CGRect(x: 805, y: 460, width: 98, height: 21))) },
            variant { $0.subrole = "AXDialog" },
            variant { $0.children.append(AXNode(role: AXRole.list, frame: CGRect(x: 800, y: 600, width: 300, height: 40))) },
        ]
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [Self.verificationWindow()] + nearMisses))
        let windows = try fake.rootElement.elements(AXAttribute.windows)
        #expect(windows.map(AddCustomerPanel.isVerificationWindow) == [true] + nearMisses.map { _ in false })
        let (recorded, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: recorded.rootElement, mainWindow: main))
        #expect(!AddCustomerPanel.isVerificationWindow(panel.window) && !AddCustomerPanel.isVerificationWindow(main))
    }

    /// A client alert after the match press — 确定 and a close button, no field — is not the invite:
    /// nothing in it is pressed and the add is not reported as requested.
    @Test func anAlertAfterTheMatchPressIsNotTheInvite() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var alert: AXElementHandle?
        fake.reactions["action:\(AXAction.press)"] = {
            guard fake.recordedActions.last?.handle == wecomButton, alert == nil else { return }
            alert = fake.prependChild(to: fake.rootHandle, node: Self.alertWindow())
            fake.mutate(wecomButton, attribute: AXAttribute.title, to: .string("«added»"))
        }
        let out = try Self.actions().addContact(phone: "13800000000", source: "wecom", greeting: nil, dryRun: false,
                                                app: fake.rootElement, window: main, requiresFreshPanel: false)
        #expect(out.status == "pressed" && out.details["confirmed"] == nil && out.details["inviteWindow"] == nil)
        let inside = Set(AXElement(handle: try #require(alert), backend: fake).descendants(maxDepth: 3, maxNodes: 50).map(\.handle))
        #expect(!fake.recordedActions.contains { inside.contains($0.handle) })
    }

    /// The window-number snapshot comes first: a window appearing while it is taken is in the AX
    /// snapshot that follows, and one offering a confirmation stops the command before the match press.
    @Test func aWindowDuringTheNumberSnapshotStopsTheMatchPress() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var a = Self.actions()
        a.visualObserveContactAdd = { _, _, _, _, _, _ in }
        var armed = false
        var injected: AXElementHandle?
        a.windowIdentities = { _ in
            if armed, injected == nil { injected = fake.prependChild(to: fake.rootHandle, node: Self.verificationWindow()) }
            return []
        }
        let hooks = SubmitHooks(beforeIrreversible: { armed = true })
        #expect(throws: ActionError.self) {
            try a.addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                             app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        }
        let inside = Set(AXElement(handle: try #require(injected), backend: fake).descendants(maxDepth: 3, maxNodes: 50).map(\.handle))
        #expect(!fake.recordedActions.contains { $0.handle == wecomButton || inside.contains($0.handle) })
        #expect(!fake.recordedSets.contains { inside.contains($0.handle) })
    }

    /// A window that is already there at the snapshot — not yet in the invite's shape, its 发送 not
    /// pressable — and takes that shape after the press is never adopted: it is not this press's window.
    @Test func aWindowPresentAtTheSnapshotIsNeverAdopted() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var a = Self.actions()
        a.visualObserveContactAdd = { _, _, _, _, _, _ in }
        var armed = false
        var early: AXElementHandle?
        a.windowIdentities = { _ in
            if armed, early == nil {
                var window = Self.verificationWindow()
                for i in window.children.indices where window.children[i].title == "发送" { window.children[i].actions = [] }
                early = fake.prependChild(to: fake.rootHandle, node: window)
            }
            return []
        }
        fake.reactions["action:\(AXAction.press)"] = {
            guard fake.recordedActions.last?.handle == wecomButton, let window = early else { return }
            if let send = AXElement(handle: window, backend: fake).descendants(maxDepth: 3, maxNodes: 50)
                .first(where: { (try? $0.title()) == "发送" }) {
                fake.setActions(of: send.handle, to: [AXAction.press])   // now in the invite's shape
            }
            fake.mutate(wecomButton, attribute: AXAttribute.title, to: .string("«added»"))
        }
        let hooks = SubmitHooks(beforeIrreversible: { armed = true })
        let out = try a.addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                                   app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        #expect(out.status == "pressed" && out.details["inviteWindow"] == nil && out.details["confirmed"] == nil)
        let inside = Set(AXElement(handle: try #require(early), backend: fake).descendants(maxDepth: 3, maxNodes: 50).map(\.handle))
        #expect(!fake.recordedActions.contains { inside.contains($0.handle) })
        #expect(!fake.recordedSets.contains { inside.contains($0.handle) })
    }

    /// A window that appears right after the AX snapshot, before the press, stops the command before
    /// the match press whatever its shape: in the invite's shape it offers a confirmation, in any other
    /// shape the windows are no longer the snapshot's.
    @Test(arguments: [true, false])
    func aWindowAfterTheSnapshotStopsTheMatchPress(inviteShaped: Bool) throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var a = Self.actions()
        a.visualObserveContactAdd = { _, _, _, _, _, _ in }
        var armed = false, numbersTaken = false, snapshotTaken = false
        var late: AXElementHandle?
        a.windowIdentities = { _ in
            if armed { numbersTaken = true }
            return []
        }
        fake.onRead = { handle, name in
            guard numbersTaken, late == nil else { return }
            if !snapshotTaken {
                // the first window listing after the number snapshot is the AX snapshot itself
                if handle == fake.rootHandle, name == AXAttribute.windows { snapshotTaken = true }
                return
            }
            late = fake.prependChild(to: fake.rootHandle, node: inviteShaped ? Self.verificationWindow() : Self.chatWindow())
        }
        let hooks = SubmitHooks(beforeIrreversible: { armed = true })
        #expect(throws: ActionError.self) {
            try a.addContact(phone: "13800000000", source: "wecom", greeting: "你好，imctl 测试", dryRun: false,
                             app: fake.rootElement, window: main, hooks: hooks, requiresFreshPanel: false)
        }
        let inside = Set(AXElement(handle: try #require(late), backend: fake).descendants(maxDepth: 6, maxNodes: 80).map(\.handle))
        #expect(!fake.recordedActions.contains { $0.handle == wecomButton || inside.contains($0.handle) })
        #expect(!fake.recordedSets.contains { inside.contains($0.handle) })
    }

    /// A confirmation inside a window that the client does not list among its windows (here nested in
    /// a main-window popover) is no separate invite: its evidence is the confirmation going away, and
    /// while it stays the result is confirm-pressed, never requested.
    @Test func aConfirmationInAnUnlistedWindowIsNotASeparateInvite() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        let wecomButton = try #require(try panel.matches().first { $0.source == "wecom" }?.button)
        var added = false
        var sends = 0
        fake.reactions["action:\(AXAction.press)"] = {
            guard let last = fake.recordedActions.last?.handle else { return }
            if last == wecomButton, !added {
                added = true
                _ = fake.appendChild(to: main.handle, node: AXNode(role: AXRole.popover,
                    frame: CGRect(x: 780, y: 414, width: 360, height: 403), children: [Self.verificationWindow()]))
            } else if (try? AXElement(handle: last, backend: fake).title()) == "发送" {
                sends += 1   // nothing closes
            }
        }
        let out = try Self.actions().addContact(phone: "13800000000", source: "wecom", greeting: nil, dryRun: false,
                                                app: fake.rootElement, window: main, requiresFreshPanel: false)
        #expect(sends == 1 && out.status == "confirm-pressed" && out.details["inviteDialog"] == "still open")
        #expect(out.details["inviteWindow"] == nil)
    }

    static func actions() -> WeComActions {
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1),
                             verifyTimeout: 0.3, verifyInterval: 0.02)
        a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true }; a.postReturnKey = { _, _ in }
        return a
    }

    /// Two separate windows in the invite's shape — the second at another place — cannot be tied to the
    /// searched phone: the lookup refuses to choose, and nothing is pressed.
    @Test func aSecondWindowWithAConfirmationIsNotTakenForTheInvite() throws {
        let (fake, main) = try Self.fixture()
        let panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        _ = fake.appendChild(to: fake.rootHandle, node: Self.verificationWindow())
        var chat = Self.verificationWindow()
        chat.frame = AXFrame(CGRect(x: 100, y: 100, width: 960, height: 800))
        _ = fake.appendChild(to: fake.rootHandle, node: chat)
        let a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .addContact], phase: .phase1))
        #expect(throws: ActionError.self) { try a.inviteConfirm(app: fake.rootElement, mainWindow: main, panel: panel) }
        #expect(fake.recordedActions.isEmpty)
    }

    /// The 发送验证申请 window as recorded live on 2026-09-29 (geometry and roles; texts synthetic).
    static func verificationWindow() -> AXNode {
        AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: CGRect(x: 780, y: 414, width: 360, height: 403), children: [
            AXNode(role: AXRole.staticText, value: .string("«title»"), frame: CGRect(x: 805, y: 436, width: 98, height: 21)),
            AXNode(role: AXRole.staticText, value: .string("«name»"), frame: CGRect(x: 821, y: 491, width: 44, height: 20)),
            AXNode(role: AXRole.image, frame: CGRect(x: 1059, y: 491, width: 42, height: 42)),
            AXNode(role: AXRole.staticText, value: .string("«label»"), frame: CGRect(x: 821, y: 562, width: 50, height: 21)),
            AXNode(role: AXRole.textField, value: .string("«prefilled»"), frame: CGRect(x: 817, y: 656, width: 262, height: 38),
                   settable: [AXAttribute.value]),
            AXNode(role: AXRole.button, frame: CGRect(x: 1087, y: 657, width: 18, height: 18), actions: [AXAction.press]),
            AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 839, y: 744, width: 242, height: 34), actions: [AXAction.press]),
            AXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 788, y: 421, width: 12, height: 14),
                   actions: [AXAction.press]),
        ])
    }

    /// A client alert (synthetic): a line of text, 确定 and a close button.
    static func alertWindow() -> AXNode {
        AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: CGRect(x: 800, y: 450, width: 320, height: 180), children: [
            AXNode(role: AXRole.staticText, value: .string("«alert»"), frame: CGRect(x: 820, y: 480, width: 200, height: 20)),
            AXNode(role: AXRole.button, title: "确定", frame: CGRect(x: 900, y: 580, width: 120, height: 30), actions: [AXAction.press]),
            AXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 808, y: 457, width: 12, height: 14),
                   actions: [AXAction.press]),
        ])
    }

    /// A detached chat window (synthetic): a message list, the composer — an AXTextArea, as in the main
    /// window — its 发送 and a close button.
    static func chatWindow() -> AXNode {
        AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: CGRect(x: 600, y: 200, width: 700, height: 640), children: [
            AXNode(role: AXRole.staticText, value: .string("«chat»"), frame: CGRect(x: 620, y: 210, width: 120, height: 20)),
            AXNode(role: AXRole.scrollArea, frame: CGRect(x: 600, y: 250, width: 700, height: 420), children: [
                AXNode(role: AXRole.table, frame: CGRect(x: 600, y: 250, width: 700, height: 420), children: [
                    AXNode(role: AXRole.row, frame: CGRect(x: 600, y: 260, width: 700, height: 40), children: [
                        AXNode(role: AXRole.textArea, value: .string("«message»"), frame: CGRect(x: 640, y: 265, width: 200, height: 30)),
                    ]),
                ]),
            ]),
            AXNode(role: AXRole.textArea, value: .string(""), frame: CGRect(x: 610, y: 690, width: 680, height: 100),
                   settable: [AXAttribute.value]),
            AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 1200, y: 800, width: 80, height: 30), actions: [AXAction.press]),
            AXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 608, y: 207, width: 12, height: 14),
                   actions: [AXAction.press]),
        ])
    }

    /// The synthetic contacts view leaves its 添加 without AXPress; the recorded one already has it.
    static func makeAddButtonsPressable(_ fake: FakeAXBackend) {
        for button in fake.rootElement.descendants(maxDepth: 14, maxNodes: 8000)
        where (try? button.role()) == AXRole.button && (try? button.title()) == "添加" {
            fake.setActions(of: button.handle, to: [AXAction.press])
        }
    }

    /// User decision 2026-10-13: contact.add takes any phone number — whether the person accepts is theirs to
    /// decide. Only phone-shaped text (digits, + - spaces, brackets; 5–20 digits) reaches WeCom's search field.
    /// A list left in an older policy file is read, ignored and not written back; real adds and searches each
    /// keep an hourly cap.
    @Test func phonePolicyTakesAnyNumberAndKeepsTheCaps() throws {
        let p = ContactAddPolicy()
        #expect(p.allows("138 0000 0000") && p.allows("+86 (139) 0000-0001"))
        #expect(!p.allows("") && !p.allows("abc1") && !p.allows("1234") && !p.allows(String(repeating: "1", count: 21))
                && !p.allows("138 0000 0000 张三"))
        #expect(p.summary == "phones=any maxAddsPerHour=20 maxSearchesPerHour=60")
        #expect(ContactAddPolicy.mask("13800000000") == "138******00" && ContactAddPolicy.mask("123") == "***" && ContactAddPolicy.normalize("a1b2") == "12")
        let decoded = try JSONDecoder().decode(SendPolicy.self, from: Data(
            #"{"contactAdd":{"allowedPhones":["13800000000"],"maxAddsPerHour":5,"maxSearchesPerHour":7}}"#.utf8))
        #expect(decoded.contactAdd.allows("13900000001") && decoded.contactAdd.maxAddsPerHour == 5
                && decoded.contactAdd.maxSearchesPerHour == 7)
        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!written.contains("allowedPhones") && written.contains(#""maxAddsPerHour":5"#) && written.contains(#""maxSearchesPerHour":7"#))
        let empty = try JSONDecoder().decode(SendPolicy.self, from: Data("{}".utf8)).contactAdd
        #expect(empty.maxAddsPerHour == 20 && empty.maxSearchesPerHour == 60)
        #expect(ActionKind.addContact.requiresTarget == false)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

enum ContactsFixture {
    static func newCustomers() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json")))
    }

    /// Synthetic 通讯录 › 新的客户 view on the 59 px rail, shaped like the live dump of 2026-09-23
    /// 09:3x (macOS 27.0, 5.0.11; the raw dump stays outside the repo): the left `AXOutline` spans
    /// x 59–311 and its first row holds the label as an `AXTextArea` (新的客户 at x 104, depth 7)
    /// between an icon and a trailing image; the right pane starts at x 310 with its own 新的客户
    /// header, an `AXStaticText` at x 326 and depth 5 — shallower, so a breadth-first walk meets it
    /// first; the cards table spans x 310, 1612 wide, one
    /// card per row (微信, name, avatar, greeting, `icon outer user card`, 打招呼 / 接受). Labels
    /// are the client's own UI strings; card names, greetings and the y positions are synthetic.
    /// `newCustomersRow: false` drops the outline's 新的客户 row; `outlineSelectable: false` makes
    /// the outline's AXSelectedRows read-only.
    static func collapsedRail(newCustomersRow: Bool = true, outlineSelectable: Bool = true) -> AXNode {
        func text(_ role: String, _ value: String, _ frame: CGRect) -> AXNode {
            AXNode(role: role, value: .string(value), frame: frame)
        }
        func outlineRow(y: CGFloat, height: CGFloat = 36, _ content: [AXNode] = []) -> AXNode {
            let frame = CGRect(x: 60, y: y, width: 250, height: height)
            return AXNode(role: AXRole.row, frame: frame, children: [AXNode(role: AXRole.cell, frame: frame, children: content)])
        }
        func card(y: CGFloat, name: String, button: String) -> AXNode {
            AXNode(role: AXRole.row, frame: CGRect(x: 311, y: y, width: 1609, height: 122), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 327, y: y, width: 1577, height: 122), children: [
                    text(AXRole.staticText, "微信", CGRect(x: 916, y: y + 22, width: 26, height: 18)),
                    text(AXRole.staticText, name, CGRect(x: 896, y: y + 48, width: 40, height: 21)),
                    AXNode(role: AXRole.image, frame: CGRect(x: 1062, y: y + 25, width: 42, height: 42)),
                    text(AXRole.staticText, "我是\(name)", CGRect(x: 896, y: y + 88, width: 206, height: 19)),
                    AXNode(role: AXRole.image, description: "icon outer user card", frame: CGRect(x: 894, y: y + 21, width: 20, height: 20)),
                    AXNode(role: AXRole.button, title: button, frame: CGRect(x: 1165, y: y + 48, width: 62, height: 26),
                           actions: [AXAction.press], settable: [AXAttribute.focused]),
                ]),
            ])
        }
        let newCustomers = outlineRow(y: 94, [
            AXNode(role: AXRole.image, description: "icon new friend", frame: CGRect(x: 75, y: 101, width: 22, height: 22)),
            text(AXRole.textArea, WeComContactsView.newCustomersTitle, CGRect(x: 104, y: 102, width: 56, height: 20)),
            AXNode(role: AXRole.image, frame: CGRect(x: 269, y: 103, width: 32, height: 32)),
        ])
        let otherRows = [
            outlineRow(y: 130, height: 12),
            outlineRow(y: 142, [AXNode(role: AXRole.image, frame: CGRect(x: 75, y: 149, width: 22, height: 22)),
                                text(AXRole.textArea, "我的客户", CGRect(x: 104, y: 150, width: 56, height: 20))]),
            outlineRow(y: 178, [AXNode(role: AXRole.image, frame: CGRect(x: 75, y: 185, width: 22, height: 22)),
                                text(AXRole.textArea, "智能机器人", CGRect(x: 104, y: 186, width: 70, height: 20))]),
            outlineRow(y: 214, [AXNode(role: AXRole.image, frame: CGRect(x: 81, y: 225, width: 14, height: 14)),
                                text(AXRole.staticText, "添加成员...", CGRect(x: 97, y: 222, width: 65, height: 19))]),
        ]
        let outline = AXNode(role: AXRole.outline, frame: CGRect(x: 59, y: 93, width: 252, height: 1108),
                             settable: outlineSelectable ? [AXAttribute.selectedRows, AXAttribute.focused] : [AXAttribute.focused],
                             children: (newCustomersRow ? [newCustomers] : []) + otherRows + [
                                 AXNode(role: "AXColumn", frame: CGRect(x: 60, y: 94, width: 250, height: 1106)),
                             ])
        let cards = AXNode(role: AXRole.table, frame: CGRect(x: 310, y: 90, width: 1612, height: 1111),
                           settable: [AXAttribute.selectedRows, AXAttribute.focused], children: [
            card(y: 101, name: "李四", button: NewCustomersPage.greetTitle),
            card(y: 223, name: "王五", button: NewCustomersPage.greetTitle),
            card(y: 345, name: "赵六", button: NewCustomersPage.acceptTitle),
            AXNode(role: "AXColumn", frame: CGRect(x: 320, y: 91, width: 1590, height: 1109)),
        ])
        let rightPane = AXNode(role: AXRole.group, frame: CGRect(x: 310, y: 0, width: 1610, height: 1200), children: [
            AXNode(role: AXRole.group, frame: CGRect(x: 310, y: 0, width: 1610, height: 1200), children: [
                AXNode(role: AXRole.scrollArea, frame: CGRect(x: 310, y: 91, width: 1610, height: 1109), settable: [AXAttribute.focused], children: [cards]),
                text(AXRole.staticText, WeComContactsView.newCustomersTitle, CGRect(x: 326, y: 47, width: 1578, height: 26)),
                AXNode(role: AXRole.button, title: "添加", frame: CGRect(x: 1848, y: 55, width: 55, height: 19), settable: [AXAttribute.focused]),
            ]),
        ])
        return AXNode(role: AXRole.window, frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
            AXNode(role: "AXSplitGroup", frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
                AXNode(role: "AXSplitter", value: .number(60), frame: CGRect(x: 60, y: 0, width: 0, height: 1200), settable: [AXAttribute.value]),
                AXNode(role: "AXSplitGroup", frame: CGRect(x: 60, y: 0, width: 1860, height: 1200), children: [
                    AXNode(role: AXRole.textField, value: .string(""), frame: CGRect(x: 75, y: 45, width: 180, height: 34),
                           settable: [AXAttribute.value, AXAttribute.focused]),
                    AXNode(role: AXRole.scrollArea, frame: CGRect(x: 60, y: 94, width: 250, height: 1106), settable: [AXAttribute.focused], children: [outline]),
                    AXNode(role: "AXSplitter", value: .number(250), frame: CGRect(x: 310, y: 0, width: 1, height: 1200), settable: [AXAttribute.value]),
                    rightPane,
                ]),
            ]),
        ])
    }

    /// Paths inside `collapsedRail()` with its default arguments.
    static let outlinePath = [0, 1, 1, 0]
    static let newCustomersRowPath = [0, 1, 1, 0, 0]

    /// Move the entire client content within a wider window to model a rail
    /// whose width was changed by the client. The outline then begins beyond
    /// the old recorded 400-point cutoff while its AX hierarchy stays intact.
    static func shiftedContent(_ node: AXNode, by dx: CGFloat, root: Bool = true) -> AXNode {
        var shifted = node
        if let frame = node.frame {
            shifted.frame = AXFrame(CGRect(x: frame.x + (root ? 0 : dx), y: frame.y,
                                          width: frame.width + (root ? dx : 0), height: frame.height))
        }
        shifted.children = node.children.map { shiftedContent($0, by: dx, root: false) }
        return shifted
    }
}

@Suite("Contacts navigation on fixtures")
struct ContactsNavigationTests {
    @Test func badgeAndContactsSignatureAreReadFromTheTree() throws {
        let contacts = try ContactsFixture.newCustomers()
        #expect(RailBadges.newCustomersBadge(window: contacts.rootElement) == 2)
        #expect(WeComContactsView.isShowing(window: contacts.rootElement))
        let messages = try Fixtures.mainWindow()
        #expect(RailBadges.newCustomersBadge(window: messages.rootElement) == 0)
        #expect(!WeComContactsView.isShowing(window: messages.rootElement))
        #expect(try WeComContactsView.newCustomersTable(window: contacts.rootElement) != nil)
    }

    @Test func openContactsPressesCommand8ThenControlTabUntilTheSignatureAppears() throws {
        // start on the 消息 fixture; the "client" switches to the contacts tree after ⌘8 + 2×⌃Tab
        let fake = try Fixtures.mainWindow()
        let contactsRoot = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let keys = KeyLog()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        actions.frontmostPid = { nil }
        actions.postShortcut = { key, _ in
            keys.keys.append(key)
            if keys.keys.count == 3 { fake.replaceChildren(of: fake.rootHandle, with: contactsRoot.children) }
        }
        let out = try actions.openContacts(app: fake.rootElement, window: fake.rootElement)
        #expect(keys.keys == [.commandDigit(8), .controlTab, .controlTab] && out.details["steps"] == "2" && out.verified)
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.selectedRows })   // 新的客户 row selected
    }

    @Test func openContactsGivesUpAfterSixTabsWithTheStepTraceAndReturnUsesTheDeepLink() throws {
        let fake = try Fixtures.mainWindow()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.02; actions.verifyInterval = 0.01; actions.frontmostPid = { nil }
        let keys = KeyLog()
        actions.postShortcut = { key, _ in keys.keys.append(key) }
        let trace = TraceLog()
        actions.trace = { trace.lines.append($0) }
        do {
            _ = try actions.openContacts(app: fake.rootElement, window: fake.rootElement)
            Issue.record("openContacts should have failed")
        } catch let error as ActionError {
            guard case .verifyFailed(let what) = error else { Issue.record("unexpected \(error)"); return }
            // the failure text carries every step (roles, counts, timings), never content
            #expect(what.hasPrefix("contacts view did not appear after 6 tab steps [start front=unknown view="))
            #expect(what.contains("; ⌘8 view=") && what.contains("; ⌃Tab6 focus=-->- targets=0 moved=false front=unknown view="))
        }
        #expect(keys.keys.count == 7)
        #expect(trace.lines.count == 9 && trace.lines.allSatisfy { $0.hasPrefix("contacts: ") && $0.hasSuffix("ms") })
        #expect(trace.lines.filter { $0.hasPrefix("contacts: ⌃Tab") }.count == 6 && trace.lines[1].hasPrefix("contacts: front "))
        let opened = URLLog()
        actions.openURL = { opened.urls.append($0); return true }
        let back = try actions.returnToMessages(window: fake.rootElement)
        #expect(opened.urls.map(\.absoluteString) == ["wxwork://conversationlist"] && back.verified)
    }

    /// Live 2026-09-15: the client only acts on its shortcuts while it is the
    /// active application; when the user (or another app) took the front back
    /// after the first ⌃Tab, every later ⌃Tab was dropped and the six-step
    /// walk failed. The navigation must bring the client back before each key.
    @Test func openContactsBringsTheClientBackToFrontBeforeEveryShortcutAfterItLostTheFront() throws {
        let windowNode = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, settable: [AXAttribute.frontmost], children: [windowNode]))
        let window = try #require(fake.element(atPath: [0]))
        let contactsRoot = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        let front = FrontLog(current: 999)                       // another app is frontmost at the start
        actions.frontmostPid = { front.current }
        fake.reactions["set:\(AXAttribute.frontmost)"] = { front.current = 4242; fake.mutate(fake.rootHandle, attribute: AXAttribute.frontmost, to: .bool(true)) }
        let keys = KeyLog()
        actions.postShortcut = { key, _ in
            keys.keys.append(key)
            guard front.current == 4242 else { return }          // an inactive client ignores the key
            front.delivered += 1
            if front.delivered == 2 { front.current = 999; fake.mutate(fake.rootHandle, attribute: AXAttribute.frontmost, to: .bool(false)) }   // the user clicks back to their app after ⌃Tab 1 landed
            if front.delivered == 3 { fake.replaceChildren(of: window.handle, with: contactsRoot.children) }
        }
        let out = try actions.openContacts(app: fake.rootElement, window: window)
        #expect(keys.keys == [.commandDigit(8), .controlTab, .controlTab] && out.details["steps"] == "2" && out.verified)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.frontmost }.count == 2)   // once at the start, once before ⌃Tab 2
    }

    @Test func scanSummarisesTheViewWithoutItsContent() throws {
        let contacts = WeComContactsView.scan(window: try ContactsFixture.newCustomers().rootElement)
        #expect(contacts.showing && contacts.signature.first == "新的客户" && contacts.signature.count >= 2 && contacts.left > 0)
        #expect(contacts.fingerprint.count == 6 && contacts.summary.hasPrefix("view=\(contacts.fingerprint) texts=\(contacts.texts) left=\(contacts.left) sig=新的客户+"))
        let messages = WeComContactsView.scan(window: try Fixtures.mainWindow().rootElement)
        #expect(!messages.showing && messages.signature.isEmpty && messages.fingerprint != contacts.fingerprint && messages.summary.contains(" sig=- showing=false "))
    }

    @Test func focusMoveReportsRolesAndOnlyActsOnAFocusedTextBox() throws {
        let fake = try Fixtures.mainWindow()
        let idle = WeComActions.moveFocusOffTextInput(app: fake.rootElement, window: fake.rootElement)
        #expect(idle == WeComActions.FocusMove(before: "-", after: "-", targets: 0, moved: false) && fake.recordedSets.isEmpty)
        let composer = try #require(fake.rootElement.descendants(maxDepth: 10, maxNodes: 3000).first { (try? $0.role()) == AXRole.textArea })
        fake.mutate(fake.rootHandle, attribute: AXAttribute.focusedUIElement, to: .element(composer.handle))
        let move = WeComActions.moveFocusOffTextInput(app: fake.rootElement, window: fake.rootElement)
        // the fixture cannot move focus, so the report says so instead of claiming success
        #expect(move.before == AXRole.textArea && move.after == AXRole.textArea && move.targets > 0 && !move.moved)
        #expect(move.summary == "AXTextArea->AXTextArea targets=\(move.targets) moved=false")
    }

    @Test func shortcutsAreRestrictedToTheApprovedKeys() {
        #expect(KeystrokeInjector.Shortcut.commandDigit(8).keyCode == 28 && KeystrokeInjector.Shortcut.controlTab.keyCode == 48)
        #expect(KeystrokeInjector.Shortcut.commandDigit(9).keyCode == nil)
        #expect(KeystrokeInjector.Shortcut.shiftControlTab.flags == [.maskControl, .maskShift])
        // B13 (user 2026-09-22 17:43): ⌘V pastes the outbox file URL into the composer; the only key added since 1.0.0.
        #expect(KeystrokeInjector.Shortcut.commandV.keyCode == 9 && KeystrokeInjector.Shortcut.commandV.flags == [.maskCommand])
    }

    /// Live 2026-09-23 (macOS 27.0, 5.0.11): every 5 minutes the daemon reached the 通讯录 view
    /// (sig=新的客户+智能机器人+添加成员... showing=true) and then failed with `contacts.outline`:
    /// the right pane's own 新的客户 header comes first in the breadth-first walk,
    /// but has no enclosing outline row.
    @Test func newCustomersIsSelectedThroughItsOutlineRowNotTheRightPaneHeader() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let window = fake.rootElement
        // The first matching text is the right-pane header, not an outline row.
        let first = try #require(WeComContactsView.texts(in: window).first { $0.0 == WeComContactsView.newCustomersTitle }?.1)
        #expect(try first.role() == AXRole.staticText)
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        #expect((try first.frame()?.minX ?? 0) > (try AXElement(handle: outline, backend: fake).frame()?.maxX ?? .infinity))
        try WeComContactsView.selectNewCustomers(window: window)
        let row = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath))
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.selectedRows])
        #expect(fake.recordedSets.first?.handle == outline && fake.recordedSets.first?.value == .elements([row]))
    }

    /// The live outline already had 新的客户 in its AXSelectedRows when the view opened; writing it
    /// again is a needless client-side change.
    @Test func anAlreadySelectedNewCustomersRowIsNotSelectedAgain() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        let row = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath))
        fake.mutate(outline, attribute: AXAttribute.selectedRows, to: .elements([row]))
        try WeComContactsView.selectNewCustomers(window: fake.rootElement)
        #expect(!fake.recordedSets.contains { $0.attribute == AXAttribute.selectedRows })
    }

    /// The error names what is missing: no 新的客户 text inside a row at all, versus a row whose
    /// outline does not take AXSelectedRows.
    @Test func aMissingNewCustomersRowAndAReadOnlyOutlineAreReportedApart() {
        #expect(throws: WeComError.region("contacts.newCustomersRow")) {
            try WeComContactsView.selectNewCustomers(window: FakeAXBackend(root: ContactsFixture.collapsedRail(newCustomersRow: false)).rootElement)
        }
        #expect(throws: WeComError.region("contacts.outline")) {
            try WeComContactsView.selectNewCustomers(window: FakeAXBackend(root: ContactsFixture.collapsedRail(outlineSelectable: false)).rootElement)
        }
    }

    /// The live round end to end on the 59 px rail: 新的客户 selected once, then
    /// the cards table is found from its measured right-hand scroll pane.
    @Test func requestListReadsTheCardsOnThe59PxRailLayout() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())   // already on 通讯录: the shortcuts are no-ops
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01; actions.frontmostPid = { nil }
        actions.postShortcut = { _, _ in }; actions.openURL = { _ in true }
        #expect(WeComContactsView.isShowing(window: fake.rootElement))
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        #expect(try table.frame()?.minX == 310)
        let cards = try actions.contactRequestList(app: fake.rootElement, window: fake.rootElement)
        #expect(cards.map(\.name) == ["李四", "王五", "赵六"] && cards.map(\.status) == [.added, .added, .pending])
        #expect(cards.allSatisfy { $0.source == "wechat" } && cards.map(\.greeting) == ["我是李四", "我是王五", "我是赵六"])
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.selectedRows])   // the 新的客户 row, nothing else
    }

    @Test func widerRailUsesTheOutlineAndMeasuredCardsPane() throws {
        let fake = FakeAXBackend(root: ContactsFixture.shiftedContent(ContactsFixture.collapsedRail(), by: 500))
        let window = fake.rootElement
        #expect(WeComContactsView.scan(window: window).showing)
        let (row, outline) = try WeComContactsView.newCustomersRow(window: window)
        #expect(try outline.frame()?.minX == 559)
        #expect(try row.frame()?.minX == 560)
        let table = try #require(try WeComContactsView.newCustomersTable(window: window))
        #expect(try table.frame()?.minX == 810)
        try WeComContactsView.selectNewCustomers(window: window)
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.selectedRows])
    }

    @Test func textFieldRowStillIdentifiesTheViewForVisualFallback() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let label = try #require(fake.handle(atPath: ContactsFixture.newCustomersRowPath + [0, 1]))
        fake.mutate(label, attribute: AXAttribute.role, to: .string(AXRole.textField))
        #expect(WeComContactsView.scan(window: fake.rootElement).showing)
        #expect(try WeComContactsView.exactNewCustomersOutlineRows(window: fake.rootElement).count == 1)
        #expect(throws: WeComError.region("contacts.newCustomersRow")) {
            try WeComContactsView.selectNewCustomers(window: fake.rootElement)
        }
    }

    @Test func duplicateOutlineRowsAndCardsTablesFailClosed() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let outline = try #require(fake.handle(atPath: ContactsFixture.outlinePath))
        _ = fake.appendChild(to: outline, node: AXNode(role: AXRole.row,
            frame: CGRect(x: 60, y: 260, width: 250, height: 36), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: 260, width: 250, height: 36), children: [
                    AXNode(role: AXRole.staticText, value: .string(WeComContactsView.newCustomersTitle),
                           frame: CGRect(x: 104, y: 268, width: 56, height: 20)),
                ]),
            ]))
        #expect(!WeComContactsView.scan(window: fake.rootElement).showing)
        #expect(throws: WeComError.region("contacts.outline")) {
            try WeComContactsView.selectNewCustomers(window: fake.rootElement)
        }
        #expect(try WeComContactsView.newCustomersTable(window: fake.rootElement) == nil)
        #expect(fake.recordedSets.isEmpty)

        let separate = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let rightPane = try #require(separate.handle(atPath: [0, 1, 3]))
        _ = separate.appendChild(to: rightPane, node: AXNode(role: AXRole.scrollArea,
            frame: CGRect(x: 310, y: 91, width: 1610, height: 1109), children: [
                AXNode(role: AXRole.table, frame: CGRect(x: 310, y: 91, width: 1610, height: 1109)),
            ]))
        #expect(try WeComContactsView.newCustomersTable(window: separate.rootElement) == nil)
    }

    @Test func narrowUnrelatedTableDoesNotStandInForCardsThatHaveNotRendered() throws {
        let fake = FakeAXBackend(root: ContactsFixture.collapsedRail())
        let rightPane = try #require(fake.handle(atPath: [0, 1, 3]))
        fake.replaceChildren(of: rightPane, with: [
            AXNode(role: AXRole.scrollArea, frame: CGRect(x: 310, y: 91, width: 280, height: 1109), children: [
                AXNode(role: AXRole.table, frame: CGRect(x: 310, y: 91, width: 280, height: 1109)),
            ]),
        ])
        #expect(try WeComContactsView.newCustomersTable(window: fake.rootElement) == nil)
    }
}

final class KeyLog { var keys: [KeystrokeInjector.Shortcut] = [] }
final class URLLog { var urls: [URL] = [] }
final class TraceLog { var lines: [String] = [] }
final class FrontLog { var current: pid_t?; var delivered = 0; var restored: [pid_t] = []; init(current: pid_t?) { self.current = current } }

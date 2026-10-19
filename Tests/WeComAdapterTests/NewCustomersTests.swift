import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("新的客户 cards")
struct NewCustomersTests {
    func actions(_ enabled: Set<ActionKind>) -> WeComActions {
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: enabled))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }
        a.postShortcut = { _, _ in }; a.openURL = { _ in true }
        return a
    }

    @Test func parsesCardsWithStatusFromTheButton() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let cards = try NewCustomersPage.parse(table: table)
        #expect(cards.count == 2 && cards.map(\.status) == [.added, .pending])
        #expect(cards.allSatisfy { $0.source == "wechat" && $0.name.hasPrefix("«") && ($0.greeting ?? "").hasPrefix("«") })
        #expect(try cards[1].button.title() == "接受")
    }

    @Test func acceptPressesTheUniquePendingCardAndVerifiesTheButtonChange() throws {
        let fake = try ContactsFixture.newCustomers()   // already on the contacts view: the shortcuts are no-ops
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try NewCustomersPage.parse(table: table)[1]
        let button = pending.button.handle
        var order: [String] = []
        fake.reactions["action:AXPress"] = {
            order.append("press")
            fake.mutate(button, attribute: AXAttribute.title, to: .string("打招呼"))
        }
        let hooks = SubmitHooks(beforeIrreversible: { order.append("checkpoint") }, afterIrreversible: { order.append("after") })
        let out = try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name, app: fake.rootElement,
                                                                                    window: fake.rootElement, hooks: hooks)
        #expect(out.verified && out.details["status"] == "added" && fake.recordedActions.map(\.action) == [AXAction.press])
        #expect(order == ["checkpoint", "press", "after"])
        #expect(throws: ActionError.targetNotFound("nobody")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: "nobody", app: fake.rootElement, window: fake.rootElement)
        }
        let added = try NewCustomersPage.parse(table: table)[0]
        #expect(throws: ActionError.localGuard("\(added.name) is already added")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: added.name, app: fake.rootElement, window: fake.rootElement)
        }
    }

    @Test func acceptFinishesTheRemarkPopoverBeforeVerifying() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try NewCustomersPage.parse(table: table)[1]
        let button = pending.button.handle
        var presses = 0
        // client behaviour: 接受 opens the remark popover; its 完成 accepts and the card turns into 打招呼
        fake.reactions["action:AXPress"] = {
            presses += 1
            if presses == 1 {
                _ = fake.appendChild(to: fake.rootHandle, node: AXNode(role: AXRole.popover, frame: CGRect(x: 600, y: 300, width: 500, height: 420), children: [
                    AXNode(role: AXRole.staticText, value: .string("设置备注名"), frame: CGRect(x: 620, y: 320, width: 100, height: 20)),
                    AXNode(role: AXRole.button, title: "完成", frame: CGRect(x: 620, y: 660, width: 460, height: 40), actions: ["AXPress"]),
                ]))
            } else {
                fake.mutate(button, attribute: AXAttribute.title, to: .string("打招呼"))
            }
        }
        let out = try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name, app: fake.rootElement, window: fake.rootElement)
        #expect(out.verified && out.details["status"] == "added" && out.details["popover"] == "完成" && presses == 2)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press, AXAction.press])
    }

    @Test func vanishedCardAfterAcceptIsUnknownAndSameKeyDoesNotPressAgain() throws {
        let fixture = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(fixture))
        let existingCard = try #require(Self.node(at: path, in: fixture).children.first)
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        // A rebuilt or virtualized list can omit the requested card while still
        // showing other cards. That absence is not evidence of acceptance.
        fake.reactions["action:AXPress"] = {
            fake.replaceChildren(of: table.handle, with: [existingCard])
        }
        let store = try ControlStore(path: ":memory:")
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-accept-absence-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.openContacts, .acceptRequest], phase: .phase1),
            checkpoints: checkpoints)
        handler.configureActions = { action in
            action.verifyTimeout = 0.05
            action.verifyInterval = 0.005
            action.acceptTimeout = 0.05
            action.frontmostPid = { nil }
            action.postShortcut = { _, _ in }
            action.openURL = { _ in true }
        }
        let executor = CommandExecutor(store: store, handler: handler, rateLimiter: nil)
        let key = "absent-after-accept"
        let params = try String(decoding: JSONEncoder().encode(ContactRequestAcceptParams(
            name: pending.name, idempotencyKey: key)), as: UTF8.self)
        let first = try executor.submit(method: .contactRequestAccept, paramsJSON: params, idempotencyKey: key)
        #expect(first.state == .unknown && first.resultJSON?.contains("could not be verified") == true)
        #expect(first.checkpointMs != nil)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
        #expect(try store.events(after: 0, limit: 100).filter { $0.kind == .contactRequestAccepted }.isEmpty)
        let replay = try executor.submit(method: .contactRequestAccept, paramsJSON: params, idempotencyKey: key)
        #expect(replay.id == first.id && replay.state == .unknown)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func acceptRefusesAPreexistingRemarkPopoverWithoutCardAssociation() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        _ = fake.appendChild(to: fake.rootHandle, node: AXNode(role: AXRole.popover,
            frame: CGRect(x: 600, y: 300, width: 500, height: 420), children: [
                AXNode(role: AXRole.button, title: "完成", frame: CGRect(x: 620, y: 660, width: 460, height: 40), actions: [AXAction.press]),
            ]))
        #expect(throws: ActionError.actionUnavailable("existing accept popover cannot be tied to requested card")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name,
                app: fake.rootElement, window: fake.rootElement)
        }
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func acceptRefusesTwoRemarkPopoversAfterTheCardPress() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        fake.reactions["action:AXPress"] = {
            for offset in [0.0, 100.0] {
                _ = fake.appendChild(to: fake.rootHandle, node: AXNode(role: AXRole.popover,
                    frame: CGRect(x: 600 + offset, y: 300, width: 500, height: 420), children: [
                        AXNode(role: AXRole.button, title: "完成",
                               frame: CGRect(x: 620 + offset, y: 660, width: 460, height: 40), actions: [AXAction.press]),
                    ]))
            }
        }
        #expect(throws: ActionError.actionUnavailable("multiple accept popovers cannot be tied to requested card")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name,
                app: fake.rootElement, window: fake.rootElement)
        }
        #expect(fake.recordedActions.map(\.handle) == [pending.button.handle])
    }

    @Test func acceptRechecksThePendingCardAfterCheckpoint() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        let hooks = SubmitHooks(beforeIrreversible: {
            fake.mutate(pending.button.handle, attribute: AXAttribute.title, to: .string(NewCustomersPage.greetTitle))
        })
        #expect(throws: ActionError.actionUnavailable("接受申请 card changed")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name,
                app: fake.rootElement, window: fake.rootElement, hooks: hooks)
        }
        #expect(fake.recordedActions.isEmpty)
    }

    /// The wide cards table in an AXNode tree: its index path, so a test can rebuild it in the fake.
    static func tablePath(_ node: AXNode, path: [Int] = []) -> [Int]? {
        if node.role == AXRole.table, let f = node.frame, f.x >= 400, f.width >= 1000 { return path }
        for (i, child) in node.children.enumerated() { if let p = tablePath(child, path: path + [i]) { return p } }
        return nil
    }

    static func node(at path: [Int], in root: AXNode) -> AXNode { path.reduce(root) { $0.children[$1] } }

    static func retitling(_ node: AXNode, from: String, to: String) -> AXNode {
        var n = node
        if n.role == AXRole.button, n.title == from { n.title = to }
        n.children = n.children.map { retitling($0, from: from, to: to) }
        return n
    }

    @Test func waitsForRowsAfterTheCardsTableAppears() throws {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(root))
        let rows = Self.node(at: path, in: root).children
        let fake = FakeAXBackend(root: root)
        let handle = try #require(fake.handle(atPath: path))
        fake.replaceChildren(of: handle, with: [])
        var reads = 0
        fake.onRead = { element, attribute in
            guard element == handle, attribute == AXAttribute.children else { return }
            reads += 1
            if reads == 3 { fake.replaceChildren(of: handle, with: rows) }
        }
        let cards = try actions([.openContacts]).readyNewCustomerCards(window: fake.rootElement)
        #expect(reads >= 3 && cards.count == 2)
    }

    @Test func blankTableWithoutAnEmptyStateFailsInsteadOfReportingZeroRequests() throws {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(root))
        let fake = FakeAXBackend(root: root)
        fake.replaceChildren(of: try #require(fake.handle(atPath: path)), with: [])
        #expect(throws: ActionError.verifyFailed("contacts.newCustomersRow card rows not ready")) {
            try actions([.openContacts]).contactRequestList(app: fake.rootElement, window: fake.rootElement)
        }
    }

    @Test func explicitEmptyStateInCardsAreaConfirmsZeroRequests() throws {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(root))
        let fake = FakeAXBackend(root: root)
        fake.replaceChildren(of: try #require(fake.handle(atPath: path)), with: [
            AXNode(role: AXRole.staticText, value: .string("暂无新的客户"),
                   frame: CGRect(x: 700, y: 500, width: 160, height: 24)),
        ])
        let cards = try actions([.openContacts]).readyNewCustomerCards(window: fake.rootElement)
        #expect(cards.isEmpty)
    }

    @Test func incompleteCardRowNeverCountsAsACompleteList() throws {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(root))
        let fake = FakeAXBackend(root: root)
        fake.replaceChildren(of: try #require(fake.handle(atPath: path)), with: [
            AXNode(role: AXRole.row, frame: CGRect(x: 311, y: 101, width: 1609, height: 122)),
        ])
        #expect(throws: ActionError.verifyFailed("contacts.newCustomersRow card rows incomplete")) {
            try actions([.openContacts]).readyNewCustomerCards(window: fake.rootElement)
        }
    }

    /// Live 2026-09-15 16:39: after 完成 the client rebuilds the cards table
    /// (the element read before 接受 went stale within 3 s), so the
    /// verification has to re-locate the table on every poll.
    @Test func acceptReLocatesTheTableWhenTheClientRebuildsItAfterDone() throws {
        let fake = try ContactsFixture.newCustomers()
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        let path = try #require(Self.tablePath(root))
        let parentPath = Array(path.dropLast())
        let parentHandle = try #require(fake.handle(atPath: parentPath))
        var rebuilt = Self.node(at: parentPath, in: root).children
        rebuilt[path[path.count - 1]] = Self.retitling(rebuilt[path[path.count - 1]], from: NewCustomersPage.acceptTitle, to: NewCustomersPage.greetTitle)
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try #require(try NewCustomersPage.parse(table: table).first { $0.status == .pending })
        var presses = 0
        fake.reactions["action:AXPress"] = {
            presses += 1
            if presses == 1 {
                _ = fake.appendChild(to: fake.rootHandle, node: AXNode(role: AXRole.popover, frame: CGRect(x: 600, y: 300, width: 500, height: 420), children: [
                    AXNode(role: AXRole.button, title: "完成", frame: CGRect(x: 620, y: 660, width: 460, height: 40), actions: ["AXPress"]),
                ]))
            } else {
                fake.replaceChildren(of: parentHandle, with: rebuilt)   // 完成: the whole cards table is rebuilt, the person now 打招呼
            }
        }
        let out = try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name, app: fake.rootElement, window: fake.rootElement)
        #expect(out.verified && out.details["status"] == "added" && out.details["popover"] == "完成" && presses == 2)
        #expect(throws: (any Error).self) { try NewCustomersPage.parse(table: table) }   // the old element really is gone
    }

    @Test func handlerMapsCardsToWireRows() throws {
        let fake = try ContactsFixture.newCustomers()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-b7-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement },
                                    policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .acceptRequest], phase: .phase1),
                                    checkpoints: cps)
        h.configureActions = { a in
            a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }
            a.postShortcut = { _, _ in }; a.openURL = { _ in true }
        }
        let rows = try h.contactRequestList()
        #expect(rows.count == 2 && rows[1]["status"] == "pending" && rows[0]["status"] == "added" && rows[1]["source"] == "wechat")
        #expect(rows.allSatisfy { $0["greeting"] != nil })
    }
}

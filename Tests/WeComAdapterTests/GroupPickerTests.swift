import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Group picker sheet")
struct GroupPickerTests {
    static func sheetFixture() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json")))
    }

    /// Start with a clean window; only this command's ⌘N may create the sheet.
    static func closedSheetFixture() throws -> (FakeAXBackend, AXNode) {
        let fake = try sheetFixture()
        let window = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        let node = try #require(window.children.first { $0.role == AXRole.sheet })
        fake.replaceChildren(of: fake.rootHandle, with: window.children.filter { $0.role != AXRole.sheet })
        return (fake, node)
    }

    /// The fixture row (as a node) whose texts include `name`, for simulating the client's search filter.
    static func rowNode(named name: String) throws -> AXNode {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        func mentions(_ n: AXNode) -> Bool { n.value == .string(name) || n.children.contains(where: mentions) }
        func rows(_ n: AXNode) -> [AXNode] {
            (n.role == AXRole.outline ? n.children.filter { $0.role == AXRole.row } : []) + n.children.flatMap(rows)
        }
        return try #require(rows(root).first(where: mentions))   // the sheet's outline is not the window's first outline
    }

    /// Same as `rowNode(named:)`, but for the 添加群成员 fixture (B14): its rows carry the
    /// `checkbox selected disabled` image `pickMembers` reads for `alreadyMember`.
    static func addMembersRowNode(named name: String) throws -> AXNode {
        let root = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json"))
        func mentions(_ n: AXNode) -> Bool { n.value == .string(name) || n.children.contains(where: mentions) }
        func rows(_ n: AXNode) -> [AXNode] {
            (n.role == AXRole.outline ? n.children.filter { $0.role == AXRole.row } : []) + n.children.flatMap(rows)
        }
        return try #require(rows(root).first(where: mentions))
    }

    /// Fake the AX text that a selected member row must expose. An unlabeled
    /// row is deliberately rejected by the production identity check.
    static func selectedRowNode(named name: String, y: CGFloat) -> AXNode {
        AXNode(role: AXRole.row, frame: CGRect(x: 961, y: y, width: 319, height: 36), children: [
            AXNode(role: AXRole.cell, children: [AXNode(role: AXRole.staticText, value: .string(name))]),
        ])
    }

    func actions(_ enabled: Set<ActionKind>) -> WeComActions {
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: enabled))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }; a.openURL = { _ in true }
        a.groupOpenTimeout = 0.1
        a.postShortcut = { _, _ in }
        return a
    }

    /// Simulate the client's server-backed new-group transition without
    /// rebuilding unrelated AX handles: its own picker closes, a genuinely
    /// new selected sidebar row appears, and the header agrees with it.
    static func showCreatedGroup(_ fake: FakeAXBackend, sheet: GroupPickerSheet,
                                 window: AXElement? = nil,
                                 title: String, header: String, editableHeader: Bool = false) throws {
        let source = window ?? fake.rootElement
        let reader = try WeComReader(window: source)
        let table = reader.layout.conversationTable
        for row in try reader.conversations() where row.selected {
            fake.mutate(row.handle, attribute: AXAttribute.selected, to: .bool(false))
        }
        if let parent = try? sheet.sheet.parent() {
            fake.removeChild(sheet.sheet.handle, from: parent.handle)
        }
        let tableFrame = try #require(try table.frame())
        let rowY = tableFrame.minY + 12
        let newRow = AXNode(role: AXRole.row,
            frame: CGRect(x: tableFrame.minX, y: rowY, width: tableFrame.width, height: 42),
            selected: true, children: [
                AXNode(role: AXRole.cell,
                    frame: CGRect(x: tableFrame.minX, y: rowY, width: tableFrame.width, height: 42),
                    children: [AXNode(role: AXRole.staticText, value: .string(title),
                        frame: CGRect(x: tableFrame.minX + 48, y: rowY + 5, width: 200, height: 20))]),
            ])
        fake.appendChild(to: table.handle, node: newRow)
        fake.appendChild(to: source.handle, node: AXNode(
            role: editableHeader ? AXRole.textField : AXRole.staticText, value: .string(header),
            frame: CGRect(x: tableFrame.maxX + 48, y: tableFrame.minY - 28,
                          width: 360, height: 22),
            actions: editableHeader ? [AXAction.confirm] : [],
            settable: editableHeader ? [AXAttribute.value, AXAttribute.focused] : []))
    }

    @Test func locatesTheSheetAndClassifiesRowsBySection() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(sheet.searchField != nil && sheet.doneButton != nil && sheet.cancelButton != nil)
        let rows = try sheet.rows()
        #expect(rows.count == 2)                                     // one WeChat contact, one company member
        #expect(sheet.customers.count == 1 && sheet.customers[0].section == "我的客户")
        #expect(rows[1].section != "我的客户")
        #expect(try sheet.doneButton?.isEnabled() == false)
        #expect(try GroupPickerSheet.locate(window: try Fixtures.mainWindow().rootElement) == nil)
    }

    /// B14 (live 2026-09-23): the client's 添加群成员 sheet is the same widget family, confirmed with 确定
    /// instead of 完成, titled 添加群成员 in the right-hand group, and marks members already in the group
    /// with a `checkbox selected disabled` image instead of leaving them selectable.
    @Test func addMembersSheetIsRecognisedByConfirmButtonTitleTextAndDisabledRows() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json")))
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(try sheet.doneButton?.title() == "确定")
        #expect(sheet.isAddMembers)
        let byName = Dictionary(uniqueKeysWithValues: try sheet.rows().map { ($0.name, $0) })
        #expect(byName["李四"]?.disabled == true)
        #expect(byName["王五"]?.disabled == false)
        #expect(byName["赵六"]?.disabled == false && byName["赵六"]?.source == "wechat")
    }

    /// The B7 发起群聊 sheet's right-hand title reads 发起群聊, not 添加群成员, so `isAddMembers` must stay
    /// false and its confirm button stays titled 完成 — unchanged behaviour, pinned by a dedicated test.
    @Test func groupPickerSheetIsNotTheAddMembersVariant() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(!sheet.isAddMembers)
        #expect(try sheet.doneButton?.title() == "完成")
    }

    /// B14 (live 2026-09-23): `pickMembers(skipDisabled: true)` is the add-members flow's semantics —
    /// a row already in the group is skipped as `alreadyMember` without ever posting Return, and the
    /// rest are added exactly the way `createGroup` always added them (search → filtered → Return →
    /// the chosen table grows).
    @Test func pickMembersSkipsAlreadyMembersAndAddsTheRestWhenSkipDisabled() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json")))
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let rowByName = ["李四": try Self.addMembersRowNode(named: "李四"), "王五": try Self.addMembersRowNode(named: "王五")]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var returns = 0
        var a = actions([.openGroupPicker, .createGroup])
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
        }
        let pid = try fake.rootElement.pid()
        let picked = try a.pickMembers(["李四", "王五"], in: sheet, app: fake.rootElement, pid: pid, skipDisabled: true)
        #expect(picked.added == ["王五"])
        #expect(picked.skipped.count == 1 && picked.skipped[0].name == "李四" && picked.skipped[0].reason == "alreadyMember")
        #expect(returns == 1)   // 李四 never got a Return
    }

    /// B14: an add-members search that matches nobody is skipped as `notFound` instead of aborting the
    /// whole call, so the rest of the list still gets a chance — `pickMembers(skipDisabled: false)`
    /// (createGroup's own semantics) throws `targetNotFound` for the same case, unchanged
    /// (`createGroupRefusesUnknownMembersBeforeDone` above).
    @Test func pickMembersSkipsUnknownMembersAsNotFoundWhenSkipDisabled() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json")))
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let rowByName = ["王五": try Self.addMembersRowNode(named: "王五")]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var returns = 0
        var a = actions([.openGroupPicker, .createGroup])
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
        }
        let pid = try fake.rootElement.pid()
        let picked = try a.pickMembers(["nobody", "王五"], in: sheet, app: fake.rootElement, pid: pid, skipDisabled: true)
        #expect(picked.skipped.count == 1 && picked.skipped[0].name == "nobody" && picked.skipped[0].reason == "notFound")
        #expect(picked.added == ["王五"])
        #expect(returns == 1)
    }

    @Test func plusButtonIsLocatedOnTheMessagesView() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-filter-panel.json")))
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(try layout.plusButton?.frame()?.minX == 361)
    }

    @Test func createGroupTypesEachMemberConfirmsWithReturnAndPressesDone() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = sheet.customers[0].name
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        // client behaviour: typing filters the outline down to the matching row; Return on the search field lists the
        // highlighted result on the right and enables 完成; 完成 closes the sheet
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var returns: [(pid_t, Bool)] = []
        var a = actions([.openGroupPicker, .createGroup])
        a.postReturnKey = { pid, control in
            returns.append((pid, control))
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns.count)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        var order: [String] = []
        var stages: [GroupCreateVisualStage] = []
        var commitGates = 0
        a.visualObserveGroupCreate = { _, _, stage, verify in
            let valid = try verify()
            #expect(valid)
            stages.append(stage)
        }
        a.visualGroupCreateCommitGate = { commitGates += 1 }
        fake.reactions["action:AXPress"] = {
            order.append("press")
            try? Self.showCreatedGroup(fake, sheet: sheet,
                                       title: "\(customer)、\(colleague)、我",
                                       header: "\(customer)、\(colleague)、我(3)")
        }
        let hooks = SubmitHooks(beforeIrreversible: { order.append("checkpoint") }, afterIrreversible: { order.append("after") })
        let out = try a.createGroup(members: [customer, colleague], app: fake.rootElement, window: fake.rootElement,
                                    sheet: sheet, hooks: hooks)
        #expect(out.verified && out.details["selected"] == "2" && out.details["memberCount"] == "3" && fake.recordedActions.last?.action == AXAction.press)
        #expect(order == ["checkpoint", "press", "after"])
        #expect(stages == [.beforeCompletion, .afterCompletion] && commitGates == 2)
        #expect(returns.count == 2 && returns.allSatisfy { !$0.1 })
        let sets = fake.recordedSets.map(\.attribute)
        #expect(sets.contains(AXAttribute.value) && sets.contains(AXAttribute.focused) && !sets.contains(AXAttribute.selectedRows))
    }

    /// Live 2026-09-15: the client ignores pid-level keys while another app is
    /// active, and the user can take the front back between two members.
    @Test func createGroupBringsTheClientBackToFrontBeforeEveryReturnAfterItLostTheFront() throws {
        let windowNode = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, settable: [AXAttribute.frontmost], children: [windowNode]))
        let window = try #require(fake.element(atPath: [0]))
        let sheet = try #require(try GroupPickerSheet.locate(window: window))
        let customer = sheet.customers[0].name
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        fake.reactions["action:AXPress"] = {
            try? Self.showCreatedGroup(fake, sheet: sheet,
                                       window: window,
                                       title: "\(customer)、\(colleague)、我",
                                       header: "\(customer)、\(colleague)、我(3)")
        }
        let front = FrontLog(current: 999)                       // another app is active when the members are typed
        fake.reactions["set:\(AXAttribute.frontmost)"] = { front.current = 4242; fake.mutate(fake.rootHandle, attribute: AXAttribute.frontmost, to: .bool(true)) }
        var a = actions([.openGroupPicker, .createGroup])
        a.frontmostPid = { front.current }
        a.postReturnKey = { _, _ in
            guard front.current == 4242 else { return }          // an inactive client drops the key
            front.delivered += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(front.delivered)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
            if front.delivered == 1 { front.current = 999; fake.mutate(fake.rootHandle, attribute: AXAttribute.frontmost, to: .bool(false)) }   // the user clicks back to their app
        }
        let out = try a.createGroup(members: [customer, colleague], app: fake.rootElement, window: window, sheet: sheet)
        #expect(out.verified && out.details["selected"] == "2" && out.details["refronts"] == "2" && front.delivered == 2)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.frontmost }.count == 2)
    }

    /// Live 2026-09-15 16:43: the client creates the group asynchronously — the
    /// header switched to the new group 4 s after 完成 — so the outcome waits
    /// for a header with a member count instead of reporting the conversation
    /// that was active before.
    @Test func createGroupWaitsForTheClientToOpenTheGroupBeforeReadingTheHeader() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = sheet.customers[0].name
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        a.groupOpenTimeout = 0.5
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        var reads = 0
        fake.reactions["action:AXPress"] = {
            if let parent = try? sheet.sheet.parent() {
                fake.removeChild(sheet.sheet.handle, from: parent.handle)
            }
            fake.onRead = { _, name in
                guard name == AXAttribute.value else { return }
                reads += 1
                if reads == 20 {
                    fake.onRead = nil
                    try? Self.showCreatedGroup(fake, sheet: sheet,
                                               title: "\(customer)、\(colleague)、我",
                                               header: "\(customer)、\(colleague)、我(3)")
                }
            }
        }
        let out = try a.createGroup(members: [customer, colleague], name: "客户群聊", app: fake.rootElement, window: fake.rootElement, sheet: sheet)
        #expect(out.verified && out.details["opened"] == "true" && out.details["title"] == "\(customer)、\(colleague)、我" && out.details["memberCount"] == "3")
        #expect(out.details["renamed"] == "false")   // this header is a static text, not the editable field: the name is only recorded
        #expect(reads >= 20 && returns == 2)
    }

    /// B49: the header is bounded by the new chat's message viewport. A group that was created and
    /// proven but whose chat has no viewport stays unnamed: nothing is written into its editable
    /// header and the command reports the group with renamed false instead of failing after 完成.
    @Test func createGroupSkipsTheNameWhenTheNewChatHasNoMessageViewport() throws {
        // The picker recording has no chat behind the sheet: once 完成 closes the sheet, nothing
        // right of the list is a message viewport, as in a new chat that has not laid out yet.
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = sheet.customers[0].name
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        a.groupOpenTimeout = 0.5
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        fake.reactions["action:AXPress"] = {
            try? Self.showCreatedGroup(fake, sheet: sheet, title: "\(customer)、\(colleague)、我",
                                       header: "\(customer)、\(colleague)、我(3)", editableHeader: true)
        }
        let out = try a.createGroup(members: [customer, colleague], name: "客户群聊", app: fake.rootElement, window: fake.rootElement, sheet: sheet)
        #expect(try WeComReader(window: fake.rootElement).layout.messageViewportFrame() == nil)
        #expect(try WeComReader(window: fake.rootElement).layout.activeTitle?.role() == AXRole.textField)
        #expect(out.verified && out.details["opened"] == "true" && out.details["renamed"] == "false")
        #expect(!fake.recordedSets.contains { $0.value == .string("客户群聊") })
        #expect(!fake.recordedActions.contains { $0.action == AXAction.confirm })
    }

    /// B49: renaming an existing group whose chat shows no message viewport cannot bound the header;
    /// it stops before any focus or value write.
    @Test func renameWithoutAMessageViewportWritesNothing() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let reader = try WeComReader(window: fake.rootElement)
        let before = try #require(try reader.activeConversationHeader())
        // The chat and its member panel share one split pane ([0, 33, 9]); without it no table right
        // of the list is left to stand in as the message viewport.
        let content = try #require(fake.handle(atPath: [0, 33]))
        let chatAndPanel = try #require(fake.handle(atPath: [0, 33, 9]))
        fake.removeChild(chatAndPanel, from: content)
        #expect(try WeComReader(window: fake.rootElement).layout.messageViewportFrame() == nil)
        #expect(try WeComReader(window: fake.rootElement).layout.activeTitle != nil)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01
        #expect(throws: ActionError.actionUnavailable("群名输入框")) { try a.renameGroup(to: "测试群改名", window: fake.rootElement) }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    /// Live 2026-09-15 20:2x: an external group (two WeChat contacts + me) shows
    /// no member count in its header — just the member names — so "opened" must
    /// also accept a header that changed away from the conversation active
    /// before 完成, or one made of the requested member names.
    @Test func createGroupRecognisesAnExternalGroupHeaderWithoutAMemberCount() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = sheet.customers[0].name
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        fake.reactions["action:AXPress"] = {
            try? Self.showCreatedGroup(fake, sheet: sheet,
                                       title: "\(customer)、\(colleague)、我",
                                       header: "\(customer)、\(colleague)、我")
        }
        let out = try a.createGroup(members: [customer, colleague], app: fake.rootElement, window: fake.rootElement, sheet: sheet)
        #expect(out.verified && out.details["opened"] == "true" && out.details["title"] == "\(customer)、\(colleague)、我" && out.details["memberCount"] == "")
    }

    /// Live 2026-09-15 (5.0.11): a group's header title is an editable text field
    /// with an AXConfirm action — the rename path needs no synthetic input.
    @Test func renameWritesTheHeaderFieldAndConfirmsIt() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.groupOpenTimeout = 0.3
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let row = try #require(try WeComReader(window: fake.rootElement).activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        // the client accepts the confirmed value: the list row is renamed after the server round trip
        var order: [String] = []
        fake.reactions["action:\(AXAction.confirm)"] = {
            order.append("confirm")
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("测试群改名"))
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("测试群改名"))
        }
        let hooks = SubmitHooks(beforeIrreversible: { order.append("checkpoint") }, afterIrreversible: { order.append("after") })
        let out = try a.renameGroup(to: "测试群改名", window: fake.rootElement, hooks: hooks)
        #expect(out.verified && out.details["renamed"] == "true" && out.details["title"] == "测试群改名" && out.target == before.raw)
        #expect(order == ["checkpoint", "confirm", "after"])
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value == .string("测试群改名") })
        #expect(fake.recordedActions.map(\.action) == [AXAction.confirm])
        #expect(fake.recordedSets.first { $0.attribute == AXAttribute.focused }?.handle == field.handle)   // editing session first
        // a header that echoes the name while the list row keeps the old one is not a rename (live 22:16)
        fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string(row.title ?? ""))
        fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(before.raw))   // back to the allowlisted group
        fake.reactions["action:\(AXAction.confirm)"] = { fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("只改了头部")) }
        let confirmationsBeforeEcho = fake.recordedActions.filter { $0.action == AXAction.confirm }.count
        let echo = try a.renameGroup(to: "只改了头部", window: fake.rootElement)
        #expect(!echo.verified && echo.details["renamed"] == "false" && echo.details["headerShowsName"] == "true")
        #expect(fake.recordedActions.filter { $0.action == AXAction.confirm }.count == confirmationsBeforeEcho + 1)
        // not allowlisted: nothing is written
        var denied = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.renameGroup]))
        denied.verifyTimeout = 0.02
        #expect(throws: PolicyError.self) { try denied.renameGroup(to: "x", window: fake.rootElement) }
        #expect(!fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value == .string("x") })
    }

    /// The header is bounded by the live message viewport, not by a band 180 pt below the window
    /// top recorded on one screen: a header pushed 200 pt lower (title field y 220–244, viewport
    /// from y 280) is still renamed, and the field must stay above the viewport while staged.
    @Test func renameFollowsTheLiveHeaderRatherThanAWindowTopBand() throws {
        func lowered(_ node: AXNode, by dy: CGFloat, rightOf x: CGFloat) -> AXNode {
            var n = node
            if let f = n.frame, f.x >= x { n.frame = AXFrame(CGRect(x: f.x, y: f.y + dy, width: f.width, height: f.height)) }
            n.children = n.children.map { lowered($0, by: dy, rightOf: x) }
            return n
        }
        let recorded = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json"))
        let fake = FakeAXBackend(root: lowered(recorded, by: 200, rightOf: 411))
        let reader = try WeComReader(window: fake.rootElement)
        let before = try #require(try reader.activeConversationHeader())
        let field = try #require(reader.layout.activeTitle)
        #expect(try field.frame()?.minY == 220 && reader.layout.messageViewportFrame()?.minY == 280)
        let row = try #require(try reader.activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.groupOpenTimeout = 0.3
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("测试群改名"))
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("测试群改名"))
        }
        let out = try a.renameGroup(to: "测试群改名", window: fake.rootElement)
        #expect(out.verified && out.details["renamed"] == "true")
        #expect(WeComActions.isInConversationHeader(CGRect(x: 426, y: 250, width: 223, height: 24),
                                                    windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                                                    viewport: CGRect(x: 411, y: 280, width: 1348, height: 715),
                                                    conversationList: CGRect(x: 159, y: 63, width: 252, height: 1138)))
        #expect(!WeComActions.isInConversationHeader(CGRect(x: 426, y: 270, width: 223, height: 24),
                                                     windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                                                     viewport: CGRect(x: 411, y: 280, width: 1348, height: 715),
                                                     conversationList: CGRect(x: 159, y: 63, width: 252, height: 1138)))
    }

    @Test func renameRechecksTheOwningCommandBeforeChangingTheHeader() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let oldTitle = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader()?.title)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [oldTitle], enabled: [.renameGroup]))
        var checks = 0
        a.visualActionGate = { kind, title in
            checks += 1
            #expect(kind == .renameGroup && title == oldTitle)
            throw AIPlannerVisionError.disabled
        }
        #expect(throws: AIPlannerVisionError.disabled) {
            try a.renameGroup(to: "新群名", window: fake.rootElement)
        }
        #expect(checks == 1 && fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func renameRejectsAHeaderChangedDuringTheCommandGate() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let oldTitle = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader()?.title)
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [oldTitle], enabled: [.renameGroup]))
        a.visualActionGate = { _, _ in
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string("别的会话"))
        }
        #expect(throws: ActionError.actionUnavailable("群名输入框")) {
            try a.renameGroup(to: "新群名", window: fake.rootElement)
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func renameRepairsOneDroppedReversibleValueBeforeItsOnlyConfirm() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let row = try #require(try WeComReader(window: fake.rootElement).activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        a.groupOpenTimeout = 0.1; a.verifyInterval = 0.01
        var writes = 0
        var checkpoints = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == field.handle,
                  fake.recordedSets.last?.value == .string("新群名") else { return }
            writes += 1
            if writes == 1 { fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(before.raw)) }
        }
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("新群名"))
        }
        let out = try a.renameGroup(to: "新群名", window: fake.rootElement,
                                    hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        #expect(out.verified && writes == 2 && checkpoints == 1)
        #expect(fake.recordedActions.map(\.action) == [AXAction.confirm])
    }

    @Test func renameStopsAfterTwoDroppedValuesWithOneCheckpointAndNoConfirm() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        var checkpoints = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            if fake.recordedSets.last?.handle == field.handle {
                fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(before.raw))
            }
        }
        #expect(throws: ActionError.actionUnavailable("群名输入框")) {
            try a.renameGroup(to: "新群名", window: fake.rootElement,
                              hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 1 && fake.recordedActions.isEmpty)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.count == 2)
    }

    @Test func renameStopsIfTheCommandGateIsRevokedAfterStaging() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        var checkpoints = 0
        a.visualActionGate = { _, _ in
            if fake.recordedSets.contains(where: { $0.handle == field.handle && $0.value == .string("新群名") }) {
                throw AIPlannerVisionError.disabled
            }
        }
        #expect(throws: AIPlannerVisionError.disabled) {
            try a.renameGroup(to: "新群名", window: fake.rootElement,
                              hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 1 && fake.recordedActions.isEmpty)
    }

    @Test func renameDoesNotAcceptAnUnselectedRowAsServerProof() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let row = try #require(try WeComReader(window: fake.rootElement).activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        let table = try WeComReader(window: fake.rootElement).layout.conversationTable
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        a.groupOpenTimeout = 0.04; a.verifyInterval = 0.005
        var checkpoints = 0
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("新群名"))
            fake.mutate(table.handle, attribute: AXAttribute.selectedRows, to: .elements([]))
            fake.mutate(row.handle, attribute: AXAttribute.selected, to: .bool(false))
        }
        // Once the original selected row is lost, a post-confirm blur would
        // act on unproven ownership. Keep the checkpoint and original error.
        #expect(throws: ActionError.actionUnavailable("群名输入框")) {
            try a.renameGroup(to: "新群名", window: fake.rootElement,
                hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 1)
        #expect(fake.recordedActions.map(\.action) == [AXAction.confirm])
        #expect(fake.recordedSets.filter {
            $0.handle == field.handle && $0.attribute == AXAttribute.value
        }.map(\.value) == [.string("新群名")])
        #expect(fake.recordedSets.filter {
            $0.handle == table.handle && $0.attribute == AXAttribute.focused
        }.isEmpty)
    }

    @Test func renameWithStaleSelectedConversationRecordsUncertainDraftWithoutConfirm() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let row = try #require(try WeComReader(window: fake.rootElement).activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [before.title], enabled: [.renameGroup]))
        var checkpoints = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == field.handle else { return }
            fake.mutate(field.handle, attribute: AXAttribute.value, to: .string(before.raw))
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("另一群"))
        }
        // B60: a stale desktop row cannot prove the server rejected AXValue.
        // Preserve the ownership error and checkpoint, without a compensating write.
        #expect(throws: ActionError.actionUnavailable("群名输入框")) {
            try a.renameGroup(to: "新群名", window: fake.rootElement,
                              hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(checkpoints == 1 && fake.recordedActions.isEmpty)
        #expect(fake.recordedSets.filter { $0.handle == field.handle && $0.attribute == AXAttribute.value }.count == 1)
    }

    @Test func sharedCreateGroupNameHelperKeepsOneConfirmAndSkipsRenameRowGate() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let before = try #require(try WeComReader(window: fake.rootElement).activeConversationHeader())
        let field = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        let row = try #require(try WeComReader(window: fake.rootElement).activeConversationRow())
        let rowTitle = try #require(row.handle.titleTextHandle(in: fake))
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [], enabled: [.createGroup]))
        a.groupOpenTimeout = 0.1; a.verifyInterval = 0.01
        var checkpoints = 0
        a.visualActionGate = { kind, title in
            #expect(kind == .createGroup && title == nil)
        }
        fake.reactions["action:\(AXAction.confirm)"] = {
            fake.mutate(rowTitle, attribute: AXAttribute.value, to: .string("新建群名"))
        }
        let out = try a.applyGroupName("新建群名", field: field, window: fake.rootElement,
                                       before: before.raw, actionKind: .createGroup,
                                       hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        #expect(out.verified && checkpoints == 1)
        #expect(fake.recordedActions.map(\.action) == [AXAction.confirm])
    }

    @Test func createGroupRechecksTheExactDoneButtonBeforeCheckpoint() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = try #require(sheet.customers.first?.name)
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        var checks = 0
        a.visualActionGate = { kind, title in
            checks += 1
            #expect(kind == .createGroup && title == nil)
            fake.mutate(done, attribute: AXAttribute.title, to: .string("取消"))
        }
        var checkpoints = 0
        let hooks = SubmitHooks(beforeIrreversible: { checkpoints += 1 })
        #expect(throws: ActionError.actionUnavailable("完成")) {
            try a.createGroup(members: [customer, colleague], app: fake.rootElement,
                              window: fake.rootElement, sheet: sheet, hooks: hooks)
        }
        #expect(checks == 1 && checkpoints == 0 && returns == 2)
        #expect(!fake.recordedActions.contains { $0.handle == done })
    }

    @Test func createGroupRejectsMemberRowsChangedDuringVisualDecision() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = try #require(sheet.customers.first?.name)
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton)
        let rowByName = [customer: try Self.rowNode(named: customer), colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value, let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var actions = actions([.openGroupPicker, .createGroup])
        var returns = 0
        actions.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable, node: Self.selectedRowNode(named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done.handle, attribute: AXAttribute.enabled, to: .bool(true))
        }
        let doneFrame = try #require(try done.frame())
        fake.appendChild(to: sheet.sheet.handle, node: AXNode(role: AXRole.button, title: "完成",
            frame: doneFrame.offsetBy(dx: 45, dy: 0), enabled: true, actions: [AXAction.press]))
        actions.visualSelect = { _, _, _, _, eligible, _ in
            #expect(eligible.count == 2)
            fake.replaceChildren(of: selectedTable, with: [
                AXNode(role: AXRole.row, frame: CGRect(x: 961, y: 424, width: 319, height: 36)),
                AXNode(role: AXRole.row, frame: CGRect(x: 961, y: 460, width: 319, height: 36)),
            ])
            return AIPlannerCandidate(id: "C0", kind: .press, element: done,
                                      role: AXRole.button, frame: doneFrame)
        }
        var checkpoints = 0
        #expect(throws: ActionError.actionUnavailable("完成")) {
            try actions.createGroup(members: [customer, colleague], app: fake.rootElement,
                                    window: fake.rootElement, sheet: sheet,
                                    hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(returns == 2 && checkpoints == 0 && !fake.recordedActions.contains { $0.handle == done.handle })
    }

    @Test func createGroupRejectsSameCountDifferentSelectedNameBeforeCheckpoint() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = try #require(sheet.customers.first?.name)
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable)
        let done = try #require(sheet.doneButton)
        let rowByName = [customer: try Self.rowNode(named: customer),
                         colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value,
               let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable.handle, node: Self.selectedRowNode(
                named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done.handle, attribute: AXAttribute.enabled, to: .bool(true))
        }
        a.visualActionGate = { _, _ in
            let rows = try selectedTable.children()
            let label = rows.last?.descendants(maxDepth: 4, maxNodes: 40)
                .first { (try? $0.role()) == AXRole.staticText }
            if let label { fake.mutate(label.handle, attribute: AXAttribute.value, to: .string("另一位合成人员")) }
        }
        var checkpoints = 0
        #expect(throws: ActionError.actionUnavailable("完成")) {
            try a.createGroup(members: [customer, colleague], app: fake.rootElement,
                              window: fake.rootElement, sheet: sheet,
                              hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        }
        #expect(returns == 2 && checkpoints == 0)
        #expect(!fake.recordedActions.contains { $0.handle == done.handle })
    }

    @Test func createGroupDoesNotTreatOldGroupCountOrHeaderChangeAsCreation() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let customer = try #require(sheet.customers.first?.name)
        let colleague = try #require(try sheet.rows().last?.name)
        let selectedTable = try #require(sheet.selectedTable)
        let done = try #require(sheet.doneButton)
        let rowByName = [customer: try Self.rowNode(named: customer),
                         colleague: try Self.rowNode(named: colleague)]
        fake.reactions["set:\(AXAttribute.value)"] = {
            if case .string(let typed)? = fake.recordedSets.last?.value,
               let row = rowByName[typed] {
                fake.replaceChildren(of: sheet.outline.handle, with: [row])
            }
        }
        var a = actions([.openGroupPicker, .createGroup])
        a.groupOpenTimeout = 0.03
        var returns = 0
        a.postReturnKey = { _, _ in
            returns += 1
            fake.appendChild(to: selectedTable.handle, node: Self.selectedRowNode(
                named: (try? sheet.searchField?.valueString()) ?? "", y: 388 + 36 * CGFloat(returns)))
            fake.mutate(done.handle, attribute: AXAttribute.enabled, to: .bool(true))
        }
        fake.reactions["action:AXPress"] = {
            if let parent = try? sheet.sheet.parent() {
                fake.removeChild(sheet.sheet.handle, from: parent.handle)
            }
            let frame = (try? WeComReader(window: fake.rootElement).layout.conversationTableFrame)
                ?? CGRect(x: 0, y: 80, width: 150, height: 700)
            fake.appendChild(to: fake.rootHandle, node: AXNode(
                role: AXRole.staticText, value: .string("另一个旧群(3)"),
                frame: CGRect(x: frame.maxX + 48, y: frame.minY - 28,
                              width: 250, height: 22)))
        }
        var checkpoints = 0
        let out = try a.createGroup(members: [customer, colleague],
                                    app: fake.rootElement, window: fake.rootElement,
                                    sheet: sheet,
                                    hooks: SubmitHooks(beforeIrreversible: { checkpoints += 1 }))
        #expect(checkpoints == 1 && returns == 2)
        #expect(!out.verified && out.details["opened"] == "false")
    }

    @Test func createGroupNeedsTwoMembersBeforeTouchingTheClient() throws {
        let fake = try Self.sheetFixture()
        #expect(throws: ActionError.localGuard(WeComActions.singleMemberGuard)) {
            try actions([.openGroupPicker, .createGroup]).createGroup(members: ["测试联系人A"], app: fake.rootElement, window: fake.rootElement)
        }
        #expect(fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func createGroupRefusesWhenReturnWouldChooseSomeoneElse() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let other = try #require(try sheet.rows().last?.name)   // listed after the customer: not the first result
        let customer = try Self.rowNode(named: sheet.customers[0].name), member = try Self.rowNode(named: other)
        fake.reactions["set:\(AXAttribute.value)"] = { fake.replaceChildren(of: sheet.outline.handle, with: [customer, member]) }
        var a = actions([.openGroupPicker, .createGroup])
        var returns = 0
        a.postReturnKey = { _, _ in returns += 1 }
        #expect(throws: ActionError.verifyFailed("the first search result for \(other) is someone else; Return would choose them")) {
            try a.createGroup(members: [other, sheet.customers[0].name], app: fake.rootElement, window: fake.rootElement, sheet: sheet)
        }
        #expect(returns == 0 && fake.recordedActions.contains { (try? AXElement(handle: $0.handle, backend: fake).title()) == "取消" })
    }

    @Test func memberRowChangedAfterFocusNeverReceivesReturn() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let wanted = try #require(sheet.customers.first?.name)
        let other = try #require(try sheet.rows().last?.name)
        let wantedRow = try Self.rowNode(named: wanted)
        let otherRow = try Self.rowNode(named: other)
        fake.reactions["set:\(AXAttribute.value)"] = {
            fake.replaceChildren(of: sheet.outline.handle, with: [wantedRow])
        }
        fake.reactions["set:\(AXAttribute.focused)"] = {
            fake.replaceChildren(of: sheet.outline.handle, with: [otherRow])
        }
        var actions = actions([.openGroupPicker, .createGroup])
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        #expect(throws: ActionError.verifyFailed("picker member identity changed before Return")) {
            try actions.pickMembers([wanted], in: sheet, app: fake.rootElement,
                                    pid: fake.pid, skipDisabled: false)
        }
        #expect(returns == 0)
    }

    @Test func createGroupRefusesUnknownMembersBeforeDone() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(throws: ActionError.targetNotFound("nobody")) {
            try actions([.openGroupPicker, .createGroup]).createGroup(members: ["nobody", "x"], app: fake.rootElement, window: fake.rootElement, sheet: sheet)
        }
        #expect(fake.recordedActions.contains { $0.action == AXAction.press && (try? AXElement(handle: $0.handle, backend: fake).title()) == "取消" })
    }

    @Test func readContactsReturnsCustomersOnlyAndCancels() throws {
        let (fake, sheetNode) = try Self.closedSheetFixture()
        var actions = actions([.openGroupPicker])
        actions.postShortcut = { _, _ in _ = fake.appendChild(to: fake.rootHandle, node: sheetNode) }
        fake.reactions["action:\(AXAction.press)"] = {
            let root = try? AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
            if let root { fake.replaceChildren(of: fake.rootHandle, with: root.children.filter { $0.role != AXRole.sheet }) }
        }
        let contacts = try actions.readContacts(app: fake.rootElement, window: fake.rootElement, limit: 50)
        #expect(contacts.count == 1 && contacts[0].section == "我的客户")
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func existingAddMembersSheetIsNeitherReusedNorCancelled() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json")))
        var actions = actions([.openGroupPicker, .createGroup])
        var shortcuts = 0
        actions.postShortcut = { _, _ in shortcuts += 1 }
        #expect(throws: ActionError.actionUnavailable("发起群聊：已有弹窗")) {
            try actions.readContacts(app: fake.rootElement, window: fake.rootElement, limit: 20)
        }
        #expect(throws: ActionError.actionUnavailable("发起群聊：已有弹窗")) {
            try actions.createGroup(members: ["合成人员甲", "合成人员乙"], app: fake.rootElement, window: fake.rootElement)
        }
        #expect(shortcuts == 0 && fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func existingCreateGroupSheetIsNotReusedForContactList() throws {
        let fake = try Self.sheetFixture()
        var actions = actions([.openGroupPicker])
        var shortcuts = 0
        actions.postShortcut = { _, _ in shortcuts += 1 }
        #expect(throws: ActionError.actionUnavailable("发起群聊：已有弹窗")) {
            try actions.readContacts(app: fake.rootElement, window: fake.rootElement, limit: 20)
        }
        #expect(shortcuts == 0 && fake.recordedActions.isEmpty && fake.recordedSets.isEmpty)
    }

    @Test func openingWrongOrMultipleSheetsNeverReturnsPicker() throws {
        let (wrong, _) = try Self.closedSheetFixture()
        let add = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-members-sheet.json"))
        let wrongSheet = try #require(add.children.first { $0.role == AXRole.sheet })
        var a = actions([.openGroupPicker])
        a.postShortcut = { _, _ in _ = wrong.appendChild(to: wrong.rootHandle, node: wrongSheet) }
        #expect(throws: ActionError.verifyFailed("发起群聊面板未唯一打开")) {
            try a.openGroupPicker(app: wrong.rootElement, window: wrong.rootElement)
        }
        #expect(wrong.recordedActions.isEmpty)

        let (multiple, node) = try Self.closedSheetFixture()
        a = actions([.openGroupPicker])
        a.postShortcut = { _, _ in
            _ = multiple.appendChild(to: multiple.rootHandle, node: node)
            _ = multiple.appendChild(to: multiple.rootHandle, node: node)
        }
        #expect(throws: ActionError.verifyFailed("发起群聊面板未唯一打开")) {
            try a.openGroupPicker(app: multiple.rootElement, window: multiple.rootElement)
        }
        #expect(multiple.recordedActions.isEmpty)
    }

    @Test func ambiguousPickerScrollBarsFailBeforeAnyBarWriteAndCancelOwnedSheet() throws {
        let (fake, node) = try Self.closedSheetFixture()
        var actions = actions([.openGroupPicker])
        actions.postShortcut = { _, _ in
            guard let sheet = fake.appendChild(to: fake.rootHandle, node: node),
                  let picker = try? GroupPickerSheet.locate(window: fake.rootElement),
                  let parent = try? picker.outline.parent() else { return }
            _ = sheet
            _ = fake.appendChild(to: parent.handle, node: AXNode(role: AXRole.scrollBar,
                value: .number(0), frame: CGRect(x: 950, y: 387, width: 17, height: 494),
                settable: [AXAttribute.value]))
        }
        fake.reactions["action:\(AXAction.press)"] = {
            let root = try? AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
            if let root { fake.replaceChildren(of: fake.rootHandle, with: root.children.filter { $0.role != AXRole.sheet }) }
        }
        #expect(throws: ActionError.actionUnavailable("contact.list：选人列表滚动条不唯一")) {
            try actions.readContacts(app: fake.rootElement, window: fake.rootElement, limit: 50)
        }
        #expect(!fake.recordedSets.contains { $0.attribute == AXAttribute.value })
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func collapsedCustomersSectionIsExpandedBySelectingItsRow() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(try sheet.customersHeaderRow() != nil)
        #expect(try sheet.expandCustomers(wait: { try $0() }) && fake.recordedSets.isEmpty)   // already expanded: nothing touched
        // collapse: blank the contact's name so no row is listed under 我的客户; selecting the header restores it
        let contactRow = sheet.customers[0].row
        let cell = try #require(try contactRow.children().first { (try? $0.role()) == AXRole.cell })
        let nameText = try #require(try cell.children().first { (try? $0.role()) == AXRole.textArea })
        let name = try #require(try nameText.valueString())
        fake.mutate(nameText.handle, attribute: AXAttribute.value, to: .string(""))
        #expect(sheet.customers.isEmpty)
        fake.reactions["set:\(AXAttribute.selectedRows)"] = { fake.mutate(nameText.handle, attribute: AXAttribute.value, to: .string(name)) }
        #expect(try sheet.expandCustomers(wait: { try $0() }))
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.selectedRows } && sheet.customers.count == 1)
    }
}

extension AXElementHandle {
    /// The title static text of a conversation row in the fake (leftmost static text of the row's top band).
    func titleTextHandle(in fake: FakeAXBackend) -> AXElementHandle? {
        let row = AXElement(handle: self, backend: fake)
        var best: (AXElementHandle, CGRect)?
        for element in row.descendants(maxDepth: 3, maxNodes: 50) {
            guard (try? element.role()) == AXRole.staticText, let frame = try? element.frame() else { continue }
            if let current = best {
                let higher = frame.minY < current.1.minY
                let sameBandLeft = frame.minY == current.1.minY && frame.minX < current.1.minX
                if higher || sameBandLeft { best = (element.handle, frame) }
            } else {
                best = (element.handle, frame)
            }
        }
        return best?.0
    }
}

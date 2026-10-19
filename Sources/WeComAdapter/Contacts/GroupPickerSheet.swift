import AXKit
import CoreGraphics

public struct PickerContact: Equatable {
    public var name: String
    public var tag: String?
    public var source: String
    public var section: String
    public var row: AXElement
    /// 添加群成员 only: true when the cell carries the client's `checkbox selected disabled` image —
    /// this person is already in the group and cannot be selected again (live 2026-09-23).
    public var disabled: Bool = false

    public static func == (a: PickerContact, b: PickerContact) -> Bool { a.name == b.name && a.section == b.section && a.tag == b.tag }
}

/// The 发起群聊 sheet opened by the + button (2026-09-15, 5.0.11), and the same widget family's 添加群成员
/// sheet opened from an existing group's header buttons (2026-09-23): a search field and an outline on
/// the left, the chosen members on the right, 取消 below and either 完成 or 确定 — `titleText` (the
/// right-hand group's `AXStaticText`) tells the two apart via `isAddMembers`. Rows are classified by the
/// indentation of their first text: section headers (我的客户, the company) indented ≤ 70 px from the
/// outline's left edge, the 微信联系人 group header ≤ 92 px, items beyond. Contact rows carry a trailing
/// "@微信" tag; in 添加群成员 a row for someone already in the group is `PickerContact.disabled`.
public struct GroupPickerSheet {
    public let sheet: AXElement
    public let searchField: AXElement?
    public let outline: AXElement
    public let selectedTable: AXElement?
    public let doneButton: AXElement?
    public let cancelButton: AXElement?
    /// The right-hand group's title (发起群聊 / 添加群成员), when the sheet has one.
    public let titleText: String?

    public static let customersSection = "我的客户"

    /// True for the 添加群成员 variant of this sheet family (B14, live 2026-09-23).
    public var isAddMembers: Bool { titleText == "添加群成员" }

    public static func locate(window: AXElement) throws -> GroupPickerSheet? {
        guard let sheet = try window.children().first(where: { (try? $0.role()) == AXRole.sheet }) else { return nil }
        let descendants = sheet.descendants(maxDepth: 8, maxNodes: 2000)
        var searchField: AXElement?, outline: AXElement?, selectedTable: AXElement?, done: AXElement?, cancel: AXElement?
        for e in descendants {
            switch try e.role() {
            case AXRole.textField: if searchField == nil { searchField = e }
            case AXRole.outline: if outline == nil { outline = e }
            case AXRole.table: if selectedTable == nil { selectedTable = e }
            case AXRole.button:
                switch try e.title() {
                case "完成", "确定": done = e
                case "取消": cancel = e
                default: break
                }
            default: break
            }
        }
        guard let outline else { throw WeComError.region("groupPicker.outline") }
        // The sheet's own title (发起群聊 / 添加群成员) sits in the right-hand group, past the outline's
        // right edge — the same left/right split the row indentation math below relies on.
        let rightEdge = (try? outline.frame())??.maxX ?? .infinity
        var titleText: String?
        for e in descendants where (try? e.role()) == AXRole.staticText {
            guard let text = try e.valueString(), !text.isEmpty, let frame = try e.frame(), frame.minX > rightEdge else { continue }
            titleText = text
            break
        }
        return GroupPickerSheet(sheet: sheet, searchField: searchField, outline: outline, selectedTable: selectedTable, doneButton: done, cancelButton: cancel, titleText: titleText)
    }

    public static let sectionHeaderIndent: CGFloat = 70
    public static let groupHeaderIndent: CGFloat = 92

    public func rows() throws -> [PickerContact] {
        var out: [PickerContact] = []
        var section = ""
        let outlineMinX = (try? outline.frame())??.minX ?? 0
        for row in try outline.children() where (try? row.role()) == AXRole.row {
            // the client rebuilds rows while disclosing / filtering: a row gone stale is skipped, not fatal
            guard let rowChildren = try? row.children() else { continue }
            let cell = rowChildren.first { (try? $0.role()) == AXRole.cell } ?? row
            guard let cellChildren = try? cell.children() else { continue }
            var name: (String, CGRect)?
            var trailing: [(String, CGRect)] = []
            var disabled = false
            for child in cellChildren {
                let role = try child.role()
                // 添加群成员 only: an already-in-the-group row carries this checkbox image (live 2026-09-23);
                // checked before the value guard below since images carry no AXValue.
                if role == AXRole.image, let d = try child.axDescription(), d.contains("checkbox selected disabled") { disabled = true }
                guard let v = try child.valueString(), !v.isEmpty, let f = try child.frame() else { continue }
                if role == AXRole.textArea, name == nil { name = (v, f) } else if role == AXRole.staticText { trailing.append((v, f)) }
            }
            guard let (text, frame) = name else { continue }
            // Indents measured from the outline's left edge (the sheet is centered, so screen x moves with the window):
            // section headers ~53 px, group headers (微信联系人) ~85 px, items ≥ 97 px (5.0.11 recording).
            let indent = frame.minX - outlineMinX
            if indent <= Self.sectionHeaderIndent { section = text; continue }
            if indent <= Self.groupHeaderIndent { continue }
            let tag = trailing.first { $0.1.minX > frame.maxX }?.0
            let source = (tag ?? "").contains("微信") ? "wechat" : "wecom"
            out.append(PickerContact(name: text, tag: tag, source: source, section: section, row: row, disabled: disabled))
        }
        return out
    }

    public var customers: [PickerContact] { (try? rows().filter { $0.section == Self.customersSection }) ?? [] }

    /// Writable bars immediately beside this sheet's contact outline. An
    /// unrelated or unframed sibling makes a full-list read unsafe: AXValue on
    /// some other bar would prove movement but not which rows were visited.
    public func visibleWritableContactBars() throws -> [AXElement] {
        let siblings = try outline.parent()?.children() ?? []
        let bars = try siblings.filter {
            try $0.role() == AXRole.scrollBar && $0.isSettable(AXAttribute.value)
        }
        guard !bars.isEmpty else { return [] }
        guard let outlineFrame = try outline.frame(), let sheetFrame = try sheet.frame(),
              outlineFrame.width > 0, outlineFrame.height > 0 else {
            throw WeComError.region("groupPicker.contactScrollBar")
        }
        for bar in bars {
            guard let frame = try bar.frame(), frame.width > 0, frame.height > frame.width * 2,
                  abs(frame.minX - (outlineFrame.maxX - frame.width)) <= 24,
                  abs(frame.minY - outlineFrame.minY) <= 8,
                  abs(frame.height - outlineFrame.height) <= 12,
                  frame.minX >= sheetFrame.minX - 8,
                  frame.maxX <= sheetFrame.maxX + 8 else {
                throw WeComError.region("groupPicker.contactScrollBar")
            }
        }
        return bars
    }

    /// The 我的客户 section row (its first text at the section indentation).
    public func customersHeaderRow() throws -> AXElement? {
        for row in try outline.children() where (try? row.role()) == AXRole.row {
            let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
            if try cell.children().contains(where: { (try? $0.role()) == AXRole.textArea && (try? $0.valueString()) == Self.customersSection }) {
                return row
            }
        }
        return nil
    }

    /// Collapsed groups: rows whose AXDisclosing is settable and false.
    public func collapsedGroups(below header: AXElement? = nil) throws -> [AXElement] {
        let floor = try header?.frame()?.minY ?? -.infinity
        return try outline.children().filter { row in
            (try? row.role()) == AXRole.row && (try? row.isSettable(AXAttribute.disclosing)) == true
                && (try? row.bool(AXAttribute.disclosing)) == false && ((try? row.frame())??.minY ?? -.infinity) > floor
        }
    }

    /// 我的客户 is collapsed when the sheet opens, and so is the 微信联系人
    /// group under it (live 2026-09-15: AXDisclosing false and settable on
    /// both; the contacts sit at disclosure level 2). Discloses the section,
    /// then every collapsed group below it, falling back to selecting the row
    /// and to the row's own button; true once contact rows are listed.
    public func expandCustomers(wait: (() throws -> Bool) throws -> Bool) throws -> Bool {
        if !customers.isEmpty { return true }
        guard let row = try customersHeaderRow() else { return false }
        if try row.isSettable(AXAttribute.disclosing) {
            try row.setAttribute(AXAttribute.disclosing, to: .bool(true))
            for _ in 0..<4 where customers.isEmpty {
                guard let group = try collapsedGroups(below: row).first(where: { (try? $0.frame())??.minY ?? 0 < (try? nextSectionY(after: row)) ?? .infinity }) else { break }
                try group.setAttribute(AXAttribute.disclosing, to: .bool(true))
                _ = try wait { !self.customers.isEmpty || (try? self.collapsedGroups(below: row).isEmpty) == true }
            }
            if !customers.isEmpty { return true }
        }
        let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
        let attempts: [() throws -> Void] = [
            {
                guard try row.isSettable(AXAttribute.disclosing) else { throw WeComError.region("groupPicker.disclosing") }
                try row.setAttribute(AXAttribute.disclosing, to: .bool(true))
            },
            { try self.outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle])) },
            {
                guard let button = try cell.children().first(where: { (try? $0.role()) == AXRole.button }) else { throw WeComError.region("groupPicker.rowButton") }
                try button.perform(AXAction.press)
            },
        ]
        for attempt in attempts {
            guard (try? attempt()) != nil else { continue }
            if try wait({ !self.customers.isEmpty }) { return true }
        }
        return false
    }

    /// Top of the next level-0 row after `row` (the next section), if any.
    func nextSectionY(after row: AXElement) throws -> CGFloat? {
        let y = try row.frame()?.minY ?? 0
        return try outline.children().compactMap { r -> CGFloat? in
            guard (try? r.role()) == AXRole.row, let f = try? r.frame(), f.minY > y, f.height > 20,
                  case .integer(0)? = try? r.attribute(AXAttribute.disclosureLevel) else { return nil }
            return f.minY
        }.min()
    }

    /// True once the outline shows search results only: every row is an item
    /// (the unfiltered list also has section and spacer rows).
    public func isFiltered() throws -> Bool {
        let rowCount = try outline.children().filter { (try? $0.role()) == AXRole.row }.count
        let items = try rows().count
        return rowCount > 0 && rowCount == items
    }

    public func selectedCount() throws -> Int {
        try selectedTable?.children().filter { (try? $0.role()) == AXRole.row }.count ?? 0
    }

    /// The chosen table must expose one unambiguous AX text per selected row
    /// before member selection can be trusted. A row count alone cannot prove
    /// that Return picked the person named in the command.
    public func selectedMemberNames() throws -> [String]? {
        guard let selectedTable else { return nil }
        var names: [String] = []
        for row in try selectedTable.children() where try row.role() == AXRole.row {
            let texts = row.descendants(maxDepth: 4, maxNodes: 40).compactMap { element -> String? in
                guard (try? element.role()) == AXRole.staticText,
                      let value = try? element.valueString(), !value.isEmpty else { return nil }
                return value
            }
            guard texts.count == 1 else { return nil }
            names.append(texts[0])
        }
        return names
    }
}

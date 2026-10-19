import AXKit
import ControlCore
import Foundation

private struct GroupCreationListAnchor {
    let rowHandles: Set<AXElementHandle>
    let titles: Set<String>
    let rowCount: Int

    init(rows: [ConversationRow]) {
        rowHandles = Set(rows.map(\.handle))
        titles = Set(rows.compactMap(\.title))
        rowCount = rows.count
    }
}

private struct CreatedGroupEvidence {
    let header: ConversationHeader
    let row: ConversationRow
}

public extension WeComActions {
    /// 完成 with one member opens the direct chat instead of creating a group (live 2026-09-15).
    static let singleMemberGuard = "a group needs at least 2 members: the client opens a direct chat for one"

    /// ⌘N (发起群聊) with the client frontmost: the + button ignores AXPress
    /// (live 2026-09-15, both with and without focus). Callers hand focus back.
    func openGroupPicker(app: AXElement, window: AXElement) throws -> GroupPickerSheet {
        try policy.authorize(.openGroupPicker, target: nil)
        // A sheet visible before this command belongs to the user or another
        // workflow. In particular, 添加群成员 has the same outline as 发起群聊.
        guard try pickerSheets(in: window).isEmpty else {
            throw ActionError.actionUnavailable("发起群聊：已有弹窗")
        }
        let pid = try app.pid()
        let windowPID = try window.pid()
        let windowFrame = try window.frame()
        guard pid == windowPID, pid > 0, windowFrame != nil else {
            throw ActionError.actionUnavailable("发起群聊窗口")
        }
        try bringToFront(app: app, pid: pid)
        guard try pickerSheets(in: window).isEmpty,
              try window.pid() == windowPID,
              try window.frame() == windowFrame else {
            throw ActionError.actionUnavailable("发起群聊窗口")
        }
        _ = try withFront(app: app, pid: pid) {
            guard try pickerSheets(in: window).isEmpty,
                  try window.pid() == windowPID,
                  try window.frame() == windowFrame else {
                throw ActionError.actionUnavailable("发起群聊窗口")
            }
            try postShortcut(.commandN, pid)
        }
        var sheet: GroupPickerSheet?
        let shown = try waitUntil {
            guard (try? pickerSheets(in: window).count) == 1 else { return false }
            sheet = try? GroupPickerSheet.locate(window: window) // the outline lags the sheet by a beat
            return sheet?.titleText == "发起群聊"
        }
        guard shown, let sheet,
              try pickerSheets(in: window).count == 1,
              try window.pid() == windowPID,
              try window.frame() == windowFrame,
              sheet.titleText == "发起群聊", !sheet.isAddMembers,
              sheet.searchField != nil, sheet.selectedTable != nil,
              sheet.cancelButton != nil,
              try sheet.doneButton?.title() == "完成",
              try sheet.selectedCount() == 0 else {
            throw ActionError.verifyFailed("发起群聊面板未唯一打开")
        }
        return sheet
    }

    private func pickerSheets(in window: AXElement) throws -> [AXElement] {
        try window.children().filter { try $0.role() == AXRole.sheet }
    }

    func closeGroupPicker(_ sheet: GroupPickerSheet, window: AXElement) throws {
        let current = try pickerSheets(in: window)
        guard current.count == 1, current[0].handle == sheet.sheet.handle,
              let fresh = try GroupPickerSheet.locate(window: window),
              ["发起群聊", "添加群成员"].contains(sheet.titleText ?? ""),
              fresh.titleText == sheet.titleText, fresh.isAddMembers == sheet.isAddMembers,
              fresh.outline.handle == sheet.outline.handle,
              fresh.searchField?.handle == sheet.searchField?.handle,
              fresh.selectedTable?.handle == sheet.selectedTable?.handle,
              let cancel = fresh.cancelButton,
              try cancel.title() == "取消" else {
            throw ActionError.actionUnavailable("发起群聊：无法确认本命令面板")
        }
        try cancel.perform(AXAction.press)
        guard try waitUntil({ try pickerSheets(in: window).isEmpty }) else {
            throw ActionError.verifyFailed("发起群聊面板未关闭")
        }
    }

    enum ContactScope { case customers, all }

    /// Reads the picker's rows — 我的客户 only, or every section (B9: colleagues
    /// for default group members) — expanding collapsed groups first and moving
    /// the outline's scroll bar to reach rows the client has not laid out; the
    /// sheet is cancelled and focus handed back afterwards.
    func readContacts(app: AXElement, window: AXElement, limit: Int, scope: ContactScope = .customers) throws -> [PickerContact] {
        let previous = frontmostPid()
        let clientPid = try? app.pid()
        defer {
            if let previous, previous != clientPid { restoreFrontmost(previous) }
        }
        let sheet = try openGroupPicker(app: app, window: window)
        var closeAttempted = false
        do {
            _ = try sheet.expandCustomers(wait: { try self.waitUntil($0) })
            if scope == .all {
                for group in (try? sheet.collapsedGroups()) ?? [] where (try? group.isSettable(AXAttribute.disclosing)) == true {
                    try? group.setAttribute(AXAttribute.disclosing, to: .bool(true))
                }
            }
            var seen: [String: PickerContact] = [:]
            var order: [String] = []
            let bars = try sheet.visibleWritableContactBars()
            // Choosing either of two picker bars can silently skip contacts.
            // The visual path also requires exactly one current AX candidate.
            guard bars.count <= 1 else { throw ActionError.actionUnavailable("contact.list：选人列表滚动条不唯一") }
            func collectVisibleRows() {
                for c in (scope == .all ? ((try? sheet.rows()) ?? []) : sheet.customers) where seen[c.name] == nil {
                    seen[c.name] = c
                    order.append(c.name)
                }
            }
            // A reused picker may open in the middle of the list. Always
            // establish the top before collecting rows, even if this viewport
            // already has enough contacts to satisfy the requested limit.
            if let originalBar = bars.first {
                var bar = originalBar
                var visualRecheck: (() throws -> Void)?
                func ensureOwnedBar() throws {
                    guard try pickerSheets(in: window).count == 1,
                          let fresh = try GroupPickerSheet.locate(window: window),
                          fresh.sheet.handle == sheet.sheet.handle,
                          fresh.titleText == "发起群聊", !fresh.isAddMembers,
                          fresh.outline.handle == sheet.outline.handle,
                          fresh.searchField?.handle == sheet.searchField?.handle,
                          fresh.selectedTable?.handle == sheet.selectedTable?.handle,
                          try fresh.selectedCount() == 0,
                          try fresh.visibleWritableContactBars().map(\.handle) == [bar.handle],
                          try bar.isSettable(AXAttribute.value) else {
                        throw ActionError.actionUnavailable("contact.list：选人面板已变化")
                    }
                    try visualRecheck?()
                }
                for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    if order.count >= limit { break }
                    try ensureOwnedBar()
                    let current = try bar.value()?.doubleValue
                    guard let current, current.isFinite else {
                        throw ActionError.actionUnavailable("contact.list：滚动条值不可读")
                    }
                    if abs(current - p) > 0.01 {
                        if visualRecheck == nil, let visualContactListScrollRounds {
                            let choice = try visualContactListScrollRounds(window, sheet, bar, p)
                            guard choice.bar.handle == bar.handle else {
                                throw ActionError.actionUnavailable("contact.list：滚动条已变化")
                            }
                            bar = choice.bar
                            visualRecheck = choice.recheck
                        } else {
                            try ensureOwnedBar()
                            try bar.setAttribute(AXAttribute.value, to: .double(p))
                        }
                        try ensureOwnedBar()
                        guard let actual = try bar.value()?.doubleValue, abs(actual - p) <= 0.01 else {
                            throw ActionError.verifyFailed("contact.list：滚动条未到请求位置")
                        }
                    }
                    collectVisibleRows()
                }
            } else {
                collectVisibleRows()
            }
            let result = order.prefix(limit).compactMap { seen[$0] }
            closeAttempted = true
            try closeGroupPicker(sheet, window: window)
            return result
        } catch {
            if !closeAttempted { try? closeGroupPicker(sheet, window: window) }
            throw error
        }
    }

    /// Per member: type the name into the sheet's search field, check that the
    /// first (and only) result is that name, focus the field and post the
    /// pid-level Return — the client then lists the member on the right (live
    /// 2026-09-15: rows accept no AX selection, press or focus; Return on the
    /// search field is the one AX-reachable way to choose). Each Return first
    /// brings the client back when it lost the front (`withFront`); `refronts`
    /// counts those. `createGroup` (`skipDisabled: false`) is unchanged by this
    /// B14 extraction: an unknown, ambiguous, or unverified member still aborts
    /// the whole call (`targetNotFound` / `targetAmbiguous` / `verifyFailed`).
    /// The add-members flow (`skipDisabled: true`, live 2026-09-23) instead
    /// records the member in `skipped` and moves on to the next one: a row
    /// already in the group (`checkbox selected disabled`) is `alreadyMember`
    /// without ever posting Return, an unmatched name is `notFound`, several
    /// rows sharing the name are `ambiguous` — so retrying a partially-failed
    /// add-members call is safe, since the people already added are skipped
    /// the same way next time. Return is never repeated: the chosen table must
    /// show the exact newly selected name, since a larger count proves no
    /// identity. Missing or conflicting AX names fail before 完成 / 确定.
    func pickMembers(_ members: [String], in sheet: GroupPickerSheet, app: AXElement, pid: pid_t, skipDisabled: Bool) throws -> (added: [String], skipped: [(name: String, reason: String)], refronts: Int) {
        guard let field = sheet.searchField else { throw ActionError.actionUnavailable("搜索") }
        var added: [String] = []
        var skipped: [(name: String, reason: String)] = []
        var refronts = 0
        for member in members {
            var results: [PickerContact] = []
            var filtered = false
            // Live 2026-09-16: right after the sheet opened, the first search came back without the member
            // (a stale result list); typing the same text again a moment later found them. One retry.
            for attempt in 0..<2 where !filtered {
                if attempt > 0 { try? field.setAttribute(AXAttribute.value, to: .string("")); Thread.sleep(forTimeInterval: 0.4); trace?("picker: search retry for \(member.count) chars") }
                try field.setAttribute(AXAttribute.value, to: .string(member))
                // wait for the filtered list (the expanded list already contains the member before the filter lands)
                filtered = try waitUntil {
                    results = (try? sheet.rows()) ?? []
                    return (try? sheet.isFiltered()) == true && results.first?.name == member
                }
            }
            if !filtered {
                // never the names themselves: lengths and how each result relates to the wanted member
                let shape = results.map { r -> String in
                    let rel = r.name == member ? "=" : (r.name.hasPrefix(member) ? "prefix" : (r.name.contains(member) ? "contains" : "other"))
                    return "\(r.name.count)c/\(r.section.count)c/\(r.source)/\(rel)"
                }
                trace?("picker: search for \(member.count) chars → filtered=\((try? sheet.isFiltered()) == true) results=\(results.count) [\(shape.joined(separator: " "))]")
                guard (try? sheet.isFiltered()) == true, results.contains(where: { $0.name == member }) else {
                    if skipDisabled { skipped.append((member, "notFound")); continue }
                    throw ActionError.targetNotFound(member)
                }
                throw ActionError.verifyFailed("the first search result for \(member) is someone else; Return would choose them")
            }
            let matches = results.filter { $0.name == member }.count
            guard matches == 1 else {
                if skipDisabled {
                    trace?("picker: search for \(member.count) chars ambiguous (\(matches) matches), skipped")
                    skipped.append((member, "ambiguous"))
                    continue
                }
                throw ActionError.targetAmbiguous(member, count: matches)
            }
            if skipDisabled, results.first?.disabled == true {
                trace?("picker: search for \(member.count) chars matched an existing member, skipped")
                skipped.append((member, "alreadyMember"))
                continue
            }
            guard let beforeNames = try sheet.selectedMemberNames() else {
                throw ActionError.verifyFailed("picker chosen member identities unavailable")
            }
            if (try? field.isSettable(AXAttribute.focused)) == true { try field.setAttribute(AXAttribute.focused, to: .bool(true)) }
            let refront = try withFront(app: app, pid: pid) {
                guard let window = try sheet.sheet.parent(),
                      let fresh = try GroupPickerSheet.locate(window: window),
                      fresh.sheet.handle == sheet.sheet.handle,
                      fresh.searchField?.handle == field.handle,
                      fresh.outline.handle == sheet.outline.handle,
                      fresh.selectedTable?.handle == sheet.selectedTable?.handle,
                      try field.valueString() == member,
                      try fresh.isFiltered(),
                      try fresh.selectedMemberNames() == beforeNames else {
                    throw ActionError.verifyFailed("picker member identity changed before Return")
                }
                let freshRows = try fresh.rows()
                guard freshRows.count == 1, freshRows[0].name == member,
                      !freshRows[0].disabled else {
                    throw ActionError.verifyFailed("picker member identity changed before Return")
                }
                try postReturnKey(pid, false)
            }
            if !refront.isEmpty { refronts += 1; trace?("picker: Return for member \(added.count + 1)\(refront)") }
            var afterNames: [String]?
            guard try waitUntil({
                afterNames = try sheet.selectedMemberNames()
                return afterNames?.count == beforeNames.count + 1
            }), afterNames == beforeNames + [member] else {
                throw ActionError.verifyFailed("Return on the search field did not select the requested member")
            }
            added.append(member)
            try? field.setAttribute(AXAttribute.value, to: .string(""))   // the client clears it itself; harmless when it already did
        }
        return (added, skipped, refronts)
    }

    /// Types each member into the sheet's search field and confirms with the
    /// pid-level Return (`pickMembers`, `skipDisabled: false`), then 完成. The
    /// add-members flow reuses the same loop with `skipDisabled: true`.
    func createGroup(members: [String], name: String? = nil, app: AXElement, window: AXElement,
                     sheet given: GroupPickerSheet? = nil, hooks: SubmitHooks = SubmitHooks()) throws -> ActionOutcome {
        try policy.authorize(.createGroup, target: nil)
        guard members.count >= 2 else { throw ActionError.localGuard(Self.singleMemberGuard) }
        guard Set(members).count == members.count,
              members.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ActionError.localGuard("group.create requires distinct nonempty member names")
        }
        let previous = frontmostPid()
        let pid = try app.pid()
        defer { if let previous, previous != pid { restoreFrontmost(previous) } }
        let sheet = try given ?? openGroupPicker(app: app, window: window)
        var selected = 0
        var refronts = 0
        do {
            _ = try sheet.expandCustomers(wait: { try self.waitUntil($0) })
            let picked = try pickMembers(members, in: sheet, app: app, pid: pid, skipDisabled: false)
            selected = picked.added.count
            refronts = picked.refronts
        } catch {
            try? closeGroupPicker(sheet, window: window)
            throw error
        }
        var crossedCheckpoint = false
        defer {
            if !crossedCheckpoint { try? closeGroupPicker(sheet, window: window) }
        }
        // The sheet may expose more than one completion control while it is rebuilding.
        // Only a button inside this sheet with the group-creation title is eligible.
        let doneCandidates = sheet.sheet.descendants(maxDepth: 8, maxNodes: 2000).filter {
            (try? $0.role()) == AXRole.button && (try? $0.title()) == "完成" && ((try? $0.isEnabled()) ?? true)
        }
        // Bind the model's completion choice to the members selected before
        // inference. A human changing rows while the request is in flight must
        // invalidate the old choice even when the selected count stays equal.
        let selectedHandles = try sheet.selectedTable?.children()
            .filter { (try? $0.role()) == AXRole.row }.map(\.handle) ?? []
        // A count or unchanged row handles do not prove who was selected.
        // The exact requested identities must remain in the command-owned
        // table across inference, checkpoint, and the final AXPress.
        guard try sheet.selectedMemberNames() == members,
              selectedHandles.count == members.count else {
            throw ActionError.verifyFailed("group.create selected member identities differ")
        }
        let done: AXElement
        if doneCandidates.count == 1 {
            done = doneCandidates[0]
        } else if doneCandidates.count > 1 {
            done = try visualChoice(window: window, goal: .control(.confirm), kind: .press,
                                    actionKind: .createGroup,
                                    expectedTitle: nil, eligible: doneCandidates, purpose: "发起群聊 完成")
        } else {
            try? closeGroupPicker(sheet, window: window)
            throw ActionError.actionUnavailable("完成")
        }
        let expectedPID = try window.pid()
        let expectedWindowFrame = try window.frame()
        func validateDone() throws {
            guard try window.pid() == expectedPID,
                  try window.frame() == expectedWindowFrame,
                  let fresh = try GroupPickerSheet.locate(window: window),
                  fresh.sheet.handle == sheet.sheet.handle,
                  fresh.titleText == "发起群聊", !fresh.isAddMembers,
                  fresh.selectedTable?.handle == sheet.selectedTable?.handle,
                  try fresh.selectedCount() == members.count,
                  try fresh.selectedMemberNames() == members,
                  try fresh.selectedTable?.children()
                    .filter({ (try? $0.role()) == AXRole.row }).map(\.handle) == selectedHandles,
                  let current = fresh.sheet.descendants(maxDepth: 8, maxNodes: 2000)
                    .first(where: { $0.handle == done.handle }),
                  try current.role() == AXRole.button,
                  try current.title() == "完成",
                  try current.actions().contains(AXAction.press),
                  try current.isEnabled() != false else {
                throw ActionError.actionUnavailable("完成")
            }
        }
        // The sidebar snapshot is required before Done. A mere changed active
        // header (or an old group with a count) cannot prove a new group.
        let beforeRows = try WeComReader(window: window).conversations()
        let listAnchor = GroupCreationListAnchor(rows: beforeRows)
        guard !beforeRows.isEmpty else {
            throw ActionError.actionUnavailable("group.create conversation list unavailable")
        }
        try visualActionGate?(.createGroup, nil)
        try validateDone()
        try visualObserveGroupCreate?(WeComReader(window: window), done, .beforeCompletion, {
            try validateDone()
            return true
        })
        try visualGroupCreateCommitGate?()
        try validateDone()
        try hooks.beforeIrreversible()
        crossedCheckpoint = true
        try visualActionGate?(.createGroup, nil)
        try visualGroupCreateCommitGate?()
        try validateDone()
        try done.perform(AXAction.press)
        try hooks.afterIrreversible()
        let closed = try waitUntil { (try? GroupPickerSheet.locate(window: window)) == nil }
        // WeCom switches asynchronously. Only a new selected sidebar row that
        // was absent from the pre-Done list, agrees with the active header, and
        // carries exact group-size or generated member-name evidence counts.
        // List rebuilding/virtualisation with insufficient identity is unknown.
        let started = Date()
        var created: CreatedGroupEvidence?
        if closed {
            while true {
                created = try? createdGroupEvidence(reader: WeComReader(window: window),
                                                    before: listAnchor, members: members)
                if created != nil || Date().timeIntervalSince(started) >= groupOpenTimeout { break }
                Thread.sleep(forTimeInterval: verifyInterval)
            }
        }
        let opened = created != nil
        trace?("picker: group \(opened ? "opened" : "not proven") after \(Int(Date().timeIntervalSince(started) * 1000))ms count=\(created?.header.memberCount.map(String.init) ?? "-")")
        if let created {
            let selected = AXElement(handle: created.row.handle, backend: window.backend)
            try visualObserveGroupCreate?(WeComReader(window: window), selected, .afterCompletion, {
                try createdGroupEvidence(reader: WeComReader(window: window),
                                         before: listAnchor, members: members)?.row.handle == created.row.handle
            })
        }
        // The requested name is written into the header field once the group is open (B8: the field is editable + AXConfirm).
        // The header is bounded by the new chat's message viewport (B49); if it never lays out, the group stays
        // created and proven but unnamed (`renamed` false) — naming is skipped before any write, not failed after 完成.
        var renamed = false
        var header = created?.header
        let viewportReady = opened && name != nil && waitForMessageViewport(window: window)
        if opened, name != nil, !viewportReady { trace?("picker: group opened; name skipped: no message viewport") }
        if viewportReady, let name, let field = try? groupNameField(window: window, title: header?.title, actionKind: .createGroup) {
            let applied = try applyGroupName(name, field: field, window: window, before: header?.raw,
                                             actionKind: .createGroup, hooks: hooks)
            renamed = applied.verified
            if renamed { header = try? WeComReader(window: window).activeConversationHeader() }
        }
        return ActionOutcome(kind: ActionKind.createGroup.rawValue, target: nil, verified: closed && opened, details: [
            "selected": String(selected), "refronts": String(refronts), "opened": opened ? "true" : "false", "renamed": renamed ? "true" : "false",
            "title": header?.title ?? "", "memberCount": header?.memberCount.map(String.init) ?? "",
        ])
    }

    /// A new title alone is weak evidence: another old conversation can take
    /// focus while the picker closes. Require one added, AX-selected sidebar
    /// identity, preservation of every previously visible row, matching group
    /// header, and an exact count or exact generated member-name tokens.
    private func createdGroupEvidence(reader: WeComReader,
                                      before: GroupCreationListAnchor,
                                      members: [String]) throws -> CreatedGroupEvidence? {
        let rows = try reader.conversations()
        let handles = Set(rows.map(\.handle))
        guard rows.count == before.rowCount + 1,
              before.rowHandles.isSubset(of: handles) else { return nil }
        let selected = rows.filter(\.selected)
        guard selected.count == 1, let row = selected.first,
              !before.rowHandles.contains(row.handle),
              let title = row.title, !title.isEmpty,
              !before.titles.contains(title),
              let header = try reader.activeConversationHeader(),
              header.title == title else { return nil }
        if let count = header.memberCount {
            guard count == members.count + 1 else { return nil }
        } else {
            let tokens = Set(title.split(whereSeparator: { "、，,".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            guard members.allSatisfy(tokens.contains) else { return nil }
        }
        return CreatedGroupEvidence(header: header, row: row)
    }
}

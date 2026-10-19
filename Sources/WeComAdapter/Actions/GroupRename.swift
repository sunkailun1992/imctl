import AXKit
import ControlCore
import Foundation

public extension WeComActions {
    /// A group's header title is an editable text field with an `AXConfirm`
    /// action (live 2026-09-15, 5.0.11, external group). Writing the value and
    /// confirming while the field is focused asks the client to rename the
    /// group; the header echoes the typed value at once, so the *list row* —
    /// which only changes once the server accepted the name — is the evidence
    /// (live 22:16: a confirm without focus changed the header only). The
    /// active conversation must be an allowlisted group.
    func renameGroup(to name: String, window: AXElement, hooks: SubmitHooks = SubmitHooks()) throws -> ActionOutcome {
        let reader = try WeComReader(window: window)
        let before = try reader.activeConversationHeader()
        try authorize(.renameGroup, title: before?.title)
        guard let field = try groupNameField(window: window, title: before?.title, actionKind: .renameGroup) else {
            throw WeComError.region("groupTitle")
        }
        return try applyGroupName(name, field: field, window: window, before: before?.raw,
                                  actionKind: .renameGroup, hooks: hooks)
    }

    /// When the layout parser cannot identify the header field, only editable fields
    /// in the conversation header — right of the conversation list, above the live
    /// message viewport — whose current value equals the observed group title are
    /// eligible. A visual choice resolves several such AX candidates; it cannot
    /// invent a field or change the target group. Without a viewport there is no
    /// header to bound, so nothing is eligible.
    func groupNameField(window: AXElement, title: String?, actionKind: ActionKind) throws -> AXElement? {
        let reader = try WeComReader(window: window)
        if let field = reader.layout.activeTitle { return field }
        guard let title, !title.isEmpty, let wf = try window.frame(),
              let viewport = reader.layout.messageViewportFrame(),
              let tableFrame = try reader.layout.conversationTable.frame() else { return nil }
        let eligible = window.descendants(maxDepth: 12, maxNodes: 6000).filter { element in
            guard (try? element.role()) == AXRole.textField,
                  (try? element.isSettable(AXAttribute.value)) == true,
                  let f = try? element.frame(),
                  Self.isInConversationHeader(f, windowFrame: wf, viewport: viewport, conversationList: tableFrame),
                  (try? element.valueString()) == title else { return false }
            return true
        }
        if eligible.count == 1 { return eligible[0] }
        if eligible.count > 1 {
            return try visualChoice(window: window, goal: .control(.groupNameField), kind: .writeText,
                                    actionKind: actionKind,
                                    expectedTitle: title, eligible: eligible, purpose: "群名输入框")
        }
        return nil
    }

    /// The header is bounded by the message viewport, which a chat that has just
    /// opened (a group `createGroup` proved a moment ago) may lay out after its
    /// header. Waits up to `verifyTimeout` for it; false means the header region
    /// cannot be proven, and nothing may be written.
    internal func waitForMessageViewport(window: AXElement) -> Bool {
        (try? waitUntil { (try? WeComReader(window: window))?.layout.messageViewportFrame() != nil }) ?? false
    }

    /// The group header's region, from live geometry: inside the window, right of the
    /// conversation list and ending above the message viewport's top (2 pt for its
    /// border). Replaces the 180 pt band below the window top recorded on 5.0.11
    /// (2026-09-15: title field y 20–44, viewport from y 80, 1200 pt window).
    internal static func isInConversationHeader(_ frame: CGRect, windowFrame: CGRect, viewport: CGRect,
                                                conversationList: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.minY >= windowFrame.minY && frame.maxY <= viewport.minY + 2
            && frame.minX > conversationList.maxX && frame.maxX <= windowFrame.maxX
    }

    /// Shared with `createGroup(name:)`, which is already authorised as a whole.
    /// Focus → value → `AXConfirm`; if the list row has not taken the name, the
    /// edit is ended by moving focus to the conversation table (blur) and the
    /// row is watched again. Not verified (no exception) when the header is
    /// not an editable field.
    func applyGroupName(_ name: String, field: AXElement, window: AXElement, before: String?,
                        actionKind: ActionKind, hooks: SubmitHooks = SubmitHooks()) throws -> ActionOutcome {
        guard try field.role() == AXRole.textField, try field.isSettable(AXAttribute.value) else {
            return ActionOutcome(kind: actionKind.rawValue, target: before, verified: false,
                                 details: ["renamed": "false", "requestedName": name, "reason": "header is not an editable text field"])
        }
        guard let before, !before.isEmpty else { throw ActionError.actionUnavailable("群名输入框") }
        let oldTitle = ConversationHeader.parse(before).title
        // The selected-row fallback can carry a member-count suffix while the
        // editable field contains only the group title. Keep the field's own
        // original value as the AX write precondition; the header is checked
        // separately so another conversation cannot be substituted.
        guard let originalFieldValue = try field.valueString(),
              originalFieldValue == before || originalFieldValue == oldTitle else {
            throw ActionError.actionUnavailable("群名输入框")
        }
        let gateTitle = actionKind.requiresTarget ? oldTitle : nil
        guard waitForMessageViewport(window: window) else { throw ActionError.actionUnavailable("群名输入框") }
        let originalRows = actionKind == .renameGroup ? try WeComReader(window: window).conversations() : []
        let originalSelected = originalRows.filter(\.selected)
        let originalRowHandle = originalSelected.count == 1 && originalSelected[0].title == oldTitle
            ? originalSelected[0].handle : nil
        let requestedNameWasAbsent = !originalRows.contains { $0.title == name }
        // A model-selected AX handle is only a proposal. Recheck the current header
        // field and the owning command immediately before each AX write, including
        // after the checkpoint and before AXConfirm.
        func validateField(value: String, header: String?) throws {
            if actionKind == .renameGroup { try authorize(.renameGroup, title: oldTitle) }
            let fresh = try WeComReader(window: window)
            let currentHeader = try fresh.activeConversationHeader()?.raw
            // Once AXValue is staged, the header may echo the requested name
            // before the server has changed the list row. The selected row is
            // still the original target; otherwise a stale field must not be
            // confirmed as a different conversation's title.
            let selectedTargetMatches: Bool
            if actionKind == .renameGroup {
                let selected = try fresh.conversations().filter(\.selected)
                selectedTargetMatches = selected.count == 1 && selected[0].title == oldTitle
                    && selected[0].handle == originalRowHandle
            } else {
                selectedTargetMatches = true
            }
            guard try field.pid() == window.pid(),
                  selectedTargetMatches,
                  try field.role() == AXRole.textField,
                  try field.isSettable(AXAttribute.value),
                  try field.valueString() == value,
                  let frame = try field.frame(),
                  let windowFrame = try window.frame(),
                  let viewport = fresh.layout.messageViewportFrame(),
                  Self.isInConversationHeader(frame, windowFrame: windowFrame, viewport: viewport,
                                              conversationList: fresh.layout.conversationTableFrame),
                  ((fresh.layout.activeTitle?.handle == field.handle) ||
                   (fresh.layout.activeTitle == nil && window.descendants(maxDepth: 12, maxNodes: 6000).contains { $0.handle == field.handle })),
                  (header == nil || currentHeader == header) else {
                throw ActionError.actionUnavailable("群名输入框")
            }
        }
        try visualActionGate?(actionKind, gateTitle)
        try validateField(value: originalFieldValue, header: before)
        if (try? field.isSettable(AXAttribute.focused)) == true { try? field.setAttribute(AXAttribute.focused, to: .bool(true)) }
        try visualActionGate?(actionKind, gateTitle)
        try validateField(value: originalFieldValue, header: before)
        if actionKind == .renameGroup {
            try visualObserveGroupName?(WeComReader(window: window), field, .beforeStaging, {
                try validateField(value: originalFieldValue, header: before)
                return true
            })
            try visualGroupNameStagingGate?()
        }
        try visualActionGate?(actionKind, gateTitle)
        try validateField(value: originalFieldValue, header: before)
        let stagedWindowPID = try window.pid()
        let stagedWindowFrame = try window.frame()
        let stagedFieldFrame = try field.frame()
        var checkpointRecorded = false
        func checkpointOnce() throws {
            guard !checkpointRecorded else { return }
            try hooks.beforeIrreversible()
            checkpointRecorded = true
        }

        // The client may apply AXValue before AXConfirm. Only this exact row
        // and editor can prove that happened; a matching title elsewhere cannot.
        func appliedNameIsOwned(after error: Error? = nil) throws -> Bool {
            guard actionKind == .renameGroup, name != oldTitle, requestedNameWasAbsent,
                  let originalRowHandle, let appliedGate = visualGroupNameAppliedGate,
                  let stagedWindowFrame, let stagedFieldFrame else { return false }
            func matches() throws -> Bool {
                guard try window.pid() == stagedWindowPID,
                      try window.frame() == stagedWindowFrame,
                      try field.pid() == stagedWindowPID,
                      try field.role() == AXRole.textField,
                      try field.frame() == stagedFieldFrame,
                      try field.isSettable(AXAttribute.value),
                      try field.valueString() == name else { return false }
                let fresh = try WeComReader(window: window)
                let rows = try fresh.conversations()
                let selected = rows.filter(\.selected)
                let header = try fresh.activeConversationHeader()
                return selected.count == 1 && selected[0].handle == originalRowHandle
                    && selected[0].title == name && rows.filter { $0.title == name }.count == 1
                    && fresh.layout.activeTitle?.handle == field.handle
                    && header?.title == name
            }
            guard try matches(), try appliedGate(error) else { return false }
            return try matches()
        }
        // AXValue is reversible only while the original group row, window and
        // editor still prove ownership. A rejected model round must not leave
        // a pending title that a later blur could commit behind a failed result.
        func restoreStagedNameIfOwned() -> Bool {
            do {
                guard let stagedWindowFrame, let stagedFieldFrame,
                      try window.pid() == stagedWindowPID,
                      try window.frame() == stagedWindowFrame,
                      try field.pid() == stagedWindowPID,
                      try field.frame() == stagedFieldFrame,
                      try field.role() == AXRole.textField,
                      try field.isSettable(AXAttribute.value) else { return false }
                let fresh = try WeComReader(window: window)
                let selected = try fresh.conversations().filter(\.selected)
                guard selected.count == 1, selected[0].title == oldTitle,
                      selected[0].handle == originalRowHandle,
                      fresh.layout.activeTitle?.handle == field.handle else { return false }
                let current = try field.valueString()
                guard current == name || current == originalFieldValue else { return false }
                if current == name {
                    try field.setAttribute(AXAttribute.value, to: .string(originalFieldValue))
                }
                let after = try WeComReader(window: window)
                let afterSelected = try after.conversations().filter(\.selected)
                let restoredValue = try field.valueString()
                return afterSelected.count == 1 && afterSelected[0].title == oldTitle
                    && afterSelected[0].handle == originalRowHandle
                    && after.layout.activeTitle?.handle == field.handle
                    && restoredValue == originalFieldValue
            } catch {
                return false
            }
        }
        func prepareName() throws -> Bool {
            // A rename value write can itself take effect. Persist uncertainty
            // before it and recheck ownership after the checkpoint callback.
            if actionKind == .renameGroup {
                try checkpointOnce()
                try visualActionGate?(actionKind, gateTitle)
                try validateField(value: originalFieldValue, header: before)
            }
            try field.setAttribute(AXAttribute.value, to: .string(name))
            if try appliedNameIsOwned() { return true }
            // AXValue can silently fail to stick while the edit field remains
            // focused. Re-observe the same field and original selected row; at most
            // one identical write is allowed while original ownership still holds.
            // Unknown values or a changed target fail closed. AXConfirm is never
            // used as a repair, because it may already have renamed the group.
            func stagedNameIsReadable() throws -> Bool {
                try visualActionGate?(actionKind, gateTitle)
                guard let current = try field.valueString() else { throw ActionError.actionUnavailable("群名输入框") }
                if current == name {
                    try validateField(value: name, header: nil)
                    return true
                }
                guard current == originalFieldValue else { throw ActionError.actionUnavailable("群名输入框") }
                try validateField(value: originalFieldValue, header: nil)
                return false
            }
            if try !stagedNameIsReadable() {
                if (try? field.isSettable(AXAttribute.focused)) == true {
                    try? field.setAttribute(AXAttribute.focused, to: .bool(true))
                }
                try visualActionGate?(actionKind, gateTitle)
                if actionKind == .renameGroup { try visualGroupNameStagingGate?() }
                try validateField(value: originalFieldValue, header: nil)
                try field.setAttribute(AXAttribute.value, to: .string(name))
                if try appliedNameIsOwned() { return true }
                guard try stagedNameIsReadable() else { throw ActionError.actionUnavailable("群名输入框") }
            }
            if actionKind == .renameGroup {
                try visualObserveGroupName?(WeComReader(window: window), field, .afterStaging, {
                    try validateField(value: name, header: nil)
                    return true
                })
                try visualGroupNameCommitGate?()
            }
            try visualActionGate?(actionKind, gateTitle)
            try validateField(value: name, header: nil)
            return false
        }
        let appliedDuringPreparation: Bool
        do {
            appliedDuringPreparation = try prepareName()
        } catch {
            if (try? appliedNameIsOwned(after: error)) == true {
                appliedDuringPreparation = true
            } else {
                if actionKind == .renameGroup, !restoreStagedNameIfOwned() {
                    // The write may have taken effect or may still commit on blur.
                    // Persist uncertainty before propagating the failure.
                    try checkpointOnce()
                    throw ActionError.verifyFailed("群名草稿未能安全恢复，结果待核对")
                }
                throw error
            }
        }
        if appliedDuringPreparation {
            guard try appliedNameIsOwned() else {
                throw ActionError.verifyFailed("群名变更后的原会话证据已变化")
            }
            // Outside the preparation catch: crash injection must propagate
            // unchanged, and an applied name must never be confirmed twice.
            try hooks.afterIrreversible()
            return ActionOutcome(kind: actionKind.rawValue, target: before, verified: true,
                                 details: ["renamed": "true", "title": name, "requestedName": name,
                                           "headerShowsName": "true"])
        }
        // Group creation retains its checkpoint immediately before confirm.
        try checkpointOnce()
        do {
            if actionKind == .renameGroup { try visualGroupNameCommitGate?() }
            try visualActionGate?(actionKind, gateTitle)
            try validateField(value: name, header: nil)
            try field.perform(AXAction.confirm)
        } catch {
            if actionKind == .renameGroup { _ = restoreStagedNameIfOwned() }
            throw error
        }
        try hooks.afterIrreversible()
        let started = Date()
        let requireSelectedRow = actionKind == .renameGroup
        var listed = try waitForListTitle(name, window: window, deadline: started.addingTimeInterval(groupOpenTimeout / 2),
                                          requireSelectedRow: requireSelectedRow)
        var how = "confirm"
        if !listed {
            // Ending the edit session is what some fields commit on; the conversation table is a harmless focus target.
            if let table = try? WeComLayout.locate(in: window).conversationTable, (try? table.isSettable(AXAttribute.focused)) == true {
                try? table.setAttribute(AXAttribute.focused, to: .bool(true))
            }
            listed = try waitForListTitle(name, window: window, deadline: started.addingTimeInterval(groupOpenTimeout),
                                          requireSelectedRow: requireSelectedRow)
            how = "confirm+blur"
        }
        let header = try? WeComReader(window: window).activeConversationHeader()?.raw
        trace?("group: rename \(listed ? "applied" : "not applied") via \(how) after \(Int(Date().timeIntervalSince(started) * 1000))ms header=\(header == name ? "new" : "old")")
        return ActionOutcome(kind: actionKind.rawValue, target: before, verified: listed,
                             details: ["renamed": listed ? "true" : "false", "title": listed ? name : (header ?? ""), "requestedName": name,
                                       "headerShowsName": header == name ? "true" : "false"])
    }

    /// True once the selected conversation row is titled `name`. Group creation
    /// also accepts an exact title when the new row has not acquired selection;
    /// a rename cannot use that fallback because another row may have the name.
    func waitForListTitle(_ name: String, window: AXElement, deadline: Date,
                          requireSelectedRow: Bool = false) throws -> Bool {
        while true {
            if let rows = try? WeComReader(window: window).conversations() {
                let selected = rows.filter(\.selected)
                if requireSelectedRow {
                    if selected.count == 1 && selected[0].title == name { return true }
                } else if rows.contains(where: { $0.title == name && ($0.selected || selected.isEmpty) }) {
                    return true
                }
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: verifyInterval)
        }
    }
}

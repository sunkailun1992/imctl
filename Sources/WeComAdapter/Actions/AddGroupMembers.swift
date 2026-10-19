import AXKit
import CoreGraphics
import ControlCore
import Foundation

/// The result of one 添加群成员 attempt. `state` follows the `submit` rules: `succeeded` only with
/// evidence (the member count grew by exactly the number added, or the client wrote a NEW 邀请 system
/// row naming all of them), `unknown` when the sheet closed but nothing could be observed — a
/// legitimate "we may have added them", never retried, and also what a 确定 press that threw resolves
/// to — and `failed` only while the sheet is still open, i.e. nothing was added. `before` / `after`
/// are nil when the client showed no count to read; `skipped` carries the members the sheet refused
/// (`alreadyMember`) or could not resolve (`notFound` / `ambiguous`), which is why re-running the
/// same call is safe.
public struct AddMembersOutcome {
    public var state: CommandState
    public var before: Int?
    public var after: Int?
    public var added: [String]
    public var skipped: [(name: String, reason: String)]
    public var evidence: String
    public var details: [String: String]
}

/// B14 `group.addMembers` (live 2026-09-23, WeCom 5.0.11): open the group's own 添加群成员 sheet from
/// the header, pick the members with the sheet loop `createGroup` already uses, then 确定. The 确定
/// press is the irreversible point — a checkpoint is on disk before it, exactly like `submit` — and
/// `dryRun` stops one step earlier, at 取消.
public extension WeComActions {
    /// `SubmitCheckpoint.strategy` for this flow (the checkpoint record has no separate kind field).
    static let addMembersStrategy = "addGroupMembers"

    /// The buttons in the group header's own band (live 2026-09-23, 5.0.11): untitled,
    /// description-less 30×30 `AXButton`s that are siblings of the title inside the same split group
    /// — x 1839 and 1879 in a 1920-wide window, on the title's own y. Geometry alone does not pick
    /// them out: the client's `_NS:*` identifiers are nib-generated, so the only other thing to go on
    /// is that neither carries a title or description. Newer AX snapshots can expose an exact
    /// `AXHelp` / `AXValue` name for 添加群成员; the action checks that before any visual fallback.
    /// A button in that band that *does* carry an `AXTitle` or
    /// an `AXDescription` is a different control this flow knows nothing about — pressing one blindly
    /// would open a panel it would then have to cancel. Returned right to left, because the rightmost
    /// unlabelled one is the one that opened 添加群成员 in the recording; the other was never pressed
    /// and its purpose is unknown. Empty for a conversation whose header has no such buttons.
    static func headerButtons(layout: WeComLayout) throws -> [AXElement] {
        guard let title = layout.activeTitle, let band = try title.frame() else { throw WeComError.region("groupTitle") }
        let siblings = (try? title.parent()?.children()) ?? []
        return siblings.filter { element in
            guard (try? element.role()) == AXRole.button, let frame = (try? element.frame()) ?? nil else { return false }
            guard ((try? element.title()) ?? nil)?.isEmpty ?? true,
                  ((try? element.axDescription()) ?? nil)?.isEmpty ?? true else { return false }
            return frame.height >= 24 && frame.height <= 36 && abs(frame.minY - band.minY) <= 12
        }.sorted { minX($0) > minX($1) }
    }

    private static func minX(_ element: AXElement) -> CGFloat { ((try? element.frame()) ?? nil)?.minX ?? 0 }

    /// Right-side title-bar AX buttons only: the right half of the header span
    /// between the conversation list and the window's right edge, measured
    /// live instead of the 320 pt band recorded in a 1920 pt window (buttons
    /// at x 1839 / 1879, 2026-09-23). A changing help/value that names an
    /// irreversible control is excluded before it can become a model box.
    static func addMembersHeaderCandidates(layout: WeComLayout) throws -> [AXElement] {
        let rightBandStart = (layout.conversationTableFrame.maxX + layout.windowFrame.maxX) / 2
        return try headerButtons(layout: layout).filter { button in
            guard let frame = (try? button.frame()) ?? nil,
                  frame.minX >= rightBandStart,
                  (try? button.role()) == AXRole.button,
                  (try? button.actions().contains(AXAction.press)) == true,
                  (try? button.isEnabled()) != false else { return false }
            let labels = [
                (try? button.title()) ?? nil,
                (try? button.axDescription()) ?? nil,
                (try? button.string(AXAttribute.help)) ?? nil,
                (try? button.valueString()) ?? nil,
            ].compactMap { $0 }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return !labels.contains { label in
                ["完成", "确定", "发送", "done", "confirm", "send"].contains { label.contains($0) }
            }
        }
    }

    /// The side panel's member heading, recorded as `群成员·12` (2026-09-23). A couple of look-alike
    /// separators are accepted so a font or locale variant does not silently drop the count.
    static let memberCountPattern = try? NSRegularExpression(pattern: "群成员[·・•]?\\s*([0-9]+)")

    /// How many members the client says this conversation has: the header's own "(N)" suffix when it
    /// carries one, else the side panel's `群成员·N` heading — the user's test group shows no suffix
    /// and only the panel counts (live 2026-09-23). nil means neither is readable, which is how
    /// `addGroupMembers` tells a group from a one-to-one chat (`NOT_A_GROUP`).
    ///
    /// The panel is the split pane right of the chat (5.0.11, recorded 2026-09-15: message viewport
    /// x 411–1759, member table from x 1760), so only static texts that *start* at or right of the
    /// live message viewport's right edge are read as the count. The same words anywhere else — an
    /// external group's banner under the header title, a message quoting the panel, a conversation
    /// preview — cannot stand in for the client's own number. This replaces a 240 pt band at the
    /// window's right edge recorded in one 1920 pt window; without a viewport nothing is read.
    static func memberCount(reader: WeComReader) -> Int? {
        if let count = (try? reader.activeConversationHeader())?.memberCount { return count }
        guard let pattern = memberCountPattern, let viewport = reader.layout.messageViewportFrame() else { return nil }
        let panelLeft = viewport.maxX - 2
        for element in reader.layout.window.descendants() where (try? element.role()) == AXRole.staticText {
            guard let frame = (try? element.frame()) ?? nil, frame.minX >= panelLeft,
                  frame.maxX <= reader.layout.windowFrame.maxX + 2,
                  let text = (try? element.valueString()) ?? nil, !text.isEmpty,
                  let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let digits = Range(match.range(at: 1), in: text), let count = Int(text[digits]) else { continue }
            return count
        }
        return nil
    }

    /// Brings up a new 添加群成员 sheet (live 2026-09-23, 5.0.11). Any pre-existing picker belongs
    /// to another operation, even when it is empty and has the right title: reject without touching
    /// it. The header buttons are tried right to left only while no sheet is present. A button that
    /// leaves a different or preselected sheet stops the attempt without cancelling that panel or
    /// pressing another button; AX cannot prove that the panel belongs to this command.
    func openAddMembersSheet(window: AXElement, reader: WeComReader, expectedTitle: String? = nil,
                             expectedMemberCount: Int? = nil) throws -> GroupPickerSheet {
        // This method is also used by the diagnostic probe. Its own gate prevents a future caller
        // from reaching either a header press or a cloud screenshot without action authorization.
        guard let activeTitle = try reader.activeConversationTitle(), !activeTitle.isEmpty else {
            throw ActionError.actionUnavailable("添加群成员")
        }
        guard expectedTitle == nil || activeTitle == expectedTitle else {
            throw ActionError.targetMismatch(expected: expectedTitle ?? "", actual: activeTitle)
        }
        try authorize(.addGroupMembers, title: activeTitle)
        // This check precedes both the visual and deterministic entry paths. In particular, an
        // empty pre-existing 添加群成员 sheet is never silently adopted as this command's own.
        guard try window.children().allSatisfy({ try $0.role() != AXRole.sheet }) else {
            throw ActionError.actionUnavailable("添加群成员：已有弹窗")
        }
        if let visualOpenAddMembersRounds {
            // A direct external command with full-window planning must use the
            // same model/AX postcondition path even when AXHelp names one
            // button. Never inherit or cancel somebody else's open picker.
            guard let count = expectedMemberCount else {
                throw ActionError.actionUnavailable("添加群成员")
            }
            return try visualOpenAddMembersRounds(reader, activeTitle, count)
        }
        let visibleHeaderButtons = try Self.headerButtons(layout: reader.layout)
        // Only controls in the right-side title bar may be offered to cloud vision. The title's
        // sibling list also contains an unrelated left-side control, which must never enter a crop.
        let visualCandidates = try Self.addMembersHeaderCandidates(layout: reader.layout)
        let semanticallyNamed = visualCandidates.filter { button in
            let help = (try? button.string(AXAttribute.help)) ?? ""
            let value = (try? button.valueString()) ?? ""
            return [help, value].contains { $0 == "添加群成员" || $0 == "Add Group Members" }
        }
        let candidates = selectAddMembersHeaderButton == nil
            ? Array(visibleHeaderButtons.prefix(2)) : Array(visualCandidates.prefix(8))
        let buttons: [AXElement]
        var selectedByFullWindow = false
        if semanticallyNamed.count == 1 {
            trace?("addMembers: exact AX control name matched")
            buttons = [semanticallyNamed[0]]
        } else if visualSelect != nil {
            // The cloud selector may only resolve the already-authorized group-header step. It
            // cannot pick a control elsewhere in the window or bypass the sheet postcondition.
            // A configured selector that cannot make a fresh, valid choice stops here instead
            // of falling through to the historical right-to-left trial presses.
            let eligible = semanticallyNamed.count > 1 ? semanticallyNamed : visualCandidates
            let selected = try visualChoice(window: window, goal: .control(.addGroupMembers), kind: .press,
                                            actionKind: .addGroupMembers,
                                            expectedTitle: activeTitle, eligible: eligible, purpose: "添加群成员")
            guard let freshFrame = try window.frame(),
                  abs(freshFrame.minX - reader.layout.windowFrame.minX) <= 2,
                  abs(freshFrame.minY - reader.layout.windowFrame.minY) <= 2,
                  abs(freshFrame.width - reader.layout.windowFrame.width) <= 2,
                  abs(freshFrame.height - reader.layout.windowFrame.height) <= 2,
                  let freshLayout = try? WeComLayout.locate(in: window),
                  try Self.headerButtons(layout: freshLayout).contains(where: { $0.handle == selected.handle }) else {
                throw ActionError.actionUnavailable("添加群成员")
            }
            buttons = [selected]
            selectedByFullWindow = true
        } else if candidates.count > 1, let selectAddMembersHeaderButton {
            let framesBefore = try candidates.map { try $0.frame() }
            let pidBefore = try window.pid()
            let selected: AXElement?
            do { selected = try selectAddMembersHeaderButton(reader, candidates, activeTitle) }
            catch {
                if let visualError = error as? CloudVisionError {
                    trace?("addMembers: visual selection stopped: \(visualError)")
                } else {
                    trace?("addMembers: visual selection stopped before AX press")
                }
                throw ActionError.actionUnavailable("添加群成员")
            }
            guard let selected else {
                trace?("addMembers: visual selection returned no confident candidate")
                throw ActionError.actionUnavailable("添加群成员")
            }
            guard let selectedIndex = candidates.firstIndex(where: { $0.handle == selected.handle }),
                  try WeComReader(window: window).activeConversationTitle() == activeTitle,
                  try window.pid() == pidBefore,
                  let freshFrame = try window.frame(),
                  abs(freshFrame.minX - reader.layout.windowFrame.minX) <= 2,
                  abs(freshFrame.minY - reader.layout.windowFrame.minY) <= 2,
                  abs(freshFrame.width - reader.layout.windowFrame.width) <= 2,
                  abs(freshFrame.height - reader.layout.windowFrame.height) <= 2,
                  let freshLayout = try? WeComLayout.locate(in: window),
                  let originalFrame = framesBefore[selectedIndex],
                  let matched = try Self.headerButtons(layout: freshLayout).first(where: { $0.handle == selected.handle }),
                  let currentFrame = try matched.frame(),
                  abs(currentFrame.minX - originalFrame.minX) <= 2,
                  abs(currentFrame.minY - originalFrame.minY) <= 2,
                  abs(currentFrame.width - originalFrame.width) <= 2,
                  abs(currentFrame.height - originalFrame.height) <= 2,
                  try selected.actions().contains(AXAction.press) else {
                trace?("addMembers: visual choice failed AX revalidation")
                throw ActionError.actionUnavailable("添加群成员")
            }
            buttons = [selected]
        } else {
            buttons = candidates
        }
        let originalPID = try window.pid()
        let originalFrame = reader.layout.windowFrame
        for button in buttons {
            try authorize(.addGroupMembers, title: activeTitle)
            try visualActionGate?(.addGroupMembers, activeTitle)
            let fresh = try WeComReader(window: window)
            let freshButtons = try (selectedByFullWindow || semanticallyNamed.count == 1)
                ? Self.addMembersHeaderCandidates(layout: fresh.layout)
                : Self.headerButtons(layout: fresh.layout)
            guard try window.pid() == originalPID,
                  let frame = try window.frame(),
                  abs(frame.minX - originalFrame.minX) <= 2,
                  abs(frame.minY - originalFrame.minY) <= 2,
                  abs(frame.width - originalFrame.width) <= 2,
                  abs(frame.height - originalFrame.height) <= 2,
                  try fresh.activeConversationTitle() == activeTitle,
                  expectedMemberCount == nil || Self.memberCount(reader: fresh) == expectedMemberCount,
                  try window.children().allSatisfy({ try $0.role() != AXRole.sheet }),
                  let current = freshButtons.first(where: { $0.handle == button.handle }),
                  try current.role() == AXRole.button,
                  try current.actions().contains(AXAction.press),
                  (try current.isEnabled()) != false else {
                throw ActionError.actionUnavailable("添加群成员")
            }
            try current.perform(AXAction.press)
            var opened: GroupPickerSheet?
            let shown = try waitUntil(timeout: addMembersTimeout) {
                opened = try? GroupPickerSheet.locate(window: window)   // the title pane lags the outline by a beat
                return opened?.isAddMembers == true
            }
            if shown, let opened {
                guard try window.children().filter({ try $0.role() == AXRole.sheet }).map(\.handle) == [opened.sheet.handle],
                      opened.selectedTable != nil, (try? opened.selectedCount()) == 0 else {
                    throw ActionError.actionUnavailable("添加群成员")
                }
                return opened
            }
            // A foreign or populated panel may have appeared while the button was in flight.
            // Its handle alone cannot prove causality, so leave it intact for the user.
            if try window.children().contains(where: { try $0.role() == AXRole.sheet }) {
                throw ActionError.actionUnavailable("添加群成员")
            }
        }
        throw ActionError.actionUnavailable("添加群成员")
    }

    /// Adds `members` to the already-open, policy-allowed group `target`.
    ///
    /// Order, and why: authorize → read the member count (`NOT_A_GROUP` when there is none, before
    /// anything is pressed) → open the sheet → pick the members (a row the client marks as already
    /// in the group is skipped, never re-selected, so a retry with a fresh idempotency key adds
    /// nobody twice) → nothing to add, or `dryRun`: press 取消 and stop → checkpoint → 确定 →
    /// evidence. The checkpoint is written *before* the press: a crash in between leaves a pending
    /// record that resolves to `unknown`, which is never re-run.
    ///
    /// The only synthetic key in this path is the pid-level Return `pickMembers` posts on the
    /// sheet's search field — the one the user approved for the 发起群聊 picker; every other step is
    /// an AX action or attribute.
    ///
    /// - Parameter dryRun: select the members, then press 取消 instead of 确定. `added` is then what
    ///   *would* have been added, and the group is untouched.
    /// - Returns: `succeeded` with `count N→M` / `row #i 邀请` / `dry-run` / `nothing-to-add`,
    ///   `unknown` with `no-evidence` (or `confirm-threw`, when the press itself did not return),
    ///   or `failed` with `sheet-still-open`.
    /// - Throws: `PolicyError` (phase / enabled / target), `ActionError.notAGroup`,
    ///   `ActionError.actionUnavailable`, and whatever `pickMembers` raises. A changed or foreign
    ///   sheet is left intact; after a checkpoint, a thrown refusal resolves to `unknown` upstream.
    func addGroupMembers(_ members: [String], target: ResolvedTarget, dryRun: Bool, app: AXElement, window: AXElement,
                         reader: WeComReader, checkpoints: CheckpointStore, hooks: SubmitHooks = SubmitHooks()) throws -> AddMembersOutcome {
        try policy.authorize(.addGroupMembers, resolved: target)
        let before = Self.memberCount(reader: reader)
        guard before != nil else { throw ActionError.notAGroup(target.title) }
        let pid = try app.pid()
        let sheet = try openAddMembersSheet(window: window, reader: reader,
                                             expectedTitle: target.title, expectedMemberCount: before)
        let windowPID = try window.pid()
        let windowFrame = try window.frame()
        var selectedRowHandles: [AXElementHandle]?

        // Cancellation and confirmation are allowed only for the newly opened sheet with the exact
        // requested selected-member identities. A replaced sheet or a user-edited selection is not
        // ours to dismiss, even when it has the same title.
        func currentOwnedSheet(selected names: [String]) throws -> GroupPickerSheet {
            try policy.authorize(.addGroupMembers, resolved: target)
            try addMembersCommitGate?()
            let live = try WeComReader(window: window)
            let liveCount = Self.memberCount(reader: live)
            guard pid == windowPID, windowPID > 0,
                  try window.pid() == windowPID,
                  let frame = try window.frame(), let windowFrame,
                  abs(frame.minX - windowFrame.minX) <= 2,
                  abs(frame.minY - windowFrame.minY) <= 2,
                  abs(frame.width - windowFrame.width) <= 2,
                  abs(frame.height - windowFrame.height) <= 2,
                  try live.activeConversationTitle() == target.title,
                  try window.children().filter({ try $0.role() == AXRole.sheet }).map(\.handle) == [sheet.sheet.handle],
                  let current = try GroupPickerSheet.locate(window: window),
                  current.sheet.handle == sheet.sheet.handle,
                  current.isAddMembers,
                  current.outline.handle == sheet.outline.handle,
                  current.searchField?.handle == sheet.searchField?.handle,
                  current.selectedTable?.handle == sheet.selectedTable?.handle,
                  try current.selectedMemberNames() == names,
                  liveCount == before || liveCount == nil else {
                throw ActionError.actionUnavailable("添加群成员：面板或已选成员已变化")
            }
            let rowHandles = try current.selectedTable?.children()
                .filter { try $0.role() == AXRole.row }.map(\.handle) ?? []
            guard selectedRowHandles == nil || rowHandles == selectedRowHandles else {
                throw ActionError.actionUnavailable("添加群成员：已选成员句柄已变化")
            }
            return current
        }

        func closeOwnedSheet(selected names: [String]) throws {
            let current = try currentOwnedSheet(selected: names)
            try closeGroupPicker(current, window: window)
        }

        let picked: (added: [String], skipped: [(name: String, reason: String)], refronts: Int)
        do {
            picked = try pickMembers(members, in: sheet, app: app, pid: pid, skipDisabled: true)
        } catch {
            // A failed picker may have a partial or externally changed selection. Only an empty
            // command-owned sheet can be cleaned without guessing who chose its rows.
            try? closeOwnedSheet(selected: [])
            throw error
        }
        var details = ["dryRun": dryRun ? "true" : "false", "refronts": String(picked.refronts),
                       "requested": String(members.count), "skipped": String(picked.skipped.count)]
        trace?("addMembers: picked \(picked.added.count)/\(members.count) skipped=\(picked.skipped.map(\.reason).joined(separator: ","))")
        let selectedSheet = try currentOwnedSheet(selected: picked.added)
        selectedRowHandles = try selectedSheet.selectedTable?.children()
            .filter { try $0.role() == AXRole.row }.map(\.handle) ?? []

        // Reversible end: nothing to add, or the caller only wanted to see who would be added.
        if picked.added.isEmpty || dryRun {
            try closeOwnedSheet(selected: picked.added)
            return AddMembersOutcome(state: .succeeded, before: before, after: nil, added: picked.added,
                                     skipped: picked.skipped, evidence: picked.added.isEmpty ? "nothing-to-add" : "dry-run",
                                     details: details)
        }

        guard let done = sheet.doneButton, (try done.isEnabled()) == true else {
            try? closeOwnedSheet(selected: picked.added)
            throw ActionError.actionUnavailable("确定")
        }
        // Baseline for the 邀请 evidence — `submit`'s rule applied to system rows: only a row that was
        // NOT on screen before the press can prove this add. A group's history may well already hold
        // "你邀请…加入了外部群聊" naming exactly these people (they were added, removed, and are being
        // added again), and that row would otherwise vouch for a 确定 that silently did nothing.
        let rowsBefore = Set(((try? reader.messages()) ?? []).map { "\($0.index):\($0.text ?? "")" })

        var checkpoint = SubmitCheckpoint(target: target.title, text: picked.added.joined(separator: ","), strategy: Self.addMembersStrategy)
        _ = try currentOwnedSheet(selected: picked.added)  // immediately before the checkpoint
        do {
            try checkpoints.write(checkpoint)
            details["checkpointID"] = checkpoint.id
            try hooks.beforeIrreversible()
            let current = try currentOwnedSheet(selected: picked.added)
            guard let liveDone = current.doneButton,
                  liveDone.handle == done.handle,
                  try liveDone.role() == AXRole.button,
                  try liveDone.title() == "确定",
                  try liveDone.actions().contains(AXAction.press),
                  try liveDone.isEnabled() == true else {
                throw ActionError.actionUnavailable("确定")
            }
        } catch {
            // The executor's checkpoint callback may already have persisted its irreversible marker.
            // Let the error propagate: CommandExecutor reads that marker and returns `unknown`,
            // without a group.membersAdded event or a second 确定 attempt.
            try? closeOwnedSheet(selected: picked.added)
            throw error
        }
        let started = Date()

        // ---- irreversible point ----
        // Keep refusal outside the AXPress catch: a denied gate must never be mistaken for a
        // dispatched press. The checkpoint remains pending and CommandExecutor returns unknown.
        let currentBeforePress = try currentOwnedSheet(selected: picked.added)
        guard let liveDone = currentBeforePress.doneButton,
              liveDone.handle == done.handle,
              try liveDone.role() == AXRole.button,
              try liveDone.title() == "确定",
              try liveDone.actions().contains(AXAction.press),
              try liveDone.isEnabled() == true else {
            throw ActionError.actionUnavailable("确定")
        }
        var confirmThrew = false
        do {
            try liveDone.perform(AXAction.press)
        } catch {
            // A throwing AXPress does NOT mean the client ignored the press: `kAXErrorCannotComplete`
            // is "the app did not answer in time", and the press may well have been dispatched. The
            // executor turns a throw into `failed`, so rethrowing here would claim "nothing was added"
            // about an add that may have gone through — only a returned `.unknown` survives as such.
            // So the press counts as made and the usual closed / evidence logic below decides.
            confirmThrew = true
            details["confirmThrew"] = "true"
            trace?("addMembers: 确定 press threw; treated as pressed")
        }

        try hooks.afterIrreversible()
        // How long the sheet may take to go away after 确定 (2026-09-23): adding members is a server
        // round trip, not a local repaint, so the general `verifyTimeout` (1.5 s in production) is the
        // wrong clock — a slow round trip would read as "确定 did not take" and be reported `failed`,
        // i.e. "nothing was added", about an add that went through. `addMembersTimeout` (3 s) is the
        // same budget this flow already gives the sheet to open. TO CALIBRATE: the live gate must
        // record the close latency actually observed, so this number comes from the client rather
        // than from reasoning about it.
        let closed = try waitUntil(timeout: addMembersTimeout) { (try? GroupPickerSheet.locate(window: window)) == nil }
        details["closed"] = closed ? "true" : "false"
        if !closed {
            // 确定 did not take: the sheet is still up, so nothing was added. Close it so the client
            // is not left with a half-filled panel, and report `failed` — safe to run again.
            try? closeGroupPicker(sheet, window: window)
            checkpoint.state = .failed
            checkpoint.reason = "sheet-still-open"
            try? checkpoints.write(checkpoint)
            trace?("addMembers: 确定 pressed but the sheet stayed open")
            return AddMembersOutcome(state: .failed, before: before, after: nil, added: picked.added,
                                     skipped: picked.skipped, evidence: "sheet-still-open", details: details)
        }

        // Evidence, re-reading the window each poll because the client rebuilds it while the sheet
        // tears down: the count grew by exactly what we added, or the client wrote a new 邀请 system
        // row naming every one of them. Either is proof; anything else is `unknown`.
        var after: Int?
        var evidence: String?
        let deadline = started.addingTimeInterval(groupOpenTimeout)
        while true {
            let fresh = try? WeComReader(window: window)
            // Keep the last count the client actually showed: a poll landing mid-rebuild reads
            // nothing, and that is not "this group has no count" — overwriting would lose the number.
            if let count = fresh.flatMap({ Self.memberCount(reader: $0) }) { after = count }
            if let before, let after, after == before + picked.added.count {
                evidence = "count \(before)→\(after)"
            } else if let row = fresh.flatMap({ Self.invitationRow(reader: $0, added: picked.added, before: rowsBefore) }) {
                evidence = "row #\(row) 邀请"
            }
            if evidence != nil || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: verifyInterval)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        details["latencyMs"] = String(latency)
        trace?("addMembers: added \(picked.added.count) count=\(before.map(String.init) ?? "-")→\(after.map(String.init) ?? "-") evidence=\(evidence != nil) after \(latency)ms")
        checkpoint.state = evidence != nil ? .succeeded : .unknown
        checkpoint.evidence = evidence
        checkpoint.reason = evidence != nil ? nil
            : (confirmThrew ? "the 确定 press did not return and neither the member count nor a new 邀请 row confirmed the add"
                            : "the sheet closed but neither the member count nor a new 邀请 row confirmed the add")
        // Best effort past the irreversible point: a store that cannot record the verdict must not
        // turn an add that may have happened into a thrown error (which the executor would report as
        // `failed`). The pending record written before 确定 is already on disk, so a restart still
        // resolves this to `unknown`.
        try? checkpoints.write(checkpoint)
        return AddMembersOutcome(state: checkpoint.state, before: before, after: after, added: picked.added,
                                 skipped: picked.skipped,
                                 evidence: evidence ?? (confirmThrew ? "confirm-threw" : "no-evidence"), details: details)
    }

    /// Index of the client's own invitation notice for this add — "你邀请来自微信的 A、B 加入了外部群聊"
    /// (live 2026-09-15 history, read again 2026-09-23). Two guards, both load-bearing: every added
    /// member must be named, so somebody else's invitation is not mistaken for proof, and the row must
    /// be one that was not there before 确定 — `before` holds the `index:text` of every row visible at
    /// that moment, so an invitation left in the history by an earlier add cannot vouch for a press
    /// that did nothing. Any row kind: the client draws it as a centered system notice.
    private static func invitationRow(reader: WeComReader, added: [String], before: Set<String>) -> Int? {
        guard let rows = try? reader.messages() else { return nil }
        return rows.last { row in
            guard let text = row.text, text.contains("邀请"), !before.contains("\(row.index):\(text)") else { return false }
            return added.allSatisfy { text.contains($0) }
        }?.index
    }
}

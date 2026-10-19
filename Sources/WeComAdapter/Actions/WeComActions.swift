import AppKit
import AXKit
import ControlCore
import Foundation

/// A passive model observation around the command-owned composer staging.
public enum ComposerVisualStage: Equatable {
    case beforeStaging
    case afterStaging
}

/// Passive visual observation around the fixed group-name AX write.
public enum GroupNameVisualStage: Equatable {
    case beforeStaging
    case afterStaging
}

/// Passive observations around this command's own Start Group Chat sheet.
/// The model cannot choose members, press Done, or declare a group created.
public enum GroupCreateVisualStage: Equatable {
    case beforeCompletion
    case afterCompletion
}

/// A passive observation around the fixed Window-menu navigation. The menu
/// itself is outside the approved WeCom main-window capture and stays AX-owned.
public enum NavigationVisualStage: Equatable {
    case beforeMenu
    case afterMenu
}

/// Passive observations before the two fixed accept-request AX presses.
/// The second stage exists only for a new, command-owned remark popover.
public enum ContactAcceptVisualStage: Equatable {
    case beforeAccept
    case beforeDone
}

/// Passive checks of a command-owned Add Customer window. The requested
/// phone, source, greeting and all AX writes remain fixed by `contact.add`.
public enum ContactAddVisualStage: Equatable {
    case searchInput
    case sourceMatch
    case inviteConfirm
}

/// The broadcast task has already been identified by exact msgid and a
/// globally unique AX Send button. A second observation is possible only
/// while that same button remains visible after the fixed press.
public enum BroadcastConfirmVisualStage: Equatable {
    case beforePress
    case afterPress
}

/// The phase-0 action set. Every step is set → read back → compare; nothing
/// is retried, and nothing runs before `ActionPolicy.authorize` passes.
public struct WeComActions {
    public var policy: ActionPolicy
    /// The target this action set operates on, already judged by the policy
    /// with the identity bridge and the conversation kind. Actions on that
    /// title reuse it; any other title is judged as a bare title.
    public var resolvedTarget: ResolvedTarget?
    /// How long to keep re-reading the client before declaring verification failed.
    public var verifyTimeout: TimeInterval
    /// How long an accepted request may take to show as 打招呼 after 完成 (a server round trip; live 2026-09-15 it outlasted the 1.5 s verify window).
    public var acceptTimeout: TimeInterval = 10
    /// How long the client may take to open a newly created group after 完成 (asynchronous; live 2026-09-15 it took 4 s).
    public var groupOpenTimeout: TimeInterval = 10
    /// How long a header button may take to bring up a sheet before the next one is tried (B14; the
    /// 添加群成员 sheet appeared at once in the 2026-09-23 recording). `groupOpenTimeout` is reused
    /// for the evidence that follows 确定.
    public var addMembersTimeout: TimeInterval = 3
    public var verifyInterval: TimeInterval
    /// Delivers one Return key to a pid (control modifier when true). Replaced in tests.
    public var postReturnKey: (pid_t, Bool) throws -> Void = { pid, control in
        try KeystrokeInjector.postReturn(toPid: pid, control: control)
    }
    /// The app that had focus before an action must make the client frontmost;
    /// nil = unknown, nothing to give back. Replaced in tests.
    public var frontmostPid: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// Gives focus back through the same AX attribute (`AXFrontmost`); failures
    /// are ignored — the navigation itself already happened. Replaced in tests.
    public var restoreFrontmost: (pid_t) -> Void = { pid in
        try? AXApp.byPID(pid, backend: LiveAXBackend()).setAttribute(AXAttribute.frontmost, to: .bool(true))
    }
    /// The approved tab shortcuts, delivered to the client's pid only. Replaced in tests.
    public var postShortcut: (KeystrokeInjector.Shortcut, pid_t) throws -> Void = { try KeystrokeInjector.postShortcut($0, toPid: $1) }
    /// B13: the clipboard used to paste a fetched file (`message.sendFile`); snapshot → file URL → ⌘V → restore. Replaced in tests.
    public var pasteboard: PasteboardHandling = GeneralPasteboard()
    /// How long the pasted attachment may take to show up in the composer before the attempt is abandoned without a Return.
    public var pasteTimeout: TimeInterval = 3
    /// Deep links (`wxwork://…`) are opened through the workspace, never typed. Replaced in tests.
    public var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// The client's window numbers (no titles, no pixels), read before and after a press
    /// that opens a same-frame window of the client (B49). Replaced in tests.
    public var windowIdentities: (pid_t) -> [WeComWindowIdentity] = { WeComWindowIdentity.list(pid: $0) }
    /// Step-by-step diagnostics of the navigation actions (roles, counts, timings — never content); nil = silent.
    public var trace: ((String) -> Void)?
    /// Optional visual disambiguation for multiple untitled group-header buttons. The daemon installs
    /// this only when cloud vision is enabled. It receives AX candidates, and must return one of
    /// their handles; a nil or stale choice stops before any header press. Ordinary reads never use it.
    public var selectAddMembersHeaderButton: ((WeComReader, [AXElement], String) throws -> AXElement?)?
    /// B17: a fixed desktop command may ask the configured visual planner to choose one AX candidate
    /// for its current typed goal. The caller supplies and rechecks the action-specific eligible handles;
    /// this closure never authorizes an operation or acts on the client. Not installed for the watcher.
    public var visualSelect: ((AXElement, AIPlannerGoal, Set<AIPlannerCandidateKind>, String?, [AXElement], () throws -> Void) throws -> AIPlannerCandidate?)?
    /// Installed by the command handler for external commands. Rechecks the
    /// live pause, local grant, policy and target before upload and AX action.
    public var visualActionGate: ((ActionKind, String?) throws -> Void)?
    /// Only an explicit `message.history` command installs this. The closure
    /// runs bounded reversible rounds for distinct chat scroll bars and returns
    /// a gate for every subsequent scroll / restore write to the chosen bar.
    public var visualScrollRounds: ((WeComReader, Double) throws -> (bar: AXElement, recheck: () throws -> Void))?
    /// Only an explicit contact.request.list / accept command may install this
    /// bounded visual selection of a unique, visible New Customers outline row.
    public var visualNewCustomersRounds: ((AXElement) throws -> Void)?
    /// Only explicit contact.list may ask the model to identify this command's
    /// unique picker contact bar before its first required AXValue change. The
    /// returned gate guards later fixed positions without further uploads.
    public var visualContactListScrollRounds: ((AXElement, GroupPickerSheet, AXElement, Double)
        throws -> (bar: AXElement, recheck: () throws -> Void))?
    /// Only an explicit group.addMembers command may install this reversible
    /// opening step. Member selection and confirmation remain command-owned.
    public var visualOpenAddMembersRounds: ((WeComReader, String, Int) throws -> GroupPickerSheet)?
    /// The group.addMembers command rechecks its live policy, pause state and
    /// resolved target immediately before checkpoint and again before 确定.
    /// This runs even when cloud vision is disabled.
    public var addMembersCommitGate: (() throws -> Void)?
    /// Only an explicit contact.add command may install this reversible step
    /// for opening the Add Customer search window. Phone input, match selection
    /// and invitation confirmation remain in addContact and its checkpoint.
    public var visualOpenAddCustomerRounds: ((AXElement, AXElement) throws -> AddCustomerPanel)?
    /// Installed only for an explicit contact.add after this command opened a
    /// fresh Add Customer window. Each observation can veto, never choose a
    /// phone, source, greeting, match button, or invitation submission.
    public var visualObserveContactAdd: ((AXElement, AXElement, AddCustomerPanel,
                                          ContactAddVisualStage, AXElement,
                                          () throws -> Bool) throws -> Void)?
    /// Rechecks the frozen command, policy, permission, windows, and model
    /// settings immediately before each fixed AX write or checkpoint. The
    /// panel carries the 发送验证申请 window this command saw appear, the one
    /// extra window the recheck may accept (B51).
    public var visualContactAddStepGate: ((AddCustomerPanel) throws -> Void)?
    /// Only explicit message.send and message.sendFile install this read-only
    /// veto. The action supplies its own exact AX pre/postcondition; the model
    /// never receives an operation for writing, pasting, or submitting.
    public var visualObserveComposer: ((WeComReader, AXElement, ComposerVisualStage,
                                        () throws -> Bool) throws -> Void)?
    /// Rechecks the same frozen window and command scope after the first
    /// observation, immediately before the action's fixed staging write/paste.
    public var visualComposerStagingGate: (() throws -> Void)?
    /// Rechecks the frozen window, current target, policy, pause and command
    /// budget without another screenshot, immediately before checkpoint and
    /// Return. Nil on the deterministic AX path.
    public var visualComposerCommitGate: (() throws -> Void)?
    /// The pre-checkpoint text cleanup may run only while the handler proves
    /// that its original main window is still the current WeCom window.
    public var visualComposerStillCurrent: ((WeComReader, AXElement) -> Bool)?
    /// Only an explicit group.rename command installs these passive vetoes.
    /// The action retains ownership of the requested title, AX write,
    /// checkpoint, one AXConfirm, and selected-row postcondition.
    public var visualObserveGroupName: ((WeComReader, AXElement, GroupNameVisualStage,
                                         () throws -> Bool) throws -> Void)?
    public var visualGroupNameStagingGate: (() throws -> Void)?
    public var visualGroupNameCommitGate: (() throws -> Void)?
    /// Read-only reconciliation of this command's already-applied group name.
    /// An optional preparation error may be reconciled only when the handler
    /// identifies this round's stale-view failure, never a model veto.
    public var visualGroupNameAppliedGate: ((Error?) throws -> Bool)?
    /// Installed only for an explicit group.create. The action supplies the
    /// exact AX precondition before Done and a newly selected group-row proof
    /// afterwards. The model may only verify, reobserve or stop.
    public var visualObserveGroupCreate: ((WeComReader, AXElement, GroupCreateVisualStage,
                                          () throws -> Bool) throws -> Void)?
    public var visualGroupCreateCommitGate: (() throws -> Void)?
    /// Only an explicit client.navigate command installs this read-only veto.
    /// It cannot select a menu item or another conversation.
    public var visualObserveNavigation: ((NavigationVisualStage, String) throws -> Void)?
    /// Rechecks the pre-observation identity, policy and local visual grant
    /// immediately before the fixed AX Window-menu press.
    public var visualNavigationPressGate: (() throws -> Void)?
    /// Only a direct contact.request.accept installs this read-only veto. It
    /// cannot pick a card, press 接受/完成, or decide whether a contact was added.
    public var visualObserveContactAccept: ((AXElement, AXElement, NewCustomerCard, AXElement,
                                             ContactAcceptVisualStage, () throws -> Bool) throws -> Void)?
    /// Rechecks command, policy, grant, same card and same button after the
    /// checkpoint and immediately before each fixed AXPress.
    public var visualContactAcceptPressGate: ((ContactAcceptVisualStage, AXElement) throws -> Void)?
    /// Only explicit broadcast.confirm installs this passive veto. The model
    /// cannot choose a task, msgid, button, or cause the irreversible press.
    public var visualObserveBroadcastConfirm: ((WeComReader, AXElement, AXElement, AXElement,
                                                String, BroadcastConfirmVisualStage,
                                                () throws -> Bool) throws -> Void)?
    /// Fresh local policy, grant, task identity, and settings gate after the
    /// checkpoint and immediately before the command-owned AXPress.
    public var visualBroadcastConfirmPressGate: ((AXElement, AXElement, AXElement,
                                                  String, () throws -> Bool) throws -> Void)?

    public init(policy: ActionPolicy, verifyTimeout: TimeInterval = 1.5, verifyInterval: TimeInterval = 0.1) {
        self.policy = policy
        self.verifyTimeout = verifyTimeout
        self.verifyInterval = verifyInterval
    }

    // MARK: locate → open → verify_target

    public func selectConversation(_ title: String, reader: WeComReader) throws -> ActionOutcome {
        try authorize(.selectConversation, title: title)
        let matches = try reader.conversations().filter { $0.title == title }
        if matches.count > 1 { throw ActionError.targetAmbiguous(title, count: matches.count) }
        let table = reader.layout.conversationTable
        // With the visual fallback enabled, a parser miss in another row must not make one
        // parsed match look unique. Read only AX text in the row title band; the model is
        // never allowed to decide which of two identical titles the caller meant.
        let rawRows = visualSelect == nil ? [] : try table.children().filter { try $0.role() == AXRole.row }
        let rawExact = rawRows.filter { Self.rowTopBandContainsExactTitle($0, title: title) }
        if rawExact.count > 1 { throw ActionError.targetAmbiguous(title, count: rawExact.count) }
        let row: AXElement
        let rowIndex: Int
        if let parsed = matches.first {
            if let raw = rawExact.first, raw.handle != parsed.handle {
                throw ActionError.targetAmbiguous(title, count: 2)
            }
            row = AXElement(handle: parsed.handle, backend: table.backend)
            rowIndex = parsed.index
        } else {
            // A row can be visible even when the geometric title parser has not assigned its title.
            // Only the row's own top-band AX text may identify it; identical visible titles remain
            // ambiguous, regardless of what the model says. The visual selector must return that
            // exact eligible AXRow, and the active header is verified after selection below.
            guard visualSelect != nil else { throw ActionError.targetNotFound(title) }
            guard !rawExact.isEmpty else { throw ActionError.targetNotFound(title) }
            row = try visualChoice(window: reader.layout.window, goal: .conversationRow(title: title), kind: .selectRow,
                                   actionKind: .selectConversation, policyTitle: title,
                                   expectedTitle: nil, eligible: rawExact, purpose: "conversation row")
            guard let index = rawRows.firstIndex(where: { $0.handle == row.handle }) else {
                throw ActionError.targetNotFound(title)
            }
            rowIndex = index
        }
        guard try table.isSettable(AXAttribute.selectedRows) else { throw ActionError.notSettable(AXAttribute.selectedRows) }
        try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))

        var actual: String?
        let ok = try waitUntil {
            actual = try WeComReader(window: reader.layout.window).activeConversationTitle()
            return actual == title
        }
        guard ok else { throw ActionError.targetMismatch(expected: title, actual: actual) }
        return ActionOutcome(kind: ActionKind.selectConversation.rawValue, target: title, verified: true,
                             details: ["rowIndex": String(rowIndex)])
    }

    static func rowTopBandContainsExactTitle(_ row: AXElement, title: String) -> Bool {
        guard let rowFrame = (try? row.frame()) ?? nil, rowFrame.height > 0,
              let cell = ((try? row.children()) ?? []).first(where: { (try? $0.role()) == AXRole.cell }),
              let children = try? cell.children() else { return false }
        return children.contains { child in
            guard (try? child.role()) == AXRole.staticText,
                  let frame = (try? child.frame()) ?? nil,
                  frame.minY >= rowFrame.minY - 2,
                  frame.minY < rowFrame.minY + min(24, rowFrame.height / 2) else { return false }
            return (try? child.valueString()) == title
        }
    }

    // MARK: precheck_input → compose

    public func composeText(_ text: String, reader: WeComReader) throws -> ActionOutcome {
        let active = try reader.activeConversationTitle()
        try authorize(.composeText, title: active)
        let current = try reader.composerValue() ?? ""
        guard current.isEmpty else { throw ActionError.localGuard("composer not empty") }
        try setComposer(text, reader: reader)
        return ActionOutcome(kind: ActionKind.composeText.rawValue, target: active, verified: true,
                             details: ["length": String(text.count)])
    }

    public func clearComposer(reader: WeComReader) throws -> ActionOutcome {
        try authorize(.clearComposer, title: nil)
        try setComposer("", reader: reader)
        return ActionOutcome(kind: ActionKind.clearComposer.rawValue, target: nil, verified: true, details: [:])
    }

    // MARK: Helpers

    func authorize(_ kind: ActionKind, title: String?) throws {
        if let resolvedTarget, let title, resolvedTarget.title == title {
            try policy.authorize(kind, resolved: resolvedTarget)
        } else {
            try policy.authorize(kind, target: title)
        }
    }

    /// Narrows a model choice to AX elements the current action already identified as eligible. A
    /// candidate outside that set, of a different operation kind, or with a changed AX frame is never
    /// actionable even if the model returned it with confidence. Call only after the method's policy
    /// gate, and re-read the command's semantic postcondition after performing the returned element.
    func visualChoice(window: AXElement, goal: AIPlannerGoal, kind: AIPlannerCandidateKind,
                      actionKind: ActionKind, policyTitle: String? = nil,
                      expectedTitle: String?, eligible: [AXElement], purpose: String) throws -> AXElement {
        guard let visualSelect, !eligible.isEmpty else { throw ActionError.actionUnavailable(purpose) }
        let target = actionKind.requiresTarget ? (policyTitle ?? expectedTitle) : policyTitle
        let gate: () throws -> Void = {
            if let visualActionGate { try visualActionGate(actionKind, target) }
        }
        try gate()
        let originalWindowFrame = try window.frame()
        let selected: AIPlannerCandidate?
        do { selected = try visualSelect(window, goal, [kind], expectedTitle, eligible, gate) }
        catch { throw ActionError.actionUnavailable(purpose) }
        try gate()
        guard let selected, selected.kind == kind,
              selected.element.backend === window.backend,
              let expected = eligible.first(where: { $0.handle == selected.element.handle }),
              try window.pid() == selected.element.pid(),
              let originalWindowFrame, let currentWindowFrame = try window.frame(),
              abs(originalWindowFrame.minX - currentWindowFrame.minX) <= 2,
              abs(originalWindowFrame.minY - currentWindowFrame.minY) <= 2,
              abs(originalWindowFrame.width - currentWindowFrame.width) <= 2,
              abs(originalWindowFrame.height - currentWindowFrame.height) <= 2,
              try expected.role() == selected.role,
              let actualFrame = try expected.frame(),
              abs(actualFrame.minX - selected.frame.minX) <= 2,
              abs(actualFrame.minY - selected.frame.minY) <= 2,
              abs(actualFrame.width - selected.frame.width) <= 2,
              abs(actualFrame.height - selected.frame.height) <= 2 else {
            throw ActionError.actionUnavailable(purpose)
        }
        switch kind {
        case .press:
            guard try expected.actions().contains(AXAction.press), (try expected.isEnabled()) != false else {
                throw ActionError.actionUnavailable(purpose)
            }
        case .selectRow:
            guard try expected.role() == AXRole.row else { throw ActionError.actionUnavailable(purpose) }
        case .writeText:
            guard try expected.isSettable(AXAttribute.value), (try expected.isEnabled()) != false else {
                throw ActionError.actionUnavailable(purpose)
            }
        case .scroll:
            guard try expected.isSettable(AXAttribute.value) else { throw ActionError.actionUnavailable(purpose) }
        }
        if let expectedTitle {
            guard try WeComReader(window: window).activeConversationTitle() == expectedTitle else {
                throw ActionError.actionUnavailable(purpose)
            }
        }
        try gate()
        return expected
    }

    func setComposer(_ text: String, reader: WeComReader) throws {
        guard let composer = reader.layout.composer else { throw WeComError.region("composer") }
        guard try composer.isSettable(AXAttribute.value) else { throw ActionError.notSettable(AXAttribute.value) }
        try composer.setAttribute(AXAttribute.value, to: .string(text))
        var readBack: String?
        let ok = try waitUntil {
            readBack = try composer.valueString()
            return readBack == text
        }
        guard ok else { throw ActionError.verifyFailed("composer read back \(readBack?.count ?? -1) chars, expected \(text.count)") }
    }

    func waitUntil(timeout: TimeInterval? = nil, _ condition: () throws -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? verifyTimeout)
        while true {
            if try condition() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: verifyInterval)
        }
    }
}

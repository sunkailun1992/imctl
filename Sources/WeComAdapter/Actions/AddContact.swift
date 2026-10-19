import AXKit
import ControlCore
import CoreGraphics
import Foundation

/// Outcome of `contact.add`: what the panel listed and what was pressed.
public struct AddContactOutcome: Equatable {
    /// matched (dry run) | requested (添加 pressed and a verification / confirm step completed) | pressed (添加 pressed, nothing else appeared)
    /// | confirm-pressed (the invite's confirmation was pressed but its dialog or window stayed open)
    public var status: String
    public var matches: [AddCustomerPanel.Match]
    public var chosen: AddCustomerPanel.Match?
    public var details: [String: String]
}

public extension WeComActions {
    /// Only the New Customers pane's own title-band 添加 can open the search
    /// window. The pane's exact 新的客户 heading, right of the 通讯录 outline,
    /// anchors it: the button must be the heading's sibling and share its line.
    /// Live 2026-09-28 on the 60 pt rail and recorded 2026-09-15 on the 160 pt
    /// rail (5.0.11), the heading and 添加 sit side by side in the pane's group
    /// above the cards' scroll area; the window-top band (260 pt) and ±65 pt
    /// offsets recorded on one screen are gone. A 添加 on the heading's line
    /// outside that group (an overlay, another view's control) is doubt, not a
    /// candidate: nothing is offered and the command stops. Chat, match and
    /// invitation controls are never offered to the visual planner.
    static func addCustomerHeaderCandidates(window: AXElement) throws -> [AXElement] {
        guard try window.role() == AXRole.window, let wf = try window.frame(),
              WeComContactsView.isShowing(window: window) else { return [] }
        let outlines = window.descendants(maxDepth: 10, maxNodes: 3000).filter {
            (try? $0.role()) == AXRole.outline && ((try? $0.frame())??.midX ?? .greatestFiniteMagnitude) < wf.midX
        }
        guard outlines.count == 1, let outlineFrame = try outlines[0].frame() else { return [] }
        let headers = WeComContactsView.texts(in: window).filter { text, element in
            guard text == WeComContactsView.newCustomersTitle,
                  (try? element.role()) == AXRole.staticText,
                  let frame = try? element.frame(), frame.height > 0,
                  frame.minX >= outlineFrame.maxX - 4,
                  frame.minY >= wf.minY else { return false }
            return true
        }.map(\.1)
        guard headers.count == 1, let header = try headers[0].frame(),
              let pane = try headers[0].parent() else { return [] }
        let onHeadingLine = window.descendants(maxDepth: 14, maxNodes: 8000).filter { button in
            guard (try? button.role()) == AXRole.button, (try? button.title()) == "添加",
                  let frame = (try? button.frame()) ?? nil, frame.height > 0 else { return false }
            return frame.minX >= header.minX
                && min(frame.maxY, header.maxY) - max(frame.minY, header.minY) >= min(frame.height, header.height) / 2
        }
        guard try onHeadingLine.allSatisfy({ try $0.parent()?.handle == pane.handle }) else { return [] }
        return try onHeadingLine.filter { button in
            guard try button.actions().contains(AXAction.press),
                  try button.isEnabled() != false else { return false }
            let help = (try? button.string(AXAttribute.help)) ?? ""
            let value = (try? button.valueString()) ?? ""
            return !AddCustomerPanel.isInviteConfirm(help) && !AddCustomerPanel.isInviteConfirm(value)
        }
    }
}

extension WeComActions {

    /// Only a unique confirmation in the Add Customer window, a main-window
    /// popover or a separate 发送验证申请 window may finish an invite started by
    /// this command. Live 2026-09-29 (5.0.11) a WeCom user's 添加 opens that
    /// separate window next to the panel. `panel` is this command's own panel
    /// once it is known; without it the one text-input window is taken as the
    /// panel (the recorded fixture path). A separate window counts only when it
    /// is not among `separateSince` — the windows present just before this
    /// command's match press; nil counts every one, so that any window offering
    /// a confirmation before that press stops the command. Several controls
    /// have no AX link to the searched phone; vision cannot supply that link.
    func inviteConfirm(app: AXElement, mainWindow: AXElement, panel: AddCustomerPanel? = nil,
                       separateSince: Set<AXElementHandle>? = nil) throws -> AXElement? {
        let all = AddCustomerPanel.inviteConfirmButtons(app: app)
        var candidates: [AXElement] = []
        let panelWindow = try panel?.window ?? uniqueAddCustomerPanel(app: app, mainWindow: mainWindow)?.window
        if let panelWindow {
            let handles = Set(panelWindow.descendants(maxDepth: 12, maxNodes: 6000).map(\.handle))
            candidates += all.filter { handles.contains($0.handle) }
        }
        let popovers = mainWindow.descendants(maxDepth: 14, maxNodes: 6000).filter { (try? $0.role()) == AXRole.popover }
        let handles = Set(popovers.flatMap { $0.descendants(maxDepth: 8, maxNodes: 1000).map(\.handle) })
        candidates += all.filter { handles.contains($0.handle) }
        let verification = try separateInviteWindows(app: app, mainWindow: mainWindow, panelWindow: panelWindow,
                                                     separateSince: separateSince)
        let verificationHandles = Set(verification.flatMap { $0.descendants(maxDepth: 12, maxNodes: 4000).map(\.handle) })
        candidates += all.filter { verificationHandles.contains($0.handle) }
        var seen = Set<AXElementHandle>()
        let unique = candidates.filter { seen.insert($0.handle).inserted }
        guard unique.count <= 1 else {
            throw ActionError.actionUnavailable("multiple invite confirmations cannot be tied to searched phone")
        }
        return unique.first
    }

    /// The separate 发送验证申请 windows that may hold this command's invite: listed client windows
    /// other than the main window and the panel, in the recorded shape, and not among
    /// `separateSince` (nil counts every one).
    func separateInviteWindows(app: AXElement, mainWindow: AXElement, panelWindow: AXElement?,
                               separateSince: Set<AXElementHandle>?) throws -> [AXElement] {
        try app.elements(AXAttribute.windows).filter {
            $0.handle != mainWindow.handle && $0.handle != panelWindow?.handle
                && !(separateSince?.contains($0.handle) ?? false) && AddCustomerPanel.isVerificationWindow($0)
        }
    }

    /// The existing locator returns the first second window. A concurrent
    /// second text-input window makes both the searched phone and confirmation
    /// ambiguous, so this method refuses to choose one by window order.
    private func uniqueAddCustomerPanel(app: AXElement, mainWindow: AXElement) throws -> AddCustomerPanel? {
        let windows = try app.elements(AXAttribute.windows).filter {
            $0.handle != mainWindow.handle && !AddCustomerPanel.isVerificationWindow($0)
        }
        let candidates = windows.filter { window in
            window.descendants(maxDepth: 12, maxNodes: 4000).contains { (try? $0.role()) == AXRole.textField }
        }
        guard candidates.count <= 1 else { throw ActionError.actionUnavailable("multiple add customer panels") }
        return try AddCustomerPanel.locate(app: app, mainWindow: mainWindow)
    }

    /// A search window may be used only after this invocation observed exactly
    /// the main window, pressed its own header button, and then observed this
    /// one new, blank Add Customer window. A pre-existing search is never ours.
    private func commandOwnedPanel(app: AXElement, mainWindow: AXElement,
                                   expectedHandle: AXElementHandle? = nil,
                                   inviteWindow: AXElementHandle? = nil) throws -> AddCustomerPanel? {
        // The one 发送验证申请 window this command saw appear after its own match
        // press (B51) may stand beside the panel while it still has that shape;
        // any other extra window still means the windows changed.
        let windows = try app.elements(AXAttribute.windows).filter {
            $0.handle != inviteWindow || !AddCustomerPanel.isVerificationWindow($0)
        }
        guard windows.count <= 2,
              windows.contains(where: { $0.handle == mainWindow.handle }) else {
            throw ActionError.actionUnavailable("添加客户 window changed")
        }
        guard windows.count == 2 else { return nil }
        guard let other = windows.first(where: { $0.handle != mainWindow.handle }) else {
            throw ActionError.actionUnavailable("添加客户 window changed")
        }
        guard expectedHandle == nil || other.handle == expectedHandle,
              try other.role() == AXRole.window,
              try other.pid() == app.pid(),
              let frame = try other.frame(), frame.width > 0, frame.height > 0 else {
            throw ActionError.actionUnavailable("添加客户 window changed")
        }
        let all = other.descendants(maxDepth: 12, maxNodes: 4000)
        let titles = all.filter {
            (try? $0.role()) == AXRole.staticText && (try? $0.valueString()) == "添加客户"
        }
        let fields = all.filter { (try? $0.role()) == AXRole.textField }
        let closes = all.filter {
            (try? $0.role()) == AXRole.button && (try? $0.subrole()) == "AXCloseButton"
        }
        guard titles.count == 1, fields.count == 1, closes.count == 1,
              try fields[0].isSettable(AXAttribute.value),
              try closes[0].actions().contains(AXAction.press),
              try closes[0].isEnabled() != false else {
            throw ActionError.actionUnavailable("添加客户 window changed")
        }
        return AddCustomerPanel(window: other, searchField: fields[0], closeButton: closes[0])
    }

    /// Attaches the window numbers this command can prove: the one pre-existing
    /// window with the main window's frame, and — only once that one is known,
    /// so an empty or failed snapshot cannot pass the main window off as new —
    /// the one new window with the panel's frame that appeared after its own
    /// press. Waits briefly for the window server; a number that stays unproven
    /// is left nil, and a capture that needs it then refuses as before.
    func identifyWindows(of panel: AddCustomerPanel, openedFrom mainWindow: AXElement, pid: pid_t,
                         before: [WeComWindowIdentity]) -> AddCustomerPanel {
        guard let panelFrame = (try? panel.window.frame()) ?? nil,
              let mainFrame = (try? mainWindow.frame()) ?? nil else { return panel }
        var identified = panel
        identified.parentWindowID = WeComWindowIdentity.existingWindow(matching: mainFrame, in: before)
        guard let parent = identified.parentWindowID else {
            trace?("addContact: main window unproved; panel window left unproved")
            return identified
        }
        _ = try? waitUntil {
            let found = WeComWindowIdentity.newWindow(matching: panelFrame, before: before,
                                                      after: windowIdentities(pid))
            identified.windowID = found == parent ? nil : found
            return identified.windowID != nil
        }
        trace?("addContact: panel window \(identified.windowID != nil ? "proved" : "unproved"), main window \(identified.parentWindowID != nil ? "proved" : "unproved")")
        return identified
    }

    /// The number of the separate 发送验证申请 window this command's match press opened: the one
    /// new on-screen layer-0 window of its frame, given the client a moment to list it, and only
    /// when the snapshot before the press holds the main window number B50 proved. Nil leaves the
    /// invite capture refused.
    func identifyInviteWindow(_ invite: AXElement, pid: pid_t, parent: CGWindowID?,
                              before: [WeComWindowIdentity]) -> CGWindowID? {
        guard let frame = (try? invite.frame()) ?? nil, let parent, before.contains(where: { $0.id == parent }) else {
            trace?("addContact: invite window unproved (main window not in the snapshot)")
            return nil
        }
        var found: CGWindowID?
        _ = try? waitUntil {
            let id = WeComWindowIdentity.newWindow(matching: frame, before: before, after: windowIdentities(pid))
            found = id == parent ? nil : id
            return found != nil
        }
        trace?("addContact: invite window \(found != nil ? "proved" : "unproved")")
        return found
    }

    private func freshAddCustomerPanel(app: AXElement, mainWindow: AXElement,
                                       expected: AddCustomerPanel, phone: String) throws -> AddCustomerPanel {
        guard let panel = try commandOwnedPanel(app: app, mainWindow: mainWindow,
                                                expectedHandle: expected.window.handle,
                                                inviteWindow: expected.inviteWindow),
              panel.window.handle == expected.window.handle,
              panel.searchField.handle == expected.searchField.handle,
              try panel.searchField.valueString() == phone else {
            throw ActionError.actionUnavailable("添加客户 search changed")
        }
        return panel
    }

    private func freshAddMatch(app: AXElement, mainWindow: AXElement, panel: AddCustomerPanel,
                               phone: String, source: String, chosen: AddCustomerPanel.Match) throws -> AXElement {
        let freshPanel = try freshAddCustomerPanel(app: app, mainWindow: mainWindow, expected: panel, phone: phone)
        let matches = try freshPanel.matches().filter { source == "any" || $0.source == source }
        guard matches.count == 1, matches[0] == chosen else {
            throw ActionError.actionUnavailable("添加客户 match changed")
        }
        let button = AXElement(handle: matches[0].button, backend: mainWindow.backend)
        guard try button.role() == AXRole.button,
              try button.title() == "添加",
              try button.actions().contains(AXAction.press),
              (try button.isEnabled()) != false else {
            throw ActionError.actionUnavailable("添加客户 match changed")
        }
        return button
    }

    /// 通讯录 › 新的客户 › 添加 → type the number (AX) → **one Return on the search box** (approved by the user
    /// 2026-09-16 12:09: the client only searches on a key) → pick the match by `source` → press its 添加 →
    /// finish a follow-up dialog (verification text / 发送 / 确定) when one shows → close the panel.
    /// The number never reaches traces or errors; `ContactAddPolicy.mask` does.
    /// Writes the greeting (when given) into the invite box and presses the invite's confirm; "requested" once the button
    /// is gone — for a separate 发送验证申请 window, once that window is gone from the client's window list.
    func finishInvite(app: AXElement, mainWindow: AXElement, panel: AddCustomerPanel,
                      phone: String, confirm: AXElement, greeting: String?,
                      details: inout [String: String], hooks: SubmitHooks = SubmitHooks()) throws -> String {
        _ = try freshAddCustomerPanel(app: app, mainWindow: mainWindow, expected: panel, phone: phone)
        guard try inviteConfirm(app: app, mainWindow: mainWindow, panel: panel)?.handle == confirm.handle else {
            throw ActionError.actionUnavailable("添加客户 invite changed")
        }
        try visualActionGate?(.addContact, nil)
        try visualContactAddStepGate?(panel)
        if let greeting, !greeting.isEmpty {
            guard let box = AddCustomerPanel.inviteTextBox(app: app, confirm: confirm,
                                                           excluding: panel.searchField.handle) else {
                throw ActionError.actionUnavailable("添加客户 invite greeting input unavailable")
            }
            try box.setAttribute(AXAttribute.value, to: .string(greeting))
            guard try box.valueString() == greeting else {
                throw ActionError.verifyFailed("添加客户 invite greeting readback differs")
            }
            details["greeting"] = "set"
        }
        let title = (try? confirm.title()).flatMap { $0 } ?? "?"
        try visualObserveContactAdd?(app, mainWindow, panel, .inviteConfirm, confirm, {
            _ = try freshAddCustomerPanel(app: app, mainWindow: mainWindow, expected: panel, phone: phone)
            return try inviteConfirm(app: app, mainWindow: mainWindow, panel: panel)?.handle == confirm.handle
                && (greeting == nil || greeting?.isEmpty == true
                    || AddCustomerPanel.inviteTextBox(app: app, confirm: confirm,
                                                      excluding: panel.searchField.handle)?.valueString() == greeting)
        })
        try visualContactAddStepGate?(panel)
        try hooks.beforeIrreversible()
        try visualContactAddStepGate?(panel)
        try visualActionGate?(.addContact, nil)
        _ = try freshAddCustomerPanel(app: app, mainWindow: mainWindow, expected: panel, phone: phone)
        guard try inviteConfirm(app: app, mainWindow: mainWindow, panel: panel)?.handle == confirm.handle,
              try confirm.role() == AXRole.button,
              try confirm.actions().contains(AXAction.press),
              (try confirm.isEnabled()) != false else {
            throw ActionError.actionUnavailable("添加客户 invite changed")
        }
        try confirm.perform(AXAction.press)
        try hooks.afterIrreversible()
        details["confirmed"] = title
        let gone: Bool
        if let invite = panel.inviteWindow {
            // The separate window must actually close; one that stays open in another shape
            // (a prompt, a spinner) is not a sent request.
            gone = try waitUntil(timeout: 4) { try !app.elements(AXAttribute.windows).contains { $0.handle == invite } }
        } else {
            gone = try waitUntil(timeout: 4) { try inviteConfirm(app: app, mainWindow: mainWindow, panel: panel) == nil }
        }
        details["inviteDialog"] = gone ? "closed" : "still open"
        return gone ? "requested" : "confirm-pressed"
    }

    func addContact(phone: String, source: String, greeting: String?, dryRun: Bool,
                    app: AXElement, window: AXElement, hooks: SubmitHooks = SubmitHooks(),
                    requiresFreshPanel: Bool = true) throws -> AddContactOutcome {
        try policy.authorize(.addContact, target: nil)
        // The opt-out is solely for the old recorded fake fixture, which
        // starts with its second window already present. No live backend may
        // execute a command against a pre-existing search window.
        guard requiresFreshPanel || app.backend.name == "fake" else {
            throw ActionError.actionUnavailable("existing search window cannot be owned")
        }
        let masked = ContactAddPolicy.mask(phone)
        let pid = try app.pid()
        if requiresFreshPanel {
            // `withContactsView` navigates and restores the client. Reject a
            // foreign window before either of those writes can touch it.
            let beforeNavigation = try app.elements(AXAttribute.windows)
            guard beforeNavigation.count == 1,
                  beforeNavigation[0].handle == window.handle,
                  try window.children().allSatisfy({ try $0.role() != AXRole.sheet }) else {
                throw ActionError.actionUnavailable("existing search window cannot be owned")
            }
        }
        return try withContactsView(app: app, window: window) {
            var details: [String: String] = [:]
            // A leftover invite has no reliable AX phone association. A fresh
            // command cannot resume it under a new idempotency key.
            if try inviteConfirm(app: app, mainWindow: window) != nil {
                throw ActionError.actionUnavailable("existing invite cannot be tied to searched phone")
            }
            if requiresFreshPanel {
                let windowsBefore = try app.elements(AXAttribute.windows)
                guard windowsBefore.count == 1, windowsBefore[0].handle == window.handle,
                      try window.children().allSatisfy({ try $0.role() != AXRole.sheet }) else {
                    throw ActionError.actionUnavailable("existing search window cannot be owned")
                }
            }
            // 1. the New Customers header's 添加 opens a separate search window.
            var panel: AddCustomerPanel? = requiresFreshPanel ? nil
                : try uniqueAddCustomerPanel(app: app, mainWindow: window)
            if panel == nil {
                let eligible = try Self.addCustomerHeaderCandidates(window: window)
                if eligible.count == 1 {
                    let add = eligible[0]
                    try bringToFront(app: app, pid: pid)
                    try visualActionGate?(.addContact, nil)
                    guard WeComContactsView.isShowing(window: window),
                          try app.elements(AXAttribute.windows).count == 1,
                          try Self.addCustomerHeaderCandidates(window: window).contains(where: { $0.handle == add.handle }) else {
                        throw ActionError.actionUnavailable("添加 (新的客户) view changed")
                    }
                    // Only a visually observed command captures the panel; it alone needs the numbers.
                    let windowsBefore = visualObserveContactAdd != nil ? windowIdentities(pid) : []
                    try add.perform(AXAction.press)
                    guard try waitUntil({
                        panel = try? commandOwnedPanel(app: app, mainWindow: window)
                        return panel != nil
                    }) else {
                        throw ActionError.verifyFailed("添加客户 panel did not open")
                    }
                    guard let opened = panel,
                          try (!requiresFreshPanel || opened.searchField.valueString() == ""),
                          try inviteConfirm(app: app, mainWindow: window, panel: opened) == nil else {
                        throw ActionError.actionUnavailable("添加客户 search window is not blank")
                    }
                    if visualObserveContactAdd != nil {
                        panel = identifyWindows(of: opened, openedFrom: window, pid: pid, before: windowsBefore)
                    }
                } else if eligible.count > 1 {
                    guard let visualOpenAddCustomerRounds else {
                        throw ActionError.actionUnavailable("添加 (新的客户)")
                    }
                    panel = try visualOpenAddCustomerRounds(app, window)
                } else {
                    throw ActionError.actionUnavailable("添加 (新的客户)")
                }
            }
            guard let panel else { throw ActionError.verifyFailed("添加客户 panel did not open") }
            var finished = false
            // Before the first irreversible match press, closing this panel
            // cleans up a failed search or revoked visual choice. Once that
            // press is attempted, a later error is uncertain: leave the panel
            // visible for inspection instead of dismissing client evidence.
            var attemptedMatchPress = false
            defer {
                if (!attemptedMatchPress || finished),
                   let current = try? commandOwnedPanel(app: app, mainWindow: window,
                                                         expectedHandle: panel.window.handle),
                   current.closeButton?.handle == panel.closeButton?.handle {
                    try? current.closeButton?.perform(AXAction.press)
                }
            }
            details["panel"] = "opened"
            // 2. the number, then the approved Return
            try visualActionGate?(.addContact, nil)
            guard let freshPanel = try commandOwnedPanel(app: app, mainWindow: window,
                                                         expectedHandle: panel.window.handle),
                  freshPanel.window.handle == panel.window.handle,
                  freshPanel.searchField.handle == panel.searchField.handle,
                  try freshPanel.window.pid() == pid,
                  try (!requiresFreshPanel || freshPanel.searchField.valueString() == "") else {
                throw ActionError.actionUnavailable("添加客户 search changed")
            }
            if (try? freshPanel.searchField.isSettable(AXAttribute.focused)) == true {
                try? freshPanel.searchField.setAttribute(AXAttribute.focused, to: .bool(true))
            }
            try visualObserveContactAdd?(app, window, panel, .searchInput, freshPanel.searchField, {
                guard let current = try commandOwnedPanel(app: app, mainWindow: window,
                                                           expectedHandle: panel.window.handle) else { return false }
                let value = try current.searchField.valueString()
                return current.searchField.handle == panel.searchField.handle
                    && value == ""
            })
            try visualContactAddStepGate?(panel)
            try freshPanel.searchField.setAttribute(AXAttribute.value, to: .string(phone))
            try visualActionGate?(.addContact, nil)
            _ = try freshAddCustomerPanel(app: app, mainWindow: window, expected: panel, phone: phone)
            let refront = try withFront(app: app, pid: pid) { try postReturnKey(pid, false) }
            details["keystroke"] = "return -> pid \(pid)\(refront)"
            var matches: [AddCustomerPanel.Match] = []
            let found = try waitUntil(timeout: max(verifyTimeout, 6)) {
                matches = (try? panel.matches()) ?? []
                return !matches.isEmpty
            }
            trace?("addContact: \(masked) → \(matches.count) match(es) [\(matches.map { "\($0.source)/\($0.name.count)c" }.joined(separator: " "))]")
            details["matches"] = String(matches.count)
            guard found else { finished = true; return AddContactOutcome(status: "no-match", matches: [], chosen: nil, details: details) }
            // 3. the match
            let eligibleMatches = matches.filter { source == "any" || $0.source == source }
            if dryRun {
                if eligibleMatches.count == 1, let candidate = eligibleMatches.first,
                   candidate.source == "wechat" || candidate.source == "wecom" {
                    let button = AXElement(handle: candidate.button, backend: window.backend)
                    try visualObserveContactAdd?(app, window, panel.choosing(candidate.source), .sourceMatch, button, {
                        _ = try freshAddMatch(app: app, mainWindow: window, panel: panel,
                                               phone: phone, source: source, chosen: candidate)
                        return true
                    })
                }
                finished = true
                return AddContactOutcome(status: "matched", matches: matches, chosen: nil, details: details)
            }
            guard let chosen = eligibleMatches.first else {
                throw ActionError.targetNotFound("\(source) match for \(masked)")
            }
            guard eligibleMatches.count == 1 else {
                throw ActionError.targetAmbiguous("\(source) match for \(masked)", count: eligibleMatches.count)
            }
            guard chosen.source == "wechat" || chosen.source == "wecom" else {
                throw ActionError.actionUnavailable("添加客户 match source unknown")
            }
            guard try inviteConfirm(app: app, mainWindow: window, panel: panel) == nil else {
                throw ActionError.actionUnavailable("existing invite cannot be tied to searched phone")
            }
            let chosenButton = AXElement(handle: chosen.button, backend: window.backend)
            try visualObserveContactAdd?(app, window, panel.choosing(chosen.source), .sourceMatch, chosenButton, {
                _ = try freshAddMatch(app: app, mainWindow: window, panel: panel,
                                       phone: phone, source: source, chosen: chosen)
                return true
            })
            try visualContactAddStepGate?(panel)
            let addsBefore = AddCustomerPanel.followUpButtons(app: app, titles: ["添加"]).count
            try hooks.beforeIrreversible()
            try visualContactAddStepGate?(panel)
            try visualActionGate?(.addContact, nil)
            let fresh = try freshAddMatch(app: app, mainWindow: window, panel: panel,
                                          phone: phone, source: source, chosen: chosen)
            // A separate 发送验证申请 window may follow the press (B51). It is ours only if it is absent
            // from the snapshots taken here at the last moment — window numbers first (only a visually
            // observed command captures that window, so only it needs them), then AX windows — and if
            // afterwards no window offers a confirmation and the windows are still the snapshot's.
            let windowsBeforeMatch = visualObserveContactAdd != nil ? windowIdentities(pid) : []
            let windowsBeforeMatchPress = Set(try app.elements(AXAttribute.windows).map(\.handle))
            guard try inviteConfirm(app: app, mainWindow: window, panel: panel) == nil else {
                throw ActionError.actionUnavailable("existing invite cannot be tied to searched phone")
            }
            guard Set(try app.elements(AXAttribute.windows).map(\.handle)) == windowsBeforeMatchPress else {
                throw ActionError.actionUnavailable("添加客户 window changed")
            }
            attemptedMatchPress = true
            try fresh.perform(AXAction.press)
            try hooks.afterIrreversible()
            details["pressed"] = "\(chosen.source)/添加"
            // 4. the invite step: 发送添加邀请 in the panel (2026-09-16) or, for a WeCom user, a separate
            // 发送验证申请 window (2026-09-29) — greeting field + confirm; give the client a few seconds to show it
            var status = "pressed"
            var confirm: AXElement?
            _ = try waitUntil(timeout: 6) {
                confirm = try inviteConfirm(app: app, mainWindow: window, panel: panel, separateSince: windowsBeforeMatchPress)
                return confirm != nil || AddCustomerPanel.followUpButtons(app: app, titles: ["添加"]).count < addsBefore
            }
            if let confirm {
                var invitePanel = panel
                // A separate window holds the confirmation only when it is one of the listed,
                // recorded-shape windows that appeared after this press.
                if let owner = try separateInviteWindows(app: app, mainWindow: window, panelWindow: panel.window,
                                                         separateSince: windowsBeforeMatchPress)
                    .first(where: { $0.descendants(maxDepth: 12, maxNodes: 4000).contains { $0.handle == confirm.handle } }) {
                    invitePanel.inviteWindow = owner.handle
                    details["inviteWindow"] = "separate"
                    if visualObserveContactAdd != nil {
                        invitePanel.inviteWindowID = identifyInviteWindow(owner, pid: pid, parent: panel.parentWindowID,
                                                                          before: windowsBeforeMatch)
                    }
                }
                status = try finishInvite(app: app, mainWindow: window, panel: invitePanel,
                                          phone: phone, confirm: confirm, greeting: greeting,
                                          details: &details, hooks: hooks)
            }
            let after = try? panel.matches()
            details["buttonAfter"] = after?.first(where: { $0.name == chosen.name }).map { _ in "still 添加" } ?? "gone"
            finished = true
            return AddContactOutcome(status: status, matches: matches, chosen: chosen, details: details)
        }
    }
}

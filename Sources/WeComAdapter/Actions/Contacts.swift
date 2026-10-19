import AppKit
import AXKit
import ControlCore
import Foundation

public extension WeComActions {
    static let conversationListDeepLink = URL(string: "wxwork://conversationlist")!
    static let maxTabSteps = 6

    /// ⌘8 puts the client on its 8th tab; ⌃Tab steps on until the 通讯录
    /// signature (新的客户 + 智能机器人 / 添加成员...) shows, then 新的客户 is
    /// selected in the left outline. The rail order is user-configurable, so
    /// the signature check — not a fixed count — decides when to stop. The
    /// client must be frontmost for its shortcuts to work (2026-09-15).
    /// Every step is reported through `trace` and, on failure, inside the
    /// error text (roles, counts, timings — never content), so a miss inside
    /// the daemon is diagnosable from the command record alone.
    func openContacts(app: AXElement, window: AXElement) throws -> ActionOutcome {
        try policy.authorize(.openContacts, target: nil)
        let pid = try app.pid()
        let started = Date()
        var steps: [String] = []
        func note(_ line: String) {
            let stamped = "\(line) +\(Int(Date().timeIntervalSince(started) * 1000))ms"
            steps.append(stamped)
            trace?("contacts: \(stamped)")
        }
        func post(_ key: KeystrokeInjector.Shortcut) throws -> String {
            try withFront(app: app, pid: pid) { try postShortcut(key, pid) }
        }
        note("start front=\(frontmostSummary(pid)) \(WeComContactsView.scan(window: window).summary)")
        let front = try bringToFront(app: app, pid: pid)
        note("front \(front)")
        let first = try post(.commandDigit(8))
        var tabs = 0
        var scan = WeComContactsView.scan(window: window)
        var showing = try waitUntil { scan = WeComContactsView.scan(window: window); return scan.showing }
        note("⌘8\(first) \(scan.summary) focus=\(Self.focusedRole(app: app))")
        while !showing && tabs < Self.maxTabSteps {
            let move = Self.moveFocusOffTextInput(app: app, window: window)
            let again = try post(.controlTab)
            tabs += 1
            showing = try waitUntil { scan = WeComContactsView.scan(window: window); return scan.showing }
            note("⌃Tab\(tabs)\(again) focus=\(move.summary) front=\(frontmostSummary(pid)) \(scan.summary)")
        }
        guard showing else {
            throw ActionError.verifyFailed("contacts view did not appear after \(Self.maxTabSteps) tab steps [\(steps.joined(separator: "; "))]")
        }
        // An explicit request command can let the model choose the one visible,
        // exactly labelled AX row. A row outside the window has no corresponding
        // pixels, so the existing AX path remains authoritative in that case.
        // Already selected rows need no additional screen upload or AX write.
        var usedVisualSelection = false
        var alreadySelected = false
        if let visualNewCustomersRounds {
            let matches = try WeComContactsView.exactNewCustomersOutlineRows(window: window)
            if matches.count > 1 {
                throw ActionError.targetAmbiguous(WeComContactsView.newCustomersTitle, count: matches.count)
            }
            if let match = matches.first {
                let selected = (try? match.outline.elements(AXAttribute.selectedRows)) ?? []
                // The exact row is already selected, including client variants
                // whose label is AXTextField and the older selector cannot parse.
                // The strict readback below still checks the cards pane.
                alreadySelected = selected.count == 1 && selected[0].handle == match.row.handle
                if !alreadySelected,
                   let windowFrame = try window.frame(),
                   let rowFrame = try match.row.frame(),
                   rowFrame.width > 0, rowFrame.height > 0,
                   rowFrame.intersection(windowFrame).width >= rowFrame.width * 0.8,
                   rowFrame.intersection(windowFrame).height >= rowFrame.height * 0.8 {
                    try visualNewCustomersRounds(window)
                    usedVisualSelection = true
                }
            }
        }
        if !usedVisualSelection && !alreadySelected {
            try WeComContactsView.selectNewCustomers(window: window)
        }
        guard visualNewCustomersRounds != nil else {
            // Other contacts commands and background request rounds retain their
            // deterministic navigation; only explicit request methods install
            // the visual selection and strict selected-row readback.
            let table = try waitUntil { try WeComContactsView.newCustomersTable(window: window) != nil }
            note("reached steps=\(tabs) table=\(table)")
            return ActionOutcome(kind: ActionKind.openContacts.rawValue, target: nil,
                                 verified: table, details: ["steps": String(tabs)])
        }
        let selected = try waitUntil { try WeComContactsView.newCustomersSelectionVerified(window: window) }
        guard selected else { throw ActionError.verifyFailed("contacts.newCustomers selection did not settle") }
        note("reached steps=\(tabs) table=true")
        return ActionOutcome(kind: ActionKind.openContacts.rawValue, target: nil, verified: true, details: ["steps": String(tabs)])
    }

    /// "yes" / "no" / "unknown": whether the client is the frontmost application right now.
    func frontmostSummary(_ pid: pid_t) -> String {
        guard let front = frontmostPid() else { return "unknown" }
        return front == pid ? "yes" : "no"
    }

    /// Delivers one pid-level key (`deliver`) after bringing the client back
    /// when it lost the front. The client acts on posted keys only while it is
    /// the active application, and the front can be taken away between two
    /// steps — the user clicking back into their own app (live 2026-09-15:
    /// every ⌃Tab after that was dropped and the 通讯录 walk failed). Returns
    /// "" or a ` refront(...)` tag for the step trace.
    func withFront(app: AXElement, pid: pid_t, _ deliver: () throws -> Void) throws -> String {
        guard Self.lostFront(app: app, pid: pid, frontmostPid: frontmostPid) else { try deliver(); return "" }
        let again = try bringToFront(app: app, pid: pid)
        try deliver()
        return " refront(\(again))"
    }

    /// The client is not the active application: the workspace names another
    /// pid, or the client's own AXFrontmost reads false. Unknown counts as fine.
    static func lostFront(app: AXElement, pid: pid_t, frontmostPid: () -> pid_t?) -> Bool {
        if let front = frontmostPid(), front != pid { return true }
        return (try? app.bool(AXAttribute.frontmost)) == false
    }

    /// AXFrontmost, then wait for the activation to land on both sides — the
    /// workspace and the client's own AXFrontmost — because the client drops
    /// its shortcuts while still inactive (live 2026-09-15: the first ⌘8 after
    /// a daemon restart was lost that way). Unknown signals do not wait.
    /// Returns a one-line summary for the step trace.
    @discardableResult
    func bringToFront(app: AXElement, pid: pid_t) throws -> String {
        guard (try? app.isSettable(AXAttribute.frontmost)) == true else { return "AXFrontmost not settable" }
        let started = Date()
        try app.setAttribute(AXAttribute.frontmost, to: .bool(true))
        let landed = try waitUntil { (frontmostPid().map { $0 == pid } ?? true) && ((try? app.bool(AXAttribute.frontmost)) ?? true) }
        let ax = (try? app.bool(AXAttribute.frontmost)).flatMap { $0 }.map { String($0) } ?? "-"
        return "front=\(frontmostSummary(pid)) landed=\(landed) axFrontmost=\(ax) \(Int(Date().timeIntervalSince(started) * 1000))ms"
    }

    /// Where the keyboard focus was before and after a move — roles only.
    struct FocusMove: Equatable {
        public var before: String
        public var after: String
        public var targets: Int
        public var moved: Bool

        public var summary: String { "\(before)->\(after) targets=\(targets) moved=\(moved)" }
    }

    /// Role of the application's focused element: "-" when nothing is focused, "?" when the role cannot be read.
    static func focusedRole(app: AXElement) -> String {
        guard let focused = try? app.element(AXAttribute.focusedUIElement) else { return "-" }
        return (try? focused.role()) ?? "?"
    }

    /// A focused text box eats the client's ⌃Tab (live 2026-09-15: the 8th tab
    /// restores focus to its text area, and the steps after ⌘8 went nowhere).
    /// Moves keyboard focus to a table / outline of the window — an AX
    /// attribute write, not an event. `moved` is true only when a focused,
    /// non-text element could be read back afterwards.
    static func moveFocusOffTextInput(app: AXElement, window: AXElement) -> FocusMove {
        let before = focusedRole(app: app)
        guard before == AXRole.textArea || before == AXRole.textField else {
            return FocusMove(before: before, after: before, targets: 0, moved: false)
        }
        let targets = window.descendants(maxDepth: 8, maxNodes: 2000).filter { let r = try? $0.role(); return r == AXRole.table || r == AXRole.outline }
        for target in targets + [window] where (try? target.isSettable(AXAttribute.focused)) == true {
            guard (try? target.setAttribute(AXAttribute.focused, to: .bool(true))) != nil else { continue }
            let now = focusedRole(app: app)
            if now != "-", now != "?", now != AXRole.textArea, now != AXRole.textField {
                return FocusMove(before: before, after: now, targets: targets.count, moved: true)
            }
        }
        return FocusMove(before: before, after: focusedRole(app: app), targets: targets.count, moved: false)
    }

    /// Back to 消息 through the client's own deep link; waits for the conversation table.
    func returnToMessages(window: AXElement) throws -> ActionOutcome {
        let opened = openURL(Self.conversationListDeepLink)
        let back = try waitUntil { (try? WeComLayout.locate(in: window)) != nil && !WeComContactsView.isShowing(window: window) }
        trace?("contacts: return opened=\(opened) back=\(back)")
        return ActionOutcome(kind: "returnToMessages", target: nil, verified: opened && back,
                             details: ["deepLink": Self.conversationListDeepLink.absoluteString])
    }

    /// Runs `body` on the contacts view and always tries to return to 消息 and hand focus back.
    func withContactsView<T>(app: AXElement, window: AXElement, _ body: () throws -> T) throws -> T {
        let previous = frontmostPid()
        let clientPid = try? app.pid()
        defer {
            _ = try? returnToMessages(window: window)
            if let previous, previous != clientPid { restoreFrontmost(previous) }
        }
        _ = try openContacts(app: app, window: window)
        return try body()
    }
}

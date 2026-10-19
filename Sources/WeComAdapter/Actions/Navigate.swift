import AXKit
import ControlCore
import Foundation

public extension WeComActions {
    /// Menu titles as the client localises them (Chinese UI, 2026-09-15, 5.0.11).
    static let navigateMenuItems: [NavigateAction: String] = [
        .nextConversation: "选择下一个会话",
        .previousConversation: "选择上一个会话",
        .nextUnreadConversation: "选择下一个未读会话",
    ]

    /// `AXPress` the 窗口 menu item for `action`, then wait (verifyTimeout)
    /// for the active title to change. No change is a legitimate outcome
    /// (nothing unread), reported as `changed = false`.
    ///
    /// The 窗口 items validate against the active application: while the
    /// client is in the background they report `AXEnabled = false` and a
    /// press does nothing (2026-09-15, 5.0.11; `AXRaise` on the window does
    /// not help). So the client is made frontmost through the `AXFrontmost`
    /// attribute — an AX attribute write like `AXSelectedRows`, no synthetic
    /// input — the item is pressed once it reports enabled, and the app that
    /// had focus before gets it back the same way.
    func navigate(_ action: NavigateAction, app: AXElement, reader: WeComReader) throws -> ActionOutcome {
        try policy.authorize(.navigate, target: nil)
        let title = Self.navigateMenuItems[action] ?? action.rawValue
        let item: AXElement
        do { item = try WeComMenuBar.menuItem(in: app, menu: WeComMenuBar.windowMenuTitle, item: title) }
        catch { throw ActionError.actionUnavailable("menu \(WeComMenuBar.windowMenuTitle) › \(title)") }
        var before = try reader.activeConversationTitle()

        let previous = frontmostPid()
        let clientPid = try? app.pid()
        defer {
            if let previous, previous != clientPid { restoreFrontmost(previous) }
        }
        if (try? app.isSettable(AXAttribute.frontmost)) == true {
            try app.setAttribute(AXAttribute.frontmost, to: .bool(true))
        }
        let enabled = try waitUntil { try item.isEnabled() ?? true }
        if !enabled {
            return ActionOutcome(kind: ActionKind.navigate.rawValue, target: nil, verified: true, details: [
                "action": action.rawValue, "before": before ?? "", "after": before ?? "",
                "changed": "false", "enabled": "false",
            ])
        }
        // Bringing WeCom forward can update the selected row and header before
        // the menu press. The visual anchor and its predicted neighbor must
        // come from the same fresh, frontmost window state; a pre-activation
        // reader can otherwise predict a row that is no longer selected.
        let currentReader: WeComReader
        if visualObserveNavigation != nil {
            currentReader = try WeComReader(window: WeComWindowLocator.mainWindow(from: app))
            before = try currentReader.activeConversationTitle()
        } else {
            currentReader = reader
        }
        // The model never sees or chooses the macOS menu item. We enter the
        // passive two-round path only when the AX list predicts a distinct
        // selected conversation. A disabled item or an unproved destination
        // keeps the original deterministic AX path.
        let predicted = visualObserveNavigation == nil ? nil : try predictedDestination(action, before: before, reader: currentReader)
        if predicted != nil {
            try visualObserveNavigation?(.beforeMenu, before ?? "")
            try visualNavigationPressGate?()
            let liveItem = try WeComMenuBar.menuItem(in: app, menu: WeComMenuBar.windowMenuTitle, item: title)
            guard liveItem.handle == item.handle, try liveItem.isEnabled() == true else {
                throw ActionError.actionUnavailable("navigation menu item changed")
            }
            // Prediction is a gate, not a menu choice. The fixed item above
            // remains the sole action the command can perform.
        }
        try item.perform(AXAction.press)
        var after = before
        let changed = try waitUntil {
            after = try WeComReader(window: currentReader.layout.window).activeConversationTitle()
            return after != before
        }
        if let predicted, changed {
            guard after == predicted else { throw ActionError.verifyFailed("navigation selected a different conversation") }
            try visualObserveNavigation?(.afterMenu, predicted)
        }
        return ActionOutcome(kind: ActionKind.navigate.rawValue, target: nil, verified: true, details: [
            "action": action.rawValue, "before": before ?? "", "after": after ?? "",
            "changed": changed ? "true" : "false", "enabled": enabled ? "true" : "false",
        ])
    }

    /// AX row order gives a conservative prediction for a menu action. If the
    /// next row is hidden, unnamed, or ambiguous, the ordinary AX menu remains
    /// authoritative and no visual upload is required by this branch.
    private func predictedDestination(_ action: NavigateAction, before: String?, reader: WeComReader) throws -> String? {
        guard let before, !before.isEmpty else { return nil }
        let rows = try reader.conversations()
        let selected = rows.enumerated().filter { $0.element.selected }
        guard selected.count == 1, selected[0].element.title == before else { return nil }
        let current = selected[0].offset
        let candidate: ConversationRow?
        switch action {
        case .nextConversation:
            candidate = current + 1 < rows.count ? rows[current + 1] : nil
        case .previousConversation:
            candidate = current > 0 ? rows[current - 1] : nil
        case .nextUnreadConversation:
            let later = rows.dropFirst(current + 1)
            let unread = later.filter { row in
                guard let badge = row.badge?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let count = Int(badge) else { return false }
                return count > 0
            }
            candidate = unread.first
        }
        guard let title = candidate?.title, !title.isEmpty, title != before else { return nil }
        return title
    }
}

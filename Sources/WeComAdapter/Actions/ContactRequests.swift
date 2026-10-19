import AXKit
import Foundation
import ControlCore

public extension WeComActions {
    /// Only a newly opened, unique remark confirmation can be associated with
    /// this command's 接受 press. A pre-existing or second 完成 button has no AX
    /// link to the requested card, so a visual guess must not submit it.
    private func acceptFinishButtons(app: AXElement, window: AXElement) -> [AXElement] {
        let mainPopovers = window.descendants(maxDepth: 14, maxNodes: 6000).filter { (try? $0.role()) == AXRole.popover }
        let otherWindows = ((try? app.elements(AXAttribute.windows)) ?? []).filter { $0.handle != window.handle }
        let remarkLabels: Set<String> = ["设置备注名", "备注企业名称", "设置标签"]
        let remarkWindows = otherWindows.filter { other in
            other.descendants(maxDepth: 8, maxNodes: 1000).contains { element in
                guard (try? element.role()) == AXRole.staticText,
                      let value = try? element.valueString() else { return false }
                return remarkLabels.contains(value)
            }
        }
        var seen = Set<AXElementHandle>()
        return (mainPopovers + remarkWindows).flatMap { root in
            root.descendants(maxDepth: 8, maxNodes: 1000).filter {
                (try? $0.role()) == AXRole.button && (try? $0.title()) == WeComAcceptPopover.doneTitle
            }
        }.filter { seen.insert($0.handle).inserted }
    }

    private func freshPendingAcceptButton(expected: NewCustomerCard, window: AXElement) throws -> AXElement {
        guard let table = try WeComContactsView.newCustomersTable(window: window),
              let rows = try? table.children().filter({ (try? $0.role()) == AXRole.row }),
              let cards = try? NewCustomersPage.parse(table: table), cards.count == rows.count else {
            throw ActionError.actionUnavailable("接受申请 card changed")
        }
        let matches = cards.filter { $0.name == expected.name }
        guard matches.count == 1, matches[0] == expected, matches[0].status == .pending,
              matches[0].button.handle == expected.button.handle,
              try matches[0].button.role() == AXRole.button,
              try matches[0].button.title() == NewCustomersPage.acceptTitle,
              try matches[0].button.actions().contains(AXAction.press),
              (try matches[0].button.isEnabled()) != false else {
            throw ActionError.actionUnavailable("接受申请 card changed")
        }
        return matches[0].button
    }

    func contactRequestList(app: AXElement, window: AXElement) throws -> [NewCustomerCard] {
        try withContactsView(app: app, window: window) {
            try readyNewCustomerCards(window: window)
        }
    }

    /// The table can appear one AX update before its card rows. An empty table
    /// alone is not evidence that there are no requests. Re-locate it on every
    /// poll because WeCom may rebuild the table while the view settles.
    func readyNewCustomerCards(window: AXElement) throws -> [NewCustomerCard] {
        var result: [NewCustomerCard]?
        var sawTable = false
        var sawRows = false
        var emptyStateReads = 0
        let ready = try waitUntil {
            guard let table = try? WeComContactsView.newCustomersTable(window: window),
                  let children = try? table.children() else {
                emptyStateReads = 0
                return false
            }
            sawTable = true
            let rows = children.filter { (try? $0.role()) == AXRole.row }
            if !rows.isEmpty {
                sawRows = true
                emptyStateReads = 0
                guard let cards = try? NewCustomersPage.parse(table: table), cards.count == rows.count else { return false }
                result = cards
                return true
            }
            if Self.hasExplicitNewCustomersEmptyState(table: table) {
                emptyStateReads += 1
                if emptyStateReads >= 2 {
                    result = []
                    return true
                }
            } else {
                emptyStateReads = 0
            }
            return false
        }
        guard ready, let result else {
            let phase = sawRows ? "card rows incomplete" : sawTable ? "card rows not ready" : "cards table unavailable"
            throw ActionError.verifyFailed("contacts.newCustomersRow \(phase)")
        }
        return result
    }

    /// Only an explicit label in the cards scroll area can confirm a genuine
    /// empty list. A blank table, a missing row or a label elsewhere cannot.
    private static func hasExplicitNewCustomersEmptyState(table: AXElement) -> Bool {
        let labels: Set<String> = ["暂无新的客户", "暂无新客户", "暂无客户申请", "暂无申请", "暂无数据"]
        let region: AXElement
        if let parent = try? table.parent(), (try? parent.role()) == AXRole.scrollArea {
            region = parent
        } else {
            region = table
        }
        guard let tableFrame = try? table.frame() else { return false }
        return region.descendants(maxDepth: 5, maxNodes: 500).contains { element in
            guard let role = try? element.role(), role == AXRole.staticText || role == AXRole.textArea,
                  let value = try? element.valueString(), labels.contains(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let frame = try? element.frame() else { return false }
            return tableFrame.intersects(frame)
        }
    }

    /// 接受 on the unique pending card called `name`, then 完成 on the remark
    /// popover the client opens (defaults kept); verified by the button
    /// explicitly turning into 打招呼. A card disappearing is not proof.
    func contactRequestAccept(name: String, app: AXElement, window: AXElement,
                              hooks: SubmitHooks = SubmitHooks()) throws -> ActionOutcome {
        try policy.authorize(.acceptRequest, target: nil)
        return try withContactsView(app: app, window: window) {
            let cards = try readyNewCustomerCards(window: window)
            let matches = cards.filter { $0.name == name }
            guard !matches.isEmpty else { throw ActionError.targetNotFound(name) }
            guard matches.count == 1 else { throw ActionError.targetAmbiguous(name, count: matches.count) }
            let card = matches[0]
            guard card.status == .pending else { throw ActionError.localGuard("\(name) is already added") }
            // The client rebuilds the cards table after 完成 (live 2026-09-15 16:39: the
            // element read before 接受 was stale 3 s later), so every check re-locates
            // it. A stale, absent or momentarily empty table is "not settled yet";
            // only the requested card explicitly changing to added proves acceptance.
            func added() -> Bool {
                guard let now = try? WeComContactsView.newCustomersTable(window: window),
                      let cards = try? NewCustomersPage.parse(table: now), !cards.isEmpty else { return false }
                return cards.first { $0.name == name }?.status == .added
            }
            // An earlier command's remark popover cannot be associated with
            // this name. Do not resume it under a new idempotency key.
            guard acceptFinishButtons(app: app, window: window).isEmpty else {
                throw ActionError.actionUnavailable("existing accept popover cannot be tied to requested card")
            }
            func finishButton() throws -> AXElement? {
                let candidates = acceptFinishButtons(app: app, window: window)
                guard candidates.count <= 1 else {
                    throw ActionError.actionUnavailable("multiple accept popovers cannot be tied to requested card")
                }
                return candidates.first
            }
            var finish: AXElement?
            if finish == nil {
                let beforeAccept = try freshPendingAcceptButton(expected: card, window: window)
                try visualObserveContactAccept?(app, window, card, beforeAccept, .beforeAccept, {
                    guard let fresh = try? freshPendingAcceptButton(expected: card, window: window),
                          fresh.handle == beforeAccept.handle else { return false }
                    return (try? finishButton()) == nil
                })
                try hooks.beforeIrreversible()
                try visualContactAcceptPressGate?(.beforeAccept, beforeAccept)
                try visualActionGate?(.acceptRequest, nil)
                let fresh = try freshPendingAcceptButton(expected: card, window: window)
                try fresh.perform(AXAction.press)
                try hooks.afterIrreversible()
                _ = try waitUntil {
                    if let b = try finishButton() { finish = b; return true }
                    return added()
                }
            }
            if let finish {
                try visualObserveContactAccept?(app, window, card, finish, .beforeDone, {
                    guard (try? freshPendingAcceptButton(expected: card, window: window))?.handle == card.button.handle else {
                        return false
                    }
                    return (try? finishButton())?.handle == finish.handle
                })
                try hooks.beforeIrreversible()
                try visualContactAcceptPressGate?(.beforeDone, finish)
                try visualActionGate?(.acceptRequest, nil)
                let fresh = try finishButton()
                guard fresh?.handle == finish.handle,
                      try finish.actions().contains(AXAction.press),
                      (try finish.isEnabled()) != false else {
                    throw ActionError.actionUnavailable("接受申请 popover changed")
                }
                try finish.perform(AXAction.press)
                try hooks.afterIrreversible()
            }
            let deadline = Date().addingTimeInterval(acceptTimeout)
            var settled = added()
            while !settled, Date() < deadline {
                Thread.sleep(forTimeInterval: verifyInterval)
                settled = added()
            }
            guard settled else {
                throw ActionError.verifyFailed("接受 pressed\(finish == nil ? " (no remark popover seen)" : ", 完成 pressed") but \(name) still pending")
            }
            return ActionOutcome(kind: ActionKind.acceptRequest.rawValue, target: name, verified: true,
                                 details: ["name": name, "status": "added", "popover": finish == nil ? "none" : WeComAcceptPopover.doneTitle])
        }
    }
}

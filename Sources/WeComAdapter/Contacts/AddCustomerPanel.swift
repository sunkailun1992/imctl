import AXKit
import ControlCore
import CoreGraphics
import Foundation

/// 通讯录 › 新的客户 › 添加 opens the 添加客户 panel (live 2026-09-16, 5.0.11):
/// it is a **second AXWindow** of the client, the size of the screen, holding
/// a title, one `AXTextField` (the search box; `AXShowMenu` + `AXConfirm`),
/// a close button and — only after a keyed search — an `AXTable` whose rows
/// are the matches: a 26 px source icon (`AXDescription` "icon outer user
/// card search" = 微信, "appicon 24x24" = 企业微信), an avatar, the name (and
/// "添加后可查看完整信息" for 企业微信 users) and an 添加 button.
public struct AddCustomerPanel {
    public struct Match: Equatable {
        public var name: String
        /// wechat | wecom | unknown
        public var source: String
        public var subtitle: String?
        public var button: AXElementHandle
    }

    public let window: AXElement
    public let searchField: AXElement
    public let closeButton: AXElement?
    /// The panel's window number, set only when the command that pressed 添加
    /// saw exactly one new same-frame window appear (live 2026-09-28: the panel
    /// is a second layer-0 window the size of the main one). A capture needs it
    /// to take the panel rather than refuse the two stacked windows.
    public var windowID: CGWindowID? = nil
    /// The number of the main window the panel was opened from: the one on-screen
    /// window with its frame in the snapshot taken just before the press. Only a
    /// snapshot that found it may prove `windowID`; no capture uses it.
    public var parentWindowID: CGWindowID? = nil

    /// The 发送验证申请 window this command's match press opened (B51, live 2026-09-29: a WeCom
    /// user's invite comes as a separate window), once the command has seen it appear.
    public var inviteWindow: AXElementHandle? = nil
    /// That window's number, when the snapshot before the match press proves it is new.
    public var inviteWindowID: CGWindowID? = nil
    /// B54: the source (wechat | wecom) of the result this command chose; set for its result-row round.
    public var chosenSource: String? = nil

    /// This panel with the chosen result's source.
    public func choosing(_ source: String) -> AddCustomerPanel {
        var panel = self
        panel.chosenSource = source
        return panel
    }

    /// The window number a capture for this command may name. The panel's own
    /// frame is taken by its proven number. A main-window capture (the invite
    /// popover stage) names none and keeps the geometric match, which refuses
    /// while the stacked panel is open: that stage has no live sample yet, and
    /// the invite was seen inside the panel (2026-09-16).
    func captureWindowID(forPanelWindow: Bool) -> CGWindowID? { forPanelWindow ? windowID : nil }

    public static let wechatIconDescription = "icon outer user card search"
    public static let wecomIconDescription = "appicon 24x24"

    /// The panel is any client window other than the main one that holds a text field and a close button —
    /// never a 发送验证申请 window, which the live client lists before the panel once it opens (B51).
    public static func locate(app: AXElement, mainWindow: AXElement) throws -> AddCustomerPanel? {
        for w in try app.elements(AXAttribute.windows) where w.handle != mainWindow.handle && !isVerificationWindow(w) {
            let all = w.descendants(maxDepth: 12, maxNodes: 4000)
            guard let field = all.first(where: { (try? $0.role()) == AXRole.textField }) else { continue }
            let close = all.first { (try? $0.role()) == AXRole.button && (try? $0.subrole()) == "AXCloseButton" }
            return AddCustomerPanel(window: w, searchField: field, closeButton: close)
        }
        return nil
    }

    public func matches() throws -> [Match] {
        var out: [Match] = []
        let all = window.descendants(maxDepth: 12, maxNodes: 4000)
        for row in all where (try? row.role()) == AXRole.row {
            guard let rf = try row.frame() else { continue }
            var source = "unknown"
            var texts: [(String, CGRect)] = []
            var button: AXElement?
            for e in all {
                guard let f = try? e.frame(), f.midY >= rf.minY, f.midY <= rf.maxY, f.minX >= rf.minX - 1, f.maxX <= rf.maxX + 1 else { continue }
                switch try e.role() {
                case AXRole.image:
                    let d = (try? e.axDescription()).flatMap { $0 } ?? ""
                    if d == Self.wechatIconDescription { source = "wechat" } else if d == Self.wecomIconDescription { source = "wecom" }
                case AXRole.staticText, AXRole.textArea:
                    if let v = try? e.valueString(), !v.isEmpty { texts.append((v, f)) }
                case AXRole.button:
                    if (try? e.title()) == "添加" { button = e }
                default: break
                }
            }
            guard let button else { continue }
            let sorted = texts.sorted { $0.1.minY != $1.1.minY ? $0.1.minY < $1.1.minY : $0.1.minX < $1.1.minX }
            guard let name = sorted.first?.0 else { continue }
            out.append(Match(name: name, source: source, subtitle: sorted.count > 1 ? sorted[1].0 : nil, button: button.handle))
        }
        return out
    }

    /// Buttons anywhere in the client that a follow-up dialog (verification text, remark) may show.
    public static func followUpButtons(app: AXElement, titles: Set<String>) -> [AXElement] {
        app.descendants(maxDepth: 12, maxNodes: 6000).filter { (try? $0.role()) == AXRole.button && titles.contains((try? $0.title()).flatMap { $0 } ?? "") }
    }

    /// The separate 发送验证申请 window (live 2026-09-29, 5.0.11, a WeCom user's 添加), in its
    /// recorded shape only: an AXStandardWindow that is not the 添加客户 panel, with exactly one
    /// writable field — a text field holding the prefilled verification text — exactly one
    /// confirmation, titled 发送 and pressable, and one close button. A chat window also offers
    /// 发送, but its composer is a text area beside a message list; an alert offers 确定 and no
    /// field. Anything else is not an invite, and the command presses nothing in it.
    public static func isVerificationWindow(_ window: AXElement) -> Bool {
        guard (try? window.role()) == AXRole.window, (try? window.subrole()) == "AXStandardWindow" else { return false }
        let all = window.descendants(maxDepth: 12, maxNodes: 4000)
        let roles = all.map { (try? $0.role()) ?? nil }
        guard !roles.contains(where: { [AXRole.textArea, AXRole.table, AXRole.outline, AXRole.list].contains($0 ?? "") }) else {
            return false
        }
        let confirms = all.filter {
            (try? $0.role()) == AXRole.button && isInviteConfirm((try? $0.title()).flatMap { $0 } ?? "")
        }
        let fields = all.filter {
            (try? $0.role()) == AXRole.textField && (try? $0.isSettable(AXAttribute.value)) == true
        }
        let closes = all.filter { (try? $0.role()) == AXRole.button && (try? $0.subrole()) == "AXCloseButton" }
        let panelTitles = all.filter { (try? $0.role()) == AXRole.staticText && (try? $0.valueString()) == "添加客户" }
        guard confirms.count == 1, fields.count == 1, closes.count == 1, panelTitles.isEmpty else { return false }
        return (try? confirms[0].title()) == "发送" && (try? confirms[0].actions().contains(AXAction.press)) == true
    }

    /// The invite step (live 2026-09-16 12:29, user screenshot): after 添加 the panel shows 发送添加邀请 — a
    /// text box holding the client's default greeting and a button titled 发送添加邀请. Any button whose
    /// title contains 发送 or 邀请, or is 确定 / 完成, counts as the confirm of such a step.
    public static func isInviteConfirm(_ title: String) -> Bool {
        title.contains("发送") || title.contains("邀请") || title == "确定" || title == "完成"
    }

    public static func inviteConfirmButtons(app: AXElement) -> [AXElement] {
        app.descendants(maxDepth: 12, maxNodes: 6000).filter { (try? $0.role()) == AXRole.button && isInviteConfirm((try? $0.title()).flatMap { $0 } ?? "") }
    }

    /// The greeting box of the invite step: the one settable text field / area above the confirm button
    /// inside the confirm's own popover, sheet or window, other than the search box. The invite step has
    /// no AX recording (2026-09-16 was a screenshot), so ownership and uniqueness replace the earlier
    /// app-wide nearest-box guess, which could have reached another window's editor (a chat composer)
    /// or a second box of the dialog; nil when there is none or more than one, and nothing is written.
    public static func inviteTextBox(app: AXElement, confirm: AXElement, excluding: AXElementHandle?) -> AXElement? {
        guard let cf = (try? confirm.frame()) ?? nil, let container = owningContainer(of: confirm) else { return nil }
        let boxes = container.descendants(maxDepth: 12, maxNodes: 6000).filter { e in
            guard let r = try? e.role(), r == AXRole.textArea || r == AXRole.textField, e.handle != excluding,
                  (try? e.isSettable(AXAttribute.value)) == true,
                  let f = (try? e.frame()) ?? nil, f.width > 0, f.height > 0 else { return false }
            return f.maxY <= cf.minY + 4
        }
        return boxes.count == 1 ? boxes[0] : nil
    }

    /// The nearest popover, sheet or window holding `element`.
    static func owningContainer(of element: AXElement) -> AXElement? {
        var current = element
        for _ in 0..<24 {
            guard let parent = (try? current.parent()) ?? nil else { return nil }
            if let role = try? parent.role(), role == AXRole.popover || role == AXRole.sheet || role == AXRole.window {
                return parent
            }
            current = parent
        }
        return nil
    }
}

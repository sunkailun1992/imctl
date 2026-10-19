import AXKit

/// The popover the client opens on 接受 (设置备注名 / 备注企业名称 / 设置标签 and
/// 完成; user screenshot 2026-09-15): the request is accepted only through
/// its 完成. Looked for outside the main window's own content — a popover
/// anywhere, or a secondary window — so a 发起群聊 sheet's 完成 is never
/// mistaken for it. Remark, company and tags are left at their defaults.
public enum WeComAcceptPopover {
    public static let doneTitle = "完成"

    public static func doneButton(app: AXElement, mainWindow: AXElement) throws -> AXElement? {
        if (try? app.role()) != AXRole.application { return doneButton(inPopoversOf: app) }
        let mainFrame = try? mainWindow.frame()
        for child in try app.children() {
            switch try? child.role() {
            case AXRole.window where (try? child.frame()) == mainFrame: if let b = doneButton(inPopoversOf: child) { return b }
            case AXRole.window, AXRole.popover: if let b = doneButton(in: child) { return b }
            default: continue
            }
        }
        return nil
    }

    static func doneButton(inPopoversOf root: AXElement) -> AXElement? {
        for p in root.descendants(maxDepth: 12, maxNodes: 4000) where (try? p.role()) == AXRole.popover {
            if let b = doneButton(in: p) { return b }
        }
        return nil
    }

    static func doneButton(in root: AXElement) -> AXElement? {
        root.descendants(maxDepth: 8, maxNodes: 1000).first { (try? $0.role()) == AXRole.button && (try? $0.title()) == doneTitle }
    }
}

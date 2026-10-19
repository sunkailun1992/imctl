import AXKit
import Foundation

/// Compact, depth-indented lines for the parts of a dumped tree a probe is
/// after: overlays (sheets, popovers, menus, secondary windows) and the
/// labelled controls inside them. Diagnostic output only.
enum ProbeTreeSummary {
    static let overlayRoles: Set<String> = ["AXSheet", "AXPopover", "AXMenu", "AXDialog"]
    static let labelledRoles: Set<String> = ["AXButton", "AXTextField", "AXStaticText", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXTextArea"]

    static func label(_ n: AXNode) -> String? {
        if let t = n.title, !t.isEmpty { return t }
        if case .string(let s)? = n.value, !s.isEmpty { return s }
        if let p = n.placeholder, !p.isEmpty { return "placeholder:" + p }
        return n.description.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func line(_ n: AXNode, depth: Int) -> String {
        let f = n.frame.map { "[\(Int($0.x)),\(Int($0.y)) \(Int($0.width))×\(Int($0.height))]" } ?? ""
        let flags = [n.enabled == false ? "disabled" : nil, n.focused == true ? "focused" : nil].compactMap { $0 }.joined(separator: ",")
        return String(repeating: "  ", count: depth) + (n.role ?? "?") + (n.subrole.map { "/\($0)" } ?? "") + " "
            + (label(n).map { "'\($0)'" } ?? "") + " " + f + (flags.isEmpty ? "" : " " + flags)
            + (n.actions.isEmpty ? "" : " actions=" + n.actions.joined(separator: ","))
    }

    /// Every overlay subtree (and every window after the first) with its labelled controls.
    static func overlays(_ root: AXNode, maxLines: Int = 120) -> [String] {
        var out: [String] = []
        var windowsSeen = 0
        func subtree(_ n: AXNode, _ d: Int) {
            guard out.count < maxLines else { return }
            if d == 0 || overlayRoles.contains(n.role ?? "") || (labelledRoles.contains(n.role ?? "") && label(n) != nil) {
                out.append(line(n, depth: d))
            }
            for c in n.children { subtree(c, d + 1) }
        }
        func walk(_ n: AXNode, _ d: Int, underOverlay: Bool) {
            guard out.count < maxLines else { return }
            let role = n.role ?? ""
            if role == "AXWindow" && d == 1 {
                windowsSeen += 1
                if windowsSeen > 1 { subtree(n, 0); return }
            }
            if overlayRoles.contains(role) { subtree(n, 0); return }
            for c in n.children { walk(c, d + 1, underOverlay: underOverlay) }
        }
        walk(root, 0, underOverlay: false)
        return out
    }

    static let keepTexts: Set<String> = ["接受", "打招呼", "完成", "取消", "新的客户", "智能机器人", "添加成员...", "设置备注名", "备注企业名称",
                                         "设置标签", "企业名称", "添加标签", "发起群聊", "我的客户", "搜索", "确定", "添加", "发送",
                                         "添加客户", "搜索结果：", "添加后可查看完整信息", "icon outer user card search", "appicon 24x24"]

    /// The tree as it will be reported: redacted unless `raw`, so the summary
    /// lines never show more than the file does.
    static func dump(app: AXElement, to path: String?, raw: Bool) throws -> AXNode {
        var node = AXTreeDumper(maxDepth: 14, maxChildren: 400, extraAttributes: ["AXSelectedRows", "AXDisclosing", "AXDisclosureLevel", "AXExpanded", "AXSelected", "AXIndex"]).dump(app)
        if !raw { node = node.redacted(.default(keepTexts: keepTexts)) }
        if let path { try node.write(to: URL(fileURLWithPath: path)) }
        return node
    }

    /// Roles from the application down to `element`, for locating a control in prose.
    static func path(of element: AXElement) -> String {
        var parts: [String] = []
        var node: AXElement? = element
        for _ in 0..<16 {
            guard let n = node else { break }
            parts.append(((try? n.role()) ?? "?") + ((try? n.title()).flatMap { $0.isEmpty ? nil : "'\($0)'" } ?? ""))
            node = try? n.parent()
        }
        return parts.reversed().joined(separator: " > ")
    }
}

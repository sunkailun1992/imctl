import AXKit

public struct MenuItemInfo: Codable, Equatable {
    public var title: String
    public var enabled: Bool?
    public init(title: String, enabled: Bool?) { self.title = title; self.enabled = enabled }
}

/// The client's own menu bar, reached from the application element. Items are
/// driven with `AXPress` — the client's own command dispatch, no synthetic
/// input. 2026-09-15 on 5.0.11: the 窗口 items report `AXEnabled = false`
/// while the client is not the active app, yet `AXPress` succeeds and the
/// conversation switches, so `enabled` is reported but never consulted.
public enum WeComMenuBar {
    public static let windowMenuTitle = "窗口"

    public static func items(in app: AXElement, menu: String) throws -> [MenuItemInfo] {
        try menuElement(in: app, menu: menu).children()
            .filter { (try? $0.role()) == AXRole.menuItem }
            .map { MenuItemInfo(title: (try? $0.title()) ?? "", enabled: try? $0.isEnabled()) }
    }

    public static func menuItem(in app: AXElement, menu: String, item: String) throws -> AXElement {
        guard let found = try menuElement(in: app, menu: menu).children().first(where: { (try? $0.title()) == item }) else {
            throw WeComError.region("menu \(menu) › \(item)")
        }
        return found
    }

    /// The `AXMenu` under the bar item titled `menu`; there may be several
    /// `AXMenuBar` children (the live client exposes two).
    private static func menuElement(in app: AXElement, menu: String) throws -> AXElement {
        guard try app.role() == AXRole.application else { throw WeComError.region("menuBar") }
        for bar in try app.children() where (try? bar.role()) == AXRole.menuBar {
            for barItem in try bar.children() where (try? barItem.title()) == menu {
                if let submenu = try barItem.children().first(where: { (try? $0.role()) == AXRole.menu }) { return submenu }
            }
        }
        throw WeComError.region("menu \(menu)")
    }
}

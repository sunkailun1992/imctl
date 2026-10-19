import AXKit
import ControlCore
import Foundation

public struct ComposerMenuReport: Codable, Equatable {
    public var items: [String]      // "title [disabled]" per AXMenuItem
    public var menuFound: Bool
    public var closed: Bool
    public var closeMethod: String?
}

extension WeComActions {
    /// Performs AXShowMenu on the composer, lists the context menu items, then
    /// closes the menu (AXCancel on the menu, else AXShowMenu again). Used to
    /// look for a 发送 item. Never presses an item.
    public func inspectComposerMenu(reader: WeComReader, settle: TimeInterval = 0.4) throws -> ComposerMenuReport {
        let active = try reader.activeConversationTitle()
        try authorize(.showComposerMenu, title: active)
        guard let composer = reader.layout.composer else { throw WeComError.region("composer") }
        let backend = reader.layout.window.backend
        let app = AXApp.byPID(try reader.layout.window.pid(), backend: backend)

        try composer.perform(AXAction.showMenu)
        var menu: AXElement?
        let deadline = Date().addingTimeInterval(max(settle, 0.05) * 5)
        repeat {
            Thread.sleep(forTimeInterval: settle)
            menu = try app.children().first { try $0.role() == "AXMenu" }
                ?? app.descendants(maxDepth: 3, maxNodes: 300).first { (try? $0.role()) == "AXMenu" }
        } while menu == nil && Date() < deadline

        guard let menu else {
            return ComposerMenuReport(items: [], menuFound: false, closed: true, closeMethod: nil)
        }
        var items: [String] = []
        for item in menu.descendants(maxDepth: 3, maxNodes: 200) where (try? item.role()) == "AXMenuItem" {
            let title = (try? item.title()) ?? ""
            let enabled = (try? item.isEnabled()) ?? true
            items.append(enabled ? title : "\(title) [disabled]")
        }
        var closed = false
        var method: String?
        if (try? menu.perform("AXCancel")) != nil { closed = true; method = "AXCancel" }
        else if (try? composer.perform(AXAction.showMenu)) != nil { method = "AXShowMenu(toggle)" }
        if !closed {
            Thread.sleep(forTimeInterval: settle)
            closed = (try? app.children().contains { try $0.role() == "AXMenu" }) == false
        }
        return ComposerMenuReport(items: items, menuFound: true, closed: closed, closeMethod: method)
    }
}

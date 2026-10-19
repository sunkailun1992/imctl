import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct MenuBarOutput: Codable {
    var menu: String
    var reachable: Bool
    var items: [MenuItemInfo]
}

struct ProbeMenuBarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menubar",
        abstract: "List the items of one of the client's menu-bar menus (default 窗口) with their enabled flags. Read-only; presses nothing."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Menu-bar item title.") var menu: String = WeComMenuBar.windowMenuTitle

    func collect() throws -> MenuBarOutput {
        let root = try ProbeSession.root(options)
        do {
            return MenuBarOutput(menu: menu, reachable: true, items: try WeComMenuBar.items(in: root, menu: menu))
        } catch let e as WeComError {
            // Window-rooted fixtures and clients without a menu bar: report, do not fail.
            FileHandle.standardError.write(Data("menu bar unavailable: \(e.description)\n".utf8))
            return MenuBarOutput(menu: menu, reachable: false, items: [])
        }
    }

    func run() throws {
        let out = try collect()
        if options.json { print(try ProbeSession.encode(out)); return }
        print("menu: \(out.menu) reachable: \(out.reachable)")
        for item in out.items { print("  - \(item.title)\(item.enabled == false ? " [disabled]" : "")") }
    }
}

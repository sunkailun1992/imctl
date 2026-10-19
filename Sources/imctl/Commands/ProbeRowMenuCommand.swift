import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

/// Diagnostic for non-text messages (B9): inspect one message row of the
/// active conversation (default: the last media row) and every element drawn
/// over it — roles, actions, attribute names — then `AXShowMenu` on whatever
/// offers it, list the context-menu items (复制 / 另存为 …) and close the
/// menu. Presses no item. Live only.
struct ProbeRowMenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rowmenu",
        abstract: "Inspect one message row (default: the last media row) and the elements over it; AXShowMenu where offered, list the items, cancel; presses nothing."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Row index in the message table (default: the last media row, else the last row).") var index: Int?
    @Option(help: "Seconds to wait for the menu.") var settle: Double = 0.4
    @Flag(name: .customLong("no-menu"), help: "Only inspect; never AXShowMenu.") var noMenu = false

    static let contentAttributes: Set<String> = [AXAttribute.value, AXAttribute.description, AXAttribute.title, AXAttribute.help, AXAttribute.placeholderValue, "AXURL", "AXFilename"]

    func describe(_ e: AXElement, label: String) -> String {
        let role = (try? e.role()) ?? "?"
        let sub = (try? e.subrole()).flatMap { $0 } ?? "-"
        let f = (try? e.frame()).flatMap { $0 } ?? .zero
        let actions = (try? e.actions()) ?? []
        let attrs = (try? e.attributeNames()) ?? []
        var content: [String] = []
        for name in attrs where Self.contentAttributes.contains(name) {
            guard let v = try? e.attribute(name) else { continue }
            switch v {
            case .string(let s): content.append("\(name)=<\(s.count) chars\(s.hasPrefix("file:") || s.hasPrefix("/") ? ", path" : (s.hasPrefix("http") ? ", http" : ""))>")
            default: content.append("\(name)=\(v)")
            }
        }
        return "\(label) \(role)/\(sub) @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) actions=\(actions) attrs=\(attrs.count) [\(attrs.joined(separator: ","))] \(content.joined(separator: " "))"
    }

    func run() throws {
        guard options.fromFixture == nil else { throw ValidationError("live only: this probe opens the client's context menu") }
        let app = try ProbeSession.root(options)
        let window = try WeComWindowLocator.mainWindow(from: app)
        let reader = try WeComReader(window: window)
        let rows = try reader.messages()
        let row: MessageRow
        if let index { guard let r = rows.first(where: { $0.index == index }) else { throw ValidationError("no row #\(index)") }; row = r }
        else { guard let r = rows.last(where: { $0.kind == .media }) ?? rows.last else { throw ValidationError("no message rows") }; row = r }
        let element = AXElement(handle: row.handle, backend: window.backend)
        print("row #\(row.index) kind=\(row.kind.rawValue) direction=\(row.direction.rawValue) frame=\(Int(row.frame.minX)),\(Int(row.frame.minY)) \(Int(row.frame.width))×\(Int(row.frame.height))")
        print(describe(element, label: "row"))
        for (i, child) in ((try? element.children()) ?? []).enumerated() {
            print(describe(child, label: " child\(i)"))
            for (j, grand) in ((try? child.children()) ?? []).enumerated() { print(describe(grand, label: "  child\(i).\(j)")) }
        }
        // everything drawn over the row, wherever it lives in the tree (pictures are not row children in 5.0.11)
        var overlapping: [AXElement] = []
        for e in window.descendants(maxDepth: 14, maxNodes: 8000) {
            guard let f = try? e.frame(), f.width >= 20, f.height >= 20, f.intersects(row.frame), f.width < row.frame.width else { continue }
            guard e.handle != element.handle else { continue }
            overlapping.append(e)
        }
        print("elements over the row: \(overlapping.count)")
        for (i, e) in overlapping.prefix(12).enumerated() { print(describe(e, label: " over\(i)")) }
        // what the row and its cell say about themselves (custom actions, role description, a short description)
        for (label, e) in [("row", element)] + ((try? element.children()) ?? []).enumerated().map { ("cell\($0.offset)", $0.element) } {
            let custom = (try? e.attribute("AXCustomActions")).flatMap { $0 }.map { "\($0)" } ?? "nil"
            let roleDescription = (try? e.string(AXAttribute.roleDescription)).flatMap { $0 } ?? "-"
            let description = (try? e.axDescription()).flatMap { $0 } ?? ""
            let shown = description.count <= 6 ? description : "<\(description.count) chars>"
            print("\(label): customActions=\(custom) roleDescription=\(roleDescription) description=\(shown) childrenCount=\((try? e.children().count) ?? -1)")
        }
        // every picture-like element in the window (the reader's messageImages come from here)
        for (i, e) in window.descendants(maxDepth: 14, maxNodes: 8000).filter({ (try? $0.role()) == AXRole.image }).prefix(10).enumerated() {
            print(describe(e, label: " image\(i)"))
        }
        guard !noMenu else { return }
        for e in [element] + ((try? element.children()) ?? []) + overlapping {
            guard (try? e.actions())?.contains(AXAction.showMenu) == true else { continue }
            try e.perform(AXAction.showMenu)
            Thread.sleep(forTimeInterval: settle)
            let shown = try? e.element(AXAttribute.shownMenu)
            let menu = shown ?? app.descendants(maxDepth: 4, maxNodes: 800).first { (try? $0.role()) == AXRole.menu }
            guard let menu else { print("AXShowMenu on \((try? e.role()) ?? "?") showed no AXMenu"); continue }
            let items = menu.descendants(maxDepth: 3, maxNodes: 200).filter { (try? $0.role()) == AXRole.menuItem }
                .map { ((try? $0.title()) ?? "") + (((try? $0.isEnabled()) ?? true) ? "" : " [disabled]") }
            print("menu via \((try? e.role()) ?? "?"): \(items.joined(separator: " | "))")
            if (try? menu.perform(AXAction.cancel)) == nil { try? e.perform(AXAction.showMenu) }
            break
        }
    }
}

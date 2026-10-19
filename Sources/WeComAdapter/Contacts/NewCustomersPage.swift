import AXKit
import CoreGraphics

public struct NewCustomerCard: Equatable {
    public enum Status: String { case pending, added }
    public var name: String
    public var greeting: String?
    public var source: String
    public var status: Status
    public var button: AXElement

    public static func == (a: NewCustomerCard, b: NewCustomerCard) -> Bool {
        a.name == b.name && a.greeting == b.greeting && a.status == b.status && a.source == b.source
    }
}

/// One request card = one 122 px row: source label (微信), a small icon, the
/// avatar, the name (second text), the greeting (third text) and one button —
/// 接受 for a pending request, 打招呼 once the person is a contact
/// (2026-09-15, 5.0.11). Texts are taken in vertical order, never by position.
public enum NewCustomersPage {
    public static let acceptTitle = "接受"
    public static let greetTitle = "打招呼"

    public static func parse(table: AXElement) throws -> [NewCustomerCard] {
        var cards: [NewCustomerCard] = []
        for row in try table.children() where (try? row.role()) == AXRole.row {
            let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
            var texts: [(String, CGRect)] = []
            var button: AXElement?
            for child in try cell.children() {
                switch try child.role() {
                case AXRole.staticText:
                    if let v = try child.valueString(), !v.isEmpty, let f = try child.frame() { texts.append((v, f)) }
                case AXRole.button:
                    let title = try child.title() ?? ""
                    if title == acceptTitle || title == greetTitle { button = child }
                default:
                    continue
                }
            }
            guard let button else { continue }
            texts.sort { $0.1.minY < $1.1.minY }
            var source = "wecom"
            if let first = texts.first, first.1.width <= 40 {
                source = first.0 == "微信" ? "wechat" : "wecom"
                texts.removeFirst()
            }
            guard let name = texts.first?.0 else { continue }
            let greeting = texts.dropFirst().first?.0
            let status: NewCustomerCard.Status = (try button.title()) == acceptTitle ? .pending : .added
            cards.append(NewCustomerCard(name: name, greeting: greeting, source: source, status: status, button: button))
        }
        return cards
    }
}

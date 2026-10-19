import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// The layout heuristics must not depend on the window sitting at the screen
/// origin or on the recording's 1920 px width (user question 2026-09-16: other
/// Macs / screens). Fixtures are re-based by moving every frame and by
/// shrinking the pane right of the fixed sidebars.
@Suite("Geometry portability")
struct GeometryPortabilityTests {
    static func moved(_ node: AXNode, dx: CGFloat, dy: CGFloat) -> AXNode {
        var n = node
        if let f = n.frame { n.frame = AXFrame(CGRect(x: f.x + dx, y: f.y + dy, width: f.width, height: f.height)) }
        n.children = n.children.map { moved($0, dx: dx, dy: dy) }
        return n
    }

    /// Everything right of `pivot` is squeezed by `factor` (a narrower window keeps its sidebars).
    static func narrowed(_ node: AXNode, pivot: CGFloat, factor: CGFloat) -> AXNode {
        var n = node
        if let f = n.frame {
            let x0 = f.x, x1 = f.x + f.width
            func map(_ x: CGFloat) -> CGFloat { x <= pivot ? x : pivot + (x - pivot) * factor }
            n.frame = AXFrame(CGRect(x: map(x0), y: f.y, width: max(map(x1) - map(x0), x1 > x0 ? 1 : 0), height: f.height))
        }
        n.children = n.children.map { narrowed($0, pivot: pivot, factor: factor) }
        return n
    }

    @Test func contactsViewWorksWhenTheWindowIsMovedAndNarrowed() throws {
        let source = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        for variant in [Self.moved(source, dx: 300, dy: 50), Self.narrowed(source, pivot: 410, factor: 0.6), Self.moved(Self.narrowed(source, pivot: 410, factor: 0.55), dx: -100, dy: 120)] {
            let fake = FakeAXBackend(root: variant)
            #expect(WeComContactsView.isShowing(window: fake.rootElement))
            #expect(try WeComContactsView.newCustomersTable(window: fake.rootElement) != nil)
            #expect(RailBadges.newCustomersBadge(window: fake.rootElement) == 2)
            let cards = try NewCustomersPage.parse(table: try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement)))
            #expect(cards.count == 2)
        }
    }

    @Test func mainWindowLayoutSurvivesAMovedOrNarrowedWindow() throws {
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        for variant in [Self.moved(source, dx: 640, dy: 200), Self.narrowed(source, pivot: 310, factor: 0.55)] {
            let fake = FakeAXBackend(root: variant)
            let layout = try WeComLayout.locate(in: fake.rootElement)
            #expect(try layout.activeTitle?.valueString() == "文件传输助手")
            #expect(try layout.searchField?.role() == AXRole.textField && layout.plusButton != nil)
            #expect((layout.messageTableFrame?.width ?? 0) > 0 && layout.composer != nil)
            #expect(try WeComReader(window: fake.rootElement).conversations().count == 6)
        }
    }

    @Test func pickerSectionsAreMeasuredFromTheOutlineNotTheScreen() throws {
        let source = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        for variant in [source, Self.moved(source, dx: -400, dy: 80), Self.moved(source, dx: 500, dy: 0)] {
            let fake = FakeAXBackend(root: variant)
            let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
            let rows = try sheet.rows()
            #expect(rows.count == 2 && sheet.customers.count == 1 && sheet.customers[0].section == "我的客户")
        }
    }
}

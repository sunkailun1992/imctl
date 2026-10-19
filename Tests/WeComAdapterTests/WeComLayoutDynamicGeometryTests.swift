import CoreGraphics
import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("WeComLayout dynamic header geometry")
struct WeComLayoutDynamicGeometryTests {
    private static func fixture(headerY: CGFloat, buttons: [CGRect],
                                extraContainerButton: CGRect? = nil,
                                includeSearch: Bool = true) -> FakeAXBackend {
        var headerChildren = buttons.map {
            AXNode(role: AXRole.button, frame: $0, enabled: true, actions: [AXAction.press])
        }
        if includeSearch {
            headerChildren.append(AXNode(role: AXRole.textField,
                                         frame: CGRect(x: 75, y: headerY, width: 180, height: 34),
                                         settable: [AXAttribute.value]))
        }
        headerChildren += [
            AXNode(role: AXRole.table,
                   frame: CGRect(x: 60, y: headerY + 55, width: 250, height: 400)),
            AXNode(role: AXRole.table,
                   frame: CGRect(x: 311, y: headerY + 55, width: 589, height: 400)),
        ]
        var windowChildren = [AXNode(role: "AXSplitGroup", children: headerChildren)]
        if let extraContainerButton {
            windowChildren.append(AXNode(role: "AXGroup", children: [
                AXNode(role: AXRole.button, frame: extraContainerButton, enabled: true,
                       actions: [AXAction.press]),
            ]))
        }
        return FakeAXBackend(root: AXNode(role: AXRole.window,
                                          frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                                          children: windowChildren))
    }

    @Test func plusFollowsSearchWhenHeaderMovesBelowTheOldTopBand() throws {
        let fake = Self.fixture(headerY: 110,
                                buttons: [CGRect(x: 261, y: 110, width: 34, height: 34)])
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(try layout.searchField?.frame()?.minY == 110)
        #expect(try layout.plusButton?.frame()?.minY == 110)
    }

    @Test func adjacentButtonsAreAmbiguousRatherThanChosenByTreeOrder() throws {
        let fake = Self.fixture(headerY: 110, buttons: [
            CGRect(x: 261, y: 110, width: 30, height: 30),
            CGRect(x: 270, y: 110, width: 30, height: 30),
        ])
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(layout.searchField != nil)
        #expect(layout.plusButton == nil)
    }

    @Test func wideSiblingButtonIsNotMistakenForPlus() throws {
        let fake = Self.fixture(headerY: 110,
                                buttons: [CGRect(x: 261, y: 110, width: 45, height: 34)])
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(layout.searchField != nil)
        #expect(layout.plusButton == nil)
    }

    @Test func nearbyButtonFromAnotherContainerCannotBecomePlus() throws {
        let fake = Self.fixture(headerY: 110, buttons: [],
                                extraContainerButton: CGRect(x: 261, y: 110, width: 34, height: 34))
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(layout.searchField != nil)
        #expect(layout.plusButton == nil)
    }

    @Test func plusRequiresItsSearchAnchor() throws {
        let fake = Self.fixture(headerY: 110,
                                buttons: [CGRect(x: 261, y: 110, width: 34, height: 34)],
                                includeSearch: false)
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(layout.searchField == nil)
        #expect(layout.plusButton == nil)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import WeComAdapter

/// The 通讯录 badge is attributed from the rail's live AX structure — badge /
/// anchor pairs, one evenly spaced anchor column, the rail splitter — never from
/// a window-relative band (2026-09-28: the recorded 370–400 band cannot meet the
/// narrow rail's 通讯录 item, whose anchor sits near y 634). Anything that does not
/// match the recorded 5.0.11 structure stays unknown instead of guessing.
@Suite("Rail badges")
struct RailBadgesTests {
    static func load(_ name: String) throws -> AXNode {
        try AXNode.load(from: Fixtures.root.appendingPathComponent(name))
    }

    /// The narrow (60 pt) 5.0.11 rail with a count on the 通讯录 pair, shaped like the
    /// recorded numbered badges: an 18 pt sliver centred on its anchor, or the
    /// button drawn at the item's icon (x 33, 31 pt above the anchor, as the live
    /// footer badge of 2026-09-28).
    static func narrowRail(contacts title: String, drawn: Bool = false) throws -> AXNode {
        var tree = try load("wecom-5.0.11-main-window.json")
        let anchor = try #require(tree.children[0].children[3].frame)
        let midY = anchor.y + anchor.height / 2
        tree.children[0].children[2].title = title
        tree.children[0].children[2].frame = drawn
            ? AXFrame(CGRect(x: 33, y: midY - 31 - 9, width: 8, height: 18))
            : AXFrame(CGRect(x: -5, y: midY - 9, width: 10, height: 18))
        return tree
    }

    static func moved(_ node: AXNode, dx: CGFloat, dy: CGFloat) -> AXNode {
        GeometryPortabilityTests.moved(node, dx: dx, dy: dy)
    }

    @Test func everyRecordedFiveElevenRailAttributesTheContactsCount() throws {
        let expected = [
            "wecom-5.0.11-new-customers.json": 2, "wecom-5.0.11-group-picker-sheet.json": 2,
            "wecom-5.0.11-external-group.json": 1, "wecom-5.0.11-image-message.json": 1,
            "wecom-5.0.11-app-menubar.json": 0, "wecom-5.0.11-blank-pane.json": 0,
            "wecom-5.0.11-filter-panel.json": 0, "wecom-5.0.11-main-window.json": 0,
        ]
        for (name, count) in expected {
            let fake = FakeAXBackend(root: try Self.load(name))
            let window = try WeComWindowLocator.mainWindow(from: fake.rootElement)
            let reading = RailBadges.read(window: window)
            #expect(reading.contacts == count, "\(name): \(reading.problem ?? "")")
            #expect(reading.problem == nil)
            #expect(reading.slots[RailBadges.contactsListIndex].railIndex == RailBadges.contactsRailIndex)
        }
    }

    @Test func narrowRailCountIsReadAsSliverOrDrawnAtTheIcon() throws {
        for drawn in [false, true] {
            let fake = FakeAXBackend(root: try Self.narrowRail(contacts: "3", drawn: drawn))
            let reading = RailBadges.read(window: fake.rootElement)
            #expect(reading.contacts == 3 && reading.problem == nil && reading.spacing == 56)
            #expect(RailBadges.newCustomersBadge(window: fake.rootElement) == 3)
        }
    }

    @Test func otherItemsCountsNeverCountAsContacts() throws {
        // Live 2026-09-28: 消息 shows 4 as a sliver and the footer item 1 drawn at its icon.
        var tree = try Self.load("wecom-5.0.11-main-window.json")
        tree.children[0].children[0].title = "4"
        tree.children[0].children[0].frame = AXFrame(CGRect(x: -5, y: 121, width: 10, height: 18))
        tree.children[0].children[18].title = "1"
        tree.children[0].children[18].frame = AXFrame(CGRect(x: 33, y: 1154, width: 8, height: 18))
        let reading = RailBadges.read(window: FakeAXBackend(root: tree).rootElement)
        #expect(reading.contacts == 0 && reading.problem == nil)
        #expect(reading.slots[0].count == 4 && reading.slots[9].count == 1 && reading.slots[9].railIndex == nil)
    }

    @Test func movedAndOffsetWindowsKeepTheAttribution() throws {
        let narrow = try Self.narrowRail(contacts: "12", drawn: true)
        let wide = try Self.load("wecom-5.0.11-new-customers.json")
        for (tree, count) in [(Self.moved(narrow, dx: 1920, dy: 30), 12), (Self.moved(narrow, dx: -400, dy: 250), 12),
                              (Self.moved(wide, dx: 2560, dy: -80), 2)] {
            #expect(RailBadges.read(window: FakeAXBackend(root: tree).rootElement).contacts == count)
        }
    }

    @Test func aSheetHungOffTheWindowDoesNotHideTheRail() throws {
        var tree = try Self.narrowRail(contacts: "2")
        tree.children.insert(AXNode(role: AXRole.sheet, frame: CGRect(x: 660, y: 300, width: 600, height: 500)), at: 0)
        #expect(RailBadges.read(window: FakeAXBackend(root: tree).rootElement).contacts == 2)
        tree.children.append(AXNode(role: AXRole.splitGroup, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(RailBadges.read(window: FakeAXBackend(root: tree).rootElement).contacts == nil)
    }

    @Test func countTitlesAreDigitsOrAClampedCount() {
        #expect(RailBadges.count(title: nil) == 0 && RailBadges.count(title: "") == 0)
        #expect(RailBadges.count(title: "7") == 7 && RailBadges.count(title: "99+") == 99)
        #expect(RailBadges.count(title: "•") == nil && RailBadges.count(title: "+") == nil && RailBadges.count(title: "３") == nil)
    }

    @Test func aReorderedRailLeavesTheCountUnknown() throws {
        // Swap the anchors (and slivers) of list pairs 1 and 2: 通讯录's pair now sits at rail slot 8.
        var tree = try Self.narrowRail(contacts: "3")
        let split = tree.children[0].children
        tree.children[0].children[2].frame = split[4].frame.map { AXFrame(CGRect(x: -5, y: $0.y + 2 - 9, width: 10, height: 18)) }
        tree.children[0].children[3].frame = split[5].frame
        tree.children[0].children[4].frame = split[2].frame.map { AXFrame(CGRect(x: -1, y: $0.y + 9 - 2, width: 2, height: 4)) }
        tree.children[0].children[5].frame = split[3].frame
        let reading = RailBadges.read(window: FakeAXBackend(root: tree).rootElement)
        #expect(reading.contacts == nil && reading.problem?.contains("rail slot 8") == true)
        #expect(RailBadges.newCustomersBadge(window: FakeAXBackend(root: tree).rootElement) == 0)
    }

    @Test func structuralDoubtLeavesTheCountUnknown() throws {
        var unpaired = try Self.narrowRail(contacts: "3")
        unpaired.children[0].children[6].role = AXRole.staticText
        var farBadge = try Self.narrowRail(contacts: "3")
        farBadge.children[0].children[2].frame = AXFrame(CGRect(x: 33, y: 540, width: 8, height: 18))
        var outsideRail = try Self.narrowRail(contacts: "3")
        outsideRail.children[0].children[2].frame = AXFrame(CGRect(x: 120, y: 625, width: 8, height: 18))
        let unreadable = try Self.narrowRail(contacts: "新")
        var twoSplitters = try Self.narrowRail(contacts: "3")
        twoSplitters.children[0].children.append(AXNode(role: AXRole.splitter, frame: CGRect(x: 400, y: 0, width: 0, height: 1200)))
        var noSplitter = try Self.narrowRail(contacts: "3")
        noSplitter.children[0].children.removeAll { $0.role == AXRole.splitter }
        var offColumn = try Self.narrowRail(contacts: "3")
        offColumn.children[0].children[9].frame = AXFrame(CGRect(x: 20, y: 521, width: 2, height: 2))
        var overlapping = try Self.narrowRail(contacts: "3")
        overlapping.children[0].children[15].frame = AXFrame(CGRect(x: -1, y: 130, width: 2, height: 2))
        for (label, tree) in [("unpaired", unpaired), ("far", farBadge), ("outside", outsideRail), ("unreadable", unreadable),
                              ("two splitters", twoSplitters), ("no splitter", noSplitter), ("off column", offColumn),
                              ("overlapping", overlapping)] {
            let reading = RailBadges.read(window: FakeAXBackend(root: tree).rootElement)
            #expect(reading.contacts == nil && reading.problem != nil, "\(label)")
            #expect(RailBadges.newCustomersBadge(window: FakeAXBackend(root: tree).rootElement) == 0, "\(label)")
        }
    }

    /// The client's transient AX errors are doubt, never a confident zero: an unreadable 通讯录 title
    /// or rail element leaves the count unknown.
    @Test func unreadableElementsLeaveTheCountUnknown() throws {
        let fake = FakeAXBackend(root: try Self.narrowRail(contacts: "2"))
        let contactsButton = try #require(fake.handle(atPath: [0, 2]))
        fake.onRead = { handle, name in
            fake.injectedFailures["get:\(AXAttribute.title)"] = (handle == contactsButton && name == AXAttribute.title)
                ? .cannotComplete("get AXTitle") : nil
        }
        let titleFailed = RailBadges.read(window: fake.rootElement)
        #expect(titleFailed.contacts == nil && titleFailed.problem?.contains("unreadable") == true)
        fake.onRead = nil
        fake.injectedFailures = [:]
        #expect(RailBadges.read(window: fake.rootElement).contacts == 2)
        let anchor = try #require(fake.handle(atPath: [0, 9]))
        fake.onRead = { handle, name in
            fake.injectedFailures["get:\(AXAttribute.role)"] = (handle == anchor && name == AXAttribute.role)
                ? .cannotComplete("get AXRole") : nil
        }
        #expect(RailBadges.read(window: fake.rootElement).contacts == nil)
    }

    /// A drawn count sits above its own anchor (at the icon); one drawn half a spacing lower
    /// already reaches toward the next item and is not attributed.
    @Test func aCountDrawnBelowItsAnchorIsNotAttributed() throws {
        var tree = try Self.narrowRail(contacts: "3", drawn: true)
        tree.children[0].children[2].frame = AXFrame(CGRect(x: 33, y: 634 + 28 - 9, width: 8, height: 18))
        let reading = RailBadges.read(window: FakeAXBackend(root: tree).rootElement)
        #expect(reading.contacts == nil && reading.slots[1].badgeOffset == 0.5)
    }

    /// An unattributed poll keeps the last attributed count, so the watcher reports no change and
    /// the problem travels with the snapshot.
    @Test func anUnattributedPollKeepsTheLastCountWithoutADiff() throws {
        let fake = FakeAXBackend(root: try Self.narrowRail(contacts: "2"))
        let first = try WatchSnapshot.capture(WeComReader(window: fake.rootElement)).snapshot
        #expect(first.newCustomersBadge == 2 && first.newCustomersBadgeProblem == nil)
        fake.mutate(try #require(fake.handle(atPath: [0, 6])), attribute: AXAttribute.role, to: .string(AXRole.staticText))
        let second = try WatchSnapshot.capture(WeComReader(window: fake.rootElement), previous: first).snapshot
        #expect(second.newCustomersBadge == 2 && second.newCustomersBadgeProblem != nil)
        #expect(!WatchDiff.compare(first, second).contains { if case .newCustomersBadgeChanged = $0 { return true }; return false })
    }

    @Test func theWatcherSnapshotCarriesTheReadingAndItsProblem() throws {
        let narrow = FakeAXBackend(root: try Self.narrowRail(contacts: "2"))
        let recognised = try WatchSnapshot.take(WeComReader(window: narrow.rootElement))
        #expect(recognised.newCustomersBadge == 2 && recognised.newCustomersBadgeProblem == nil)
        let old = try WatchSnapshot.take(WeComReader(window: try Fixtures.mainWindow().rootElement))
        #expect(old.newCustomersBadge == 0 && old.newCustomersBadgeProblem != nil)
    }
}

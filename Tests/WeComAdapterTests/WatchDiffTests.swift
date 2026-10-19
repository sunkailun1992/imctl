import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("WatchDiff")
struct WatchDiffTests {
    @Test func noChangeNoEvents() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let a = try WatchSnapshot.take(r)
        let b = try WatchSnapshot.take(r)
        #expect(WatchDiff.compare(a, b).isEmpty)
        #expect(a.conversations.count == 6 && a.messages.isEmpty && a.active == "文件传输助手")   // the fixture's only row is a centered notice (B8)
    }

    @Test func previewMutationYieldsConversationChanged() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let before = try WatchSnapshot.take(r)
        let preview = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0, 2]))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("new preview"))
        let after = try WatchSnapshot.take(r)
        #expect(WatchDiff.compare(before, after) == [.conversationChanged(index: 2, title: "文件传输助手", fields: ["preview"])])
    }

    @Test func appendedMessageRowYieldsMessageAdded() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let before = try WatchSnapshot.take(r)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var rows = existing.children
        rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.textArea, value: .string("hi"), frame: CGRect(x: 380, y: 160, width: 100, height: 15)),
            ]),
        ]), at: rows.count - 1)
        fake.replaceChildren(of: table, with: rows)
        let after = try WatchSnapshot.take(r)
        let events = WatchDiff.compare(before, after)
        #expect(events.contains(.messageCountChanged(from: 0, to: 1)))
        #expect(after.messages.first?.direction == "outbound")
        #expect(events.contains(.messageAdded(index: 1, direction: "outbound", timeLabel: nil)))
    }

    @Test func conversationSwitchSuppressesHistoryBurst() {
        let events: [WatchEvent] = [
            .activeChanged(from: "a", to: "b"), .messageCountChanged(from: 0, to: 3),
            .messageAdded(index: 0, direction: "outbound", timeLabel: nil), .messageAdded(index: 1, direction: "inbound", timeLabel: nil),
            .conversationChanged(index: 2, title: "b", fields: ["selected"]), .composerChanged(from: 0, to: 0),
        ]
        let kept = WatchDiff.observable(events)
        #expect(kept == [.activeChanged(from: "a", to: "b"), .conversationChanged(index: 2, title: "b", fields: ["selected"]), .composerChanged(from: 0, to: 0)])
        let plain: [WatchEvent] = [.messageAdded(index: 5, direction: "outbound", timeLabel: "1:00")]
        #expect(WatchDiff.observable(plain) == plain)
    }

    @Test func prependedHistoryIsNotNewMessages() {
        func m(_ i: Int, _ t: String, _ d: String = "outbound") -> WatchSnapshot.Message { .init(index: i, text: t, timeLabel: nil, direction: d, y: Double(i)) }
        let old = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "x"), m(1, "y")], composerLength: 0)
        let new = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "h1"), m(1, "h2"), m(2, "x"), m(3, "y")], composerLength: 0)
        let events = WatchDiff.compare(old, new)
        #expect(events.contains(.messagesPrepended(count: 2)))
        #expect(!events.contains { if case .messageAdded = $0 { return true }; return false })
        #expect(!events.contains { if case .messageChanged = $0 { return true }; return false })
        #expect(!events.contains { if case .messageCountChanged = $0 { return true }; return false })
        // head and tail both match (repeated texts): treated as an append
        let dup = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "x"), m(1, "y"), m(2, "x"), m(3, "y")], composerLength: 0)
        #expect(WatchDiff.compare(old, dup).contains(.messageAdded(index: 2, direction: "outbound", timeLabel: nil)))
        // a time label change on a tail-aligned row is still reported at its new index
        let relabelled = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "h1"), m(1, "x"), .init(index: 2, text: "y", timeLabel: "1:00", direction: "outbound", y: 2)], composerLength: 0)
        #expect(WatchDiff.compare(old, relabelled).contains(.messageChanged(index: 2, fields: ["timeLabel"])))
        #expect(WatchDiff.observable([.activeChanged(from: "a", to: "b"), .messagesPrepended(count: 3)]) == [.activeChanged(from: "a", to: "b")])
    }

    @Test func activeAndComposerChangesAreReported() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let before = try WatchSnapshot.take(r)
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("other"))
        let composer = try #require(fake.handle(atPath: [0, 33, 6, 0, 2, 0]))
        fake.mutate(composer, attribute: AXAttribute.value, to: .string("abc"))
        let after = try WatchSnapshot.take(r)
        let events = WatchDiff.compare(before, after)
        #expect(events.contains(.activeChanged(from: "文件传输助手", to: "other")))
        #expect(events.contains(.composerChanged(from: 0, to: 3)))
        #expect(WatchEvent.composerChanged(from: 0, to: 3).summary.contains("composer"))
    }

    @Test func badgeChangeIsAnEvent() {
        var a = WatchSnapshot(active: "a", conversations: [], messages: [], composerLength: 0)
        var b = a; b.newCustomersBadge = 2
        #expect(WatchDiff.compare(a, b).contains { if case .newCustomersBadgeChanged(0, 2) = $0 { return true }; return false })
        a.newCustomersBadge = 2
        #expect(!WatchDiff.compare(a, b).contains { if case .newCustomersBadgeChanged = $0 { return true }; return false })
    }
}

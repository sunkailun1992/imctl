import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// 2026-09-15, 5.0.11: a conversation whose pane exposes nothing to AX — no
/// message table, no composer, no header; only the list (and the filter side
/// panel) remain. Recorded while the daemon was stuck in the `system` pause.
@Suite("Blank-pane fixture (5.0.11)")
struct BlankPaneFixtureTests {
    static func fake() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-blank-pane.json")))
    }

    @Test func layoutHasOnlyTheConversationListAndTheTitleFallsBackToTheSelectedRow() throws {
        let fake = try Self.fake()
        let reader = try WeComReader(window: fake.rootElement)
        #expect(reader.layout.messageTable == nil && reader.layout.composer == nil && reader.layout.activeTitle == nil)
        #expect(Int(reader.layout.conversationTableFrame.minX) == 159)
        let selected = try #require(try reader.conversations().first(where: \.selected)?.title)
        #expect(selected.hasPrefix("«"))   // a real title, redacted at recording time
        #expect(try reader.activeConversationTitle() == selected)
        #expect(try reader.messages().isEmpty && reader.layout.messageTable == nil)
        #expect(try reader.activeConversationType() == .unknown)
        let snapshot = try WatchSnapshot.take(reader)
        #expect(snapshot.active == selected && snapshot.messages.isEmpty && snapshot.conversations.count == 11)
    }

    @Test func engineThrottlesRelocationWhileThePaneStaysBlank() throws {
        let fake = try Self.fake()
        var subscriptions = 0
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.onRelocated = { _ in subscriptions += 1 }
        for _ in 0..<11 { _ = try engine.poll() }
        // initial location, then the 5th and 10th blank polls mark a re-location for the next poll: 3 in 11 polls, not 11
        #expect(engine.polls == 11 && engine.relocations == 3 && subscriptions == 3)
    }

    @Test func fallbackNeverOverridesARealHeader() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.layout.activeTitle != nil && reader.activeConversationTitle() == "文件传输助手")
        let noActive = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-main-window.json")))
        let fresh = try WeComReader(window: noActive.rootElement)
        // fresh launch: no header and no selected row → still nil
        #expect(try fresh.conversations().first(where: \.selected) == nil)
        #expect(try fresh.activeConversationTitle() == nil)
    }
}

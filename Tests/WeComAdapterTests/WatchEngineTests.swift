import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("WatchEngine on fake")
struct WatchEngineTests {
    static func row(_ text: String, x: CGFloat) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.textArea, value: .string(text), frame: CGRect(x: x, y: 160, width: 94, height: 15)),
            ]),
        ])
    }

    @Test func unchangedRowsReuseCompleteMessagesAndPeriodicPollRefreshesInPlaceEdits() throws {
        let fake = GroupFixture.backend(messages: [GroupFixture.messageRow(y: 64, text: "first")])
        let body = try #require(fake.handle(atPath: GroupFixture.messageTablePath + [0, 0, 0]))
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.fullMessageReadEvery = 3
        var bodyReads = 0
        fake.onRead = { handle, attribute in
            if handle == body && attribute == AXAttribute.value { bodyReads += 1 }
        }

        #expect(try engine.poll().isEmpty)
        #expect(bodyReads > 0)
        bodyReads = 0
        fake.mutate(body, attribute: AXAttribute.value, to: .string("edited in place"))
        #expect(try engine.poll().isEmpty)
        #expect(bodyReads == 0 && engine.previous?.messages.first?.text == "first")

        #expect(try engine.poll().isEmpty) // third poll is the bounded fallback
        #expect(bodyReads > 0 && engine.previous?.messages.first?.text == "edited in place")

        bodyReads = 0
        fake.mutate(body, attribute: AXAttribute.value, to: .string("notification edit"))
        #expect(try engine.poll(forceMessages: true).isEmpty)
        #expect(bodyReads > 0 && engine.previous?.messages.first?.text == "notification edit")
    }

    @Test func changedRowHandlesOrSelectedPreviewForceMessageRead() throws {
        let fake = GroupFixture.backend(messages: [GroupFixture.messageRow(y: 64, text: "first")])
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        let body = try #require(fake.handle(atPath: GroupFixture.messageTablePath + [0, 0, 0]))
        let preview = try #require(fake.handle(atPath: GroupFixture.groupRowPreviewPath))
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.fullMessageReadEvery = 100
        var bodyReads = 0
        fake.onRead = { handle, attribute in
            if handle == body && attribute == AXAttribute.value { bodyReads += 1 }
        }

        _ = try engine.poll()
        bodyReads = 0
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("new preview"))
        _ = try engine.poll()
        #expect(bodyReads > 0)

        // The preview stays fixed; appending a row must still be observed.
        bodyReads = 0
        fake.appendChild(to: table, node: GroupFixture.messageRow(y: 144, text: "second"))
        let drafts = try engine.poll()
        #expect(bodyReads > 0)
        #expect(drafts.contains { $0.kind == .messageObserved && $0.payload["text"] == "second" })
    }

    @Test func forcedPartialReadInvalidatesCachedMessagesAndRecovers() throws {
        let fake = GroupFixture.backend(messages: [GroupFixture.messageRow(y: 64, text: "complete")])
        let body = try #require(fake.handle(atPath: GroupFixture.messageTablePath + [0, 0, 0]))
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        #expect(try engine.poll().isEmpty)
        fake.onRead = { handle, attribute in
            guard attribute == AXAttribute.value else { return }
            fake.injectedFailures["get:AXValue"] = handle == body
                ? .apiFailure(code: -25201, operation: "get AXValue") : nil
        }
        #expect(throws: WeComError.region("incomplete message AXValue")) {
            try engine.poll(forceMessages: true)
        }
        #expect(engine.reader == nil)

        fake.onRead = nil
        fake.injectedFailures["get:AXValue"] = nil
        #expect(try engine.poll().isEmpty)
        #expect(engine.previous?.messages.first?.text == "complete")
    }

    @Test func engineAttributesAppendedOutboundRowAndIgnoresPrepend() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var relocated = 0
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) },
                                 recentSends: { [ControllerSend(commandId: "c1", target: "文件传输助手", text: "b1", tsMs: 1)] })
        engine.onRelocated = { _ in relocated += 1 }
        #expect(try engine.poll().isEmpty && relocated == 1)
        var rows = existing.children
        rows.insert(Self.row("b1", x: 1800), at: rows.count - 1)          // ours
        fake.replaceChildren(of: table, with: rows)
        let d1 = try engine.poll()
        #expect(d1.count == 1 && d1[0].kind == .messageObserved)
        #expect(d1[0].payload["origin"] == "controller" && d1[0].payload["commandId"] == "c1" && d1[0].payload["text"] == "b1" && d1[0].payload["kind"] == "message")
        rows.insert(Self.row("someone", x: 1800), at: rows.count - 1)     // a human, from elsewhere
        fake.replaceChildren(of: table, with: rows)
        let d2 = try engine.poll()
        #expect(d2.count == 1 && d2[0].payload["origin"] == "other" && d2[0].payload["direction"] == "outbound")
        #expect(d2[0].payload["commandId"] == nil && d2[0].payload["conversation"] == "文件传输助手")
        rows.insert(contentsOf: [Self.row("old1", x: 380), Self.row("old2", x: 380)], at: 0)   // history loaded
        fake.replaceChildren(of: table, with: rows)
        #expect(try engine.poll().isEmpty)
        #expect(engine.polls == 4 && engine.relocations == 1)
    }

    @Test func fileTransferAssistantLeftSideRowIsStillOurOwnAndConversationActivityIsDrafted() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        _ = try engine.poll()
        var rows = existing.children
        rows.insert(Self.row("hello?", x: 380), at: rows.count - 1)
        fake.replaceChildren(of: table, with: rows)
        let preview = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0, 2]))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("hello?"))
        let drafts = try engine.poll()
        #expect(drafts.count == 2)
        #expect(drafts.contains { $0.kind == .conversationActivity && $0.payload["fields"] == "preview" && $0.payload["preview"] == "hello?" })
        #expect(drafts.contains { $0.kind == .messageObserved && $0.payload["origin"] == "other" && $0.payload["direction"] == "outbound" })
    }

    @Test func engineRelocatesAfterErrorAndEveryNPolls() throws {
        let fake = try Fixtures.mainWindow()
        var calls = 0
        let engine = WatchEngine(readerProvider: {
            calls += 1
            if calls == 2 { throw AXKitError.cannotComplete("x") }
            return try WeComReader(window: fake.rootElement)
        })
        engine.relocateEvery = 3
        _ = try engine.poll(); _ = try engine.poll(); _ = try engine.poll()
        #expect(engine.reader == nil)
        #expect(throws: AXKitError.self) { try engine.poll() }
        _ = try engine.poll()
        #expect(engine.relocations == 2 && engine.errors == 1 && calls == 3)
    }


    @Test func groupObservationsCarrySenderKeyTypeAndBridgeIds() throws {
        let fake = GroupFixture.backend()
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.identityLookup = { title in title == "imctl测试群" ? [Identity(kind: .group, id: "wr1", title: title, updatedMs: 1)] : [] }
        #expect(try engine.poll().isEmpty)
        var rows = GroupFixture.defaultMessages()
        rows.append(GroupFixture.messageRow(y: 454, text: "在吗", sender: "王五"))
        rows.append(GroupFixture.systemRow(y: 534, text: "«b2»加入群聊"))   // never observed
        rows.append(AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931)))
        fake.replaceChildren(of: table, with: rows)
        let drafts = try engine.poll()
        #expect(drafts.count == 1)
        let p = drafts[0].payload
        #expect(drafts[0].kind == .messageObserved && p["sender"] == "王五" && p["text"] == "在吗" && p["origin"] == "peer" && p["direction"] == "inbound")
        #expect(p["conversationType"] == "group" && p["chatId"] == "wr1" && p["externalUserId"] == nil)
        #expect(p["messageKey"] == MessageKey.make(conversation: "imctl测试群", sender: "王五", timeLabel: nil, text: "在吗", ordinal: 0))
        // a list-row change carries the bridge id; with no marker the bridge kind fills the type (B4 calibration rule)
        let preview = try #require(fake.handle(atPath: GroupFixture.groupRowPreviewPath))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("王五: 在吗"))
        let d2 = try engine.poll()
        #expect(d2.count == 1 && d2[0].kind == .conversationActivity && d2[0].payload["chatId"] == "wr1" && d2[0].payload["conversationType"] == "group")
    }

    @Test func bridgeFillsTheTypeAndAnEmptySenderIsOmitted() throws {
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.identityLookup = { $0 == "文件传输助手" ? [Identity(kind: .group, id: "wr1", title: "文件传输助手", updatedMs: 0)] : [] }
        _ = try engine.poll()
        var rows = existing.children
        rows.insert(Self.row("no sender label", x: 1800), at: rows.count - 1)
        fake.replaceChildren(of: table, with: rows)
        let drafts = try engine.poll()
        let observed = try #require(drafts.first { $0.kind == .messageObserved })
        #expect(observed.payload["conversationType"] == "group" && observed.payload["chatId"] == "wr1")
        #expect(observed.payload["sender"] == nil && observed.payload["messageKey"]?.count == 16)
    }
}

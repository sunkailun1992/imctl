import CoreGraphics
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Group conversation parsing (synthetic fixture)")
struct GroupParsingTests {
    @Test func headerStripsMemberCountAndInfersGroup() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let header = try #require(try reader.activeConversationHeader())
        #expect(header.raw == "imctl测试群(3)" && header.title == "imctl测试群" && header.memberCount == 3)
        #expect(try reader.activeConversationTitle() == "imctl测试群")
        #expect(try reader.activeConversationType() == .group)
        #expect(try reader.activeConversationRow()?.title == "imctl测试群")
        #expect(ConversationHeader.parse("文件传输助手") == ConversationHeader(raw: "文件传输助手", title: "文件传输助手", memberCount: nil))
        #expect(ConversationHeader.parse("群 （12）").title == "群" && ConversationHeader.parse("群 （12）").memberCount == 12)
        #expect(ConversationHeader.parse("张三(客户)").memberCount == nil)
    }

    @Test func rowsCarryKindSenderAndSystemNoticesAreFiltered() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let all = try reader.messages()
        #expect(all.map(\.kind) == [.timeSeparator, .system, .message, .message, .message, .message])
        #expect(all[1].text == "«a1»加入群聊" && all[1].direction == .unknown && all[1].senderLabel == nil)
        #expect(all[2].senderLabel == "张三" && all[2].direction == .inbound)
        #expect(all[3].senderLabel == nil && all[3].direction == .outbound)
        let chat = try reader.chatMessages()
        #expect(chat.map(\.index) == [2, 3, 4, 5])
        let keys = chat.compactMap(\.messageKey)
        #expect(keys.count == 4 && Set(keys).count == 4)
        #expect(keys[0] == MessageKey.make(conversation: "imctl测试群", sender: "张三", timeLabel: nil, text: "大家好", ordinal: 0))
        #expect(keys[2] != keys[3])   // two identical "收到" from 李四 differ by ordinal
    }

    @Test func conversationRowsExposeMarkersAndTypes() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let rows = try reader.conversations()
        #expect(rows.map(\.title) == ["文件传输助手", "imctl测试群", "小明·a1b2c3", "«ext»", "同事甲"])
        #expect(rows[2].markers == ["微信"] && rows[3].markers == ["外部"] && rows[0].markers.isEmpty)
        #expect(rows[2].preview == "«p2»")   // the marker is not mistaken for title or preview
        #expect(rows.map(ConversationTypeInference.infer(row:)) == [.unknown, .unknown, .customer, .group, .unknown])
        #expect(ConversationTypeInference.infer(header: nil, messages: [], row: nil) == .unknown)
    }

    /// Live 2026-09-15 (5.0.11): the 外部 tag of an external group row arrives in
    /// the badge text area (sometimes with a trailing U+200B), not as a static text.
    @Test func badgeSlotCarryingAListTagBecomesAMarker() throws {
        let row = GroupFixture.conversationRow(y: 200, title: "«g»", preview: "«p»", time: "16:43", badge: "外部\u{200B}")
        let plain = GroupFixture.conversationRow(y: 264, title: "«h»", preview: "«q»", time: "昨天", badge: "3")
        let table = AXNode(role: AXRole.table, frame: CGRect(x: 60, y: 200, width: 250, height: 128), children: [row, plain])
        let rows = try ConversationRowParser().parse(table: FakeAXBackend(root: table).rootElement)
        #expect(rows[0].markers == ["外部"] && rows[0].badge == nil && ConversationTypeInference.infer(row: rows[0]) == .group)
        #expect(rows[1].markers.isEmpty && rows[1].badge == "3" && ConversationTypeInference.infer(row: rows[1]) == .unknown)
    }

    /// Live 2026-09-15 21:59 (5.0.11, redacted fixture): in an external group the
    /// sender of an inbound bubble is a clickable "名字@微信" button above it, and
    /// the header shows no member count — the sender label alone proves the group.
    @Test func externalGroupSenderIsAButtonWithoutTheWeChatTag() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-external-group.json")))
        let reader = try WeComReader(window: fake.rootElement)
        let rows = try reader.messages()
        #expect(rows.map(\.kind) == [.system, .system, .message, .message])
        #expect(rows[2].direction == .outbound && rows[2].senderLabel == nil)
        #expect(rows[3].direction == .inbound && rows[3].senderLabel == "«s1»")
        #expect(try reader.activeConversationHeader()?.memberCount == nil && (try reader.activeConversationType()) == .group)
        #expect(MessageRowParser.senderName(from: "张三@某公司") == "张三@某公司")
    }

    @Test func plainFixtureIsUnchanged() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        #expect(try reader.activeConversationType() == .unknown)
        let rows = try reader.messages()
        #expect(rows.count == 1 && rows[0].kind == .system)   // pixel-centered text area (B8): a notice, not a bubble
        #expect(try reader.chatMessages().isEmpty)
    }
}

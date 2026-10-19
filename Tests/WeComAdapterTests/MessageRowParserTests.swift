import CoreGraphics
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("MessageRowParser on 5.0.10 fixture")
struct MessageRowParserTests {
    @Test func parsesSingleVisibleMessageWithUnknownDirection() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        let rows = try reader.messages()
        #expect(rows.count == 1)
        #expect(rows[0].timeLabel == "9:18")
        #expect(rows[0].text?.hasPrefix("«") == true)
        #expect(rows[0].bodyFrame?.width == 412)
        #expect(rows[0].direction == .unknown)
        #expect(try reader.composerValue() == "")
    }

    /// Live 2026-09-15 21:19 (5.0.11, redacted fixture): a conversation with an
    /// image message. Row 3 is a 246 px row whose cell has no children (the
    /// picture is not exposed as text); rows 1–2 are centered text areas —
    /// system notices, not messages.
    @Test func imageRowIsMediaAndCenteredTextAreasAreSystemNotices() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-image-message.json")))
        let reader = try WeComReader(window: fake.rootElement)
        let rows = try reader.messages()
        #expect(rows.map(\.kind) == [.message, .system, .system, .media])
        #expect(rows[0].direction == .inbound && rows[0].timeLabel == "9:32")
        #expect(rows[3].text == nil && rows[3].direction == .unknown && rows[3].frame.height == 246)
        let chat = try reader.chatMessages()
        #expect(chat.map(\.index) == [0, 3] && chat[1].kind == .media && chat[1].messageKey != nil && chat[0].messageKey != chat[1].messageKey)
    }

    /// Live 2026-09-16 11:01 (5.0.11): the first picture after a gap is one 388 px row whose only child is the
    /// time label — a media row that carries its own label, not a time separator.
    @Test func aTallRowWithOnlyATimeLabelIsAPictureWithItsLabel() throws {
        let table = AXNode(role: AXRole.table, frame: CGRect(x: 2330, y: -1046, width: 1511, height: 1942), children: [
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 2331, y: 423, width: 1509, height: 84), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 2331, y: 423, width: 1509, height: 84), children: [
                    AXNode(role: AXRole.staticText, value: .string("2:03"), frame: CGRect(x: 3071, y: 430, width: 30, height: 18)),
                    AXNode(role: AXRole.textArea, value: .string("hello"), frame: CGRect(x: 3638, y: 460, width: 176, height: 20)),
                ]),
            ]),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 2331, y: 507, width: 1509, height: 388), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 2331, y: 507, width: 1509, height: 388), children: [
                    AXNode(role: AXRole.staticText, value: .string("11:01"), frame: CGRect(x: 3071, y: 514, width: 30, height: 18)),
                ]),
            ]),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 2331, y: 895, width: 1509, height: 40), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 2331, y: 895, width: 1509, height: 40), children: [
                    AXNode(role: AXRole.staticText, value: .string("昨天 9:24"), frame: CGRect(x: 3060, y: 900, width: 60, height: 18)),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: table)
        let rows = try MessageRowParser().parse(table: fake.rootElement, tableFrame: table.frame?.cgRect ?? .zero)
        #expect(rows.map(\.kind) == [.message, .media, .timeSeparator])
        #expect(rows[1].timeLabel == "11:01" && rows[1].text == nil && rows[1].frame.height == 388)
        #expect(rows[2].timeLabel == "昨天 9:24")
    }

    @Test func groupSenderLabelDisambiguatesCenteredLongBubble() throws {
        let tableFrame = CGRect(x: 310, y: 0, width: 1610, height: 600)
        func row(senderX: CGFloat?) -> AXNode {
            var children: [AXNode] = []
            if let senderX {
                children.append(AXNode(role: AXRole.staticText, value: .string("测试发送者"),
                                       frame: CGRect(x: senderX, y: 100, width: 70, height: 18)))
            }
            children.append(AXNode(role: AXRole.textArea, value: .string("一条较长的群消息"),
                                   frame: CGRect(x: 690, y: 130, width: 850, height: 30)))
            return AXNode(role: AXRole.row, frame: CGRect(x: 311, y: 90, width: 1608, height: 100), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 90, width: 1608, height: 100), children: children),
            ])
        }
        let table = AXNode(role: AXRole.table, frame: tableFrame,
                           children: [row(senderX: 390), row(senderX: 1080), row(senderX: nil)])
        let parsed = try MessageRowParser().parse(table: FakeAXBackend(root: table).rootElement, tableFrame: tableFrame)
        #expect(parsed[0].kind == .message && parsed[0].senderLabel == "测试发送者" && parsed[0].direction == .inbound)
        #expect(parsed[1].kind == .message && parsed[1].senderLabel == "测试发送者" && parsed[1].direction == .unknown)
        #expect(parsed[2].kind == .message && parsed[2].senderLabel == nil && parsed[2].direction == .unknown)
    }

    @Test func aMediaRowsOwnImageStillProvidesDirection() throws {
        let frame = CGRect(x: 300, y: 0, width: 1200, height: 400)
        let picture = AXNode(role: AXRole.image, frame: CGRect(x: 1220, y: 70, width: 220, height: 180))
        let table = AXNode(role: AXRole.table, frame: frame, children: [
            AXNode(role: AXRole.row, frame: CGRect(x: 301, y: 60, width: 1198, height: 220), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 301, y: 60, width: 1198, height: 220), children: [picture]),
            ]),
        ])
        let row = try #require(MessageRowParser().parse(table: FakeAXBackend(root: table).rootElement, tableFrame: frame).first)
        #expect(row.kind == .media && row.direction == .outbound)
    }

    @Test func ignoredChildRoleDoesNotReadGeometry() throws {
        let tableFrame = CGRect(x: 0, y: 0, width: 600, height: 200)
        let table = AXNode(role: AXRole.table, frame: tableFrame, children: [
            AXNode(role: AXRole.row, frame: CGRect(x: 0, y: 0, width: 600, height: 80), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 0, y: 0, width: 600, height: 80), children: [
                    AXNode(role: AXRole.group, frame: CGRect(x: 10, y: 10, width: 40, height: 40)),
                    AXNode(role: AXRole.textArea, value: .string("hello"), frame: CGRect(x: 400, y: 20, width: 100, height: 20)),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: table)
        let ignored = try #require(fake.handle(atPath: [0, 0, 0]))
        let body = try #require(fake.handle(atPath: [0, 0, 1]))
        var ignoredGeometryReads = 0
        var bodyGeometryReads = 0
        fake.onRead = { handle, attribute in
            guard [AXAttribute.frame, AXAttribute.position, AXAttribute.size].contains(attribute) else { return }
            if handle == ignored { ignoredGeometryReads += 1 }
            if handle == body { bodyGeometryReads += 1 }
        }
        let rows = try MessageRowParser().parse(table: fake.rootElement, tableFrame: tableFrame)
        #expect(rows.count == 1 && rows[0].text == "hello" && rows[0].kind == .message)
        #expect(ignoredGeometryReads == 0)
        #expect(bodyGeometryReads > 0)
    }
}

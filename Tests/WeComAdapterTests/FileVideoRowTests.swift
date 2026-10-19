import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Live 2026-09-22 (5.0.11, macOS 27.0, 文件传输助手): a text row, an outbound video (play icon + duration), an
/// outbound docx and an inbound pdf (file icon + name + size), and a picture row whose cell has no children.
@Suite("File / video rows (B13)")
struct FileVideoRowTests {
    func rows() throws -> [MessageRow] {
        let table = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-file-video-rows.json"))
        let fake = FakeAXBackend(root: table)
        return try MessageRowParser().parse(table: fake.rootElement, tableFrame: table.frame?.cgRect ?? .zero)
    }

    /// An inbound file row of a group: the sender's name is a static text ABOVE the bubble, so it comes
    /// first among the cell's children and must not be mistaken for the file name.
    static func groupFileRow(y: CGFloat) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 112), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 112), children: [
                GroupFixture.text("9:20", x: 1102, y: y + 7, w: 40),
                GroupFixture.text("李四", x: 390, y: y + 30, w: 60, h: 16),
                AXNode(role: AXRole.image, description: "file word emphasized", frame: CGRect(x: 390, y: y + 52, width: 42, height: 42)),
                GroupFixture.text("report.docx", x: 445, y: y + 52, w: 169, h: 20),
                GroupFixture.text("14K", x: 445, y: y + 78, w: 24),
            ]),
        ])
    }

    /// An outbound video bubble: the play icon carries the direction, the duration sits under it.
    static func videoRow(y: CGFloat) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 360), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 360), children: [
                AXNode(role: AXRole.image, description: "wwsecurity play action play 40", frame: CGRect(x: 1792, y: y + 150, width: 42, height: 42)),
                GroupFixture.text("00:07", x: 1863, y: y + 300, w: 32),
            ]),
        ])
    }

    @Test func kindsFieldsAndDirections() throws {
        let r = try rows()
        #expect(r.map(\.kind) == [.message, .video, .file, .file, .media])
        #expect(r[1].timeLabel == "17:38" && r[1].duration == "01:14" && r[1].text == nil && r[1].direction == .outbound)
        #expect(r[2].fileName == "report.docx" && r[2].fileSize == "14K" && r[2].fileType == "word" && r[2].text == nil && r[2].direction == .outbound)
        #expect(r[3].fileName == "invoice.pdf" && r[3].fileSize == "74K" && r[3].fileType == "pdf" && r[3].direction == .inbound)
        #expect(r[4].text == nil && r[4].timeLabel == nil && r[4].direction == .unknown)
    }

    @Test func aVideoWithoutItsOwnTimeLabelKeepsTheDurationOutOfTimeLabel() throws {
        let table = AXNode(role: AXRole.table, frame: CGRect(x: 311, y: 0, width: 1609, height: 600), children: [
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 0, width: 1609, height: 360), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 0, width: 1609, height: 360), children: [
                    AXNode(role: AXRole.image, description: "wwsecurity play action play 40", frame: CGRect(x: 400, y: 150, width: 42, height: 42)),
                    AXNode(role: AXRole.staticText, value: .string("00:07"), frame: CGRect(x: 640, y: 320, width: 32, height: 18)),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: table)
        let r = try MessageRowParser().parse(table: fake.rootElement, tableFrame: table.frame?.cgRect ?? .zero)
        #expect(r.count == 1 && r[0].kind == .video && r[0].timeLabel == nil && r[0].duration == "00:07" && r[0].direction == .inbound)
    }

    /// Review 2026-09-22: in a group the cell's children are [time, sender, icon, name, size]; the name is
    /// the first non-size static that is not entirely above the icon, and the sender is the one that is.
    @Test func aGroupFileRowTakesTheNameFromTheBubbleNotTheSenderLabel() throws {
        let window = GroupFixture.window(messages: [GroupFixture.timeRow(y: 64, "9:18"), Self.groupFileRow(y: 94)])
        let reader = try WeComReader(window: FakeAXBackend(root: window).rootElement)
        let row = try #require(try reader.messages().last)
        #expect(row.kind == .file && row.fileName == "report.docx" && row.fileSize == "14K" && row.fileType == "word")
        #expect(row.senderLabel == "李四" && row.direction == .inbound && row.text == nil && row.timeLabel == "9:20")
    }

    @Test func keysUseTheFileNameAndHistoryCarriesTheFields() throws {
        let fileRow = AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                GroupFixture.text("invoice.pdf", x: 1657, y: 113, w: 142, h: 20),
                GroupFixture.text("74K", x: 1657, y: 139, w: 24),
            ]),
        ])
        let messages = [GroupFixture.timeRow(y: 64, "9:18"), fileRow]
        let window = GroupFixture.window(messages: messages)
        let fake = FakeAXBackend(root: window)
        let reader = try WeComReader(window: fake.rootElement)
        let chat = try reader.chatMessages()
        #expect(chat.count == 1 && chat[0].kind == .file && chat[0].messageKey == MessageKey.make(conversation: GroupFixture.groupTitle, sender: nil, timeLabel: nil, text: "invoice.pdf", ordinal: 0))
        let snapshot = try WatchSnapshot.take(reader)
        #expect(snapshot.messages.first?.fileName == "invoice.pdf" && snapshot.messages.first?.fileSize == "74K" && snapshot.messages.first?.kind == "file")
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-fv-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation, .scrollHistory], phase: .phase1), checkpoints: cps)
        let hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.count == 1 && hist[0]["kind"] == "file" && hist[0]["fileName"] == "invoice.pdf" && hist[0]["fileSize"] == "74K" && hist[0]["fileType"] == "pdf" && hist[0]["text"] == nil && hist[0]["media"] == "unmatched" && hist[0]["mediaType"] == nil)
        // A video appended after the first poll: its duration reaches both message.observed and message.history.
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        #expect(try engine.poll().isEmpty)
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        fake.replaceChildren(of: table, with: messages + [Self.videoRow(y: 176), AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931))])
        let drafts = try engine.poll()
        #expect(drafts.count == 1 && drafts[0].kind == .messageObserved && drafts[0].payload["kind"] == "video" && drafts[0].payload["duration"] == "00:07" && drafts[0].payload["mediaType"] == nil)
        let grown = try h.messageHistory(limit: 10, scrollback: false)
        #expect(grown.count == 2 && grown[1]["kind"] == "video" && grown[1]["duration"] == "00:07")
    }
}

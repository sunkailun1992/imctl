import AXKit
import CoreGraphics
import Foundation
import Testing
import WeComAdapter
@testable import imctl

@Suite("probe commands")
struct ProbeCommandTests {
    @Test func conversationsFromFixtureRedactedByDefault() throws {
        let cmd = try ProbeConversationsCommand.parse(["--from-fixture", Fixtures.mainWindowPath()])
        let out = try cmd.collect()
        #expect(out.conversations.count == 6)
        #expect(out.conversations.contains { $0.title == "文件传输助手" })
        #expect(out.conversations.allSatisfy { $0.title == "文件传输助手" || $0.title?.hasPrefix("«") == true })
        #expect(out.render().contains("文件传输助手"))
    }

    @Test func messagesFromFixture() throws {
        let cmd = try ProbeMessagesCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--json"])
        let out = try cmd.collect()
        #expect(out.active == "文件传输助手")
        #expect(out.messages.count == 1 && out.messages[0].kind == "system" && out.messages[0].direction == "unknown")   // a pixel-centered text area is a notice (B8)
        #expect(out.messages[0].messageKey == nil)   // notices never get a message key
        #expect(out.composerLength == 0)
        #expect(try out.jsonString().contains("\"kind\" : \"system\""))
    }

    @Test func messagesProbeReadsTheMessageTableOnlyOnce() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())))
        let reader = try WeComReader(window: fake.rootElement)
        let table = try #require(reader.layout.messageTable)
        let tableFrame = try #require(reader.layout.messageTableFrame)
        let timeFrame = CGRect(x: tableFrame.midX - 30, y: tableFrame.minY + 20, width: 60, height: 20)
        let timeRowFrame = CGRect(x: tableFrame.minX, y: timeFrame.minY, width: tableFrame.width, height: 24)
        _ = fake.appendChild(to: table.handle, node: AXNode(role: AXRole.row, frame: timeRowFrame, children: [
            AXNode(role: AXRole.cell, frame: timeRowFrame, children: [
                AXNode(role: AXRole.staticText, value: .string("10:20"), frame: timeFrame),
            ]),
        ]))
        let bodyFrame = CGRect(x: tableFrame.maxX - 200, y: tableFrame.minY + 50, width: 150, height: 25)
        let messageRowFrame = CGRect(x: tableFrame.minX, y: bodyFrame.minY, width: tableFrame.width, height: 36)
        _ = fake.appendChild(to: table.handle, node: AXNode(role: AXRole.row, frame: messageRowFrame, children: [
            AXNode(role: AXRole.cell, frame: messageRowFrame, children: [
                AXNode(role: AXRole.textArea, value: .string("probe synthetic text"), frame: bodyFrame),
            ]),
        ]))
        var tableReads = 0
        fake.onRead = { handle, attribute in
            if handle == table.handle && attribute == AXAttribute.children { tableReads += 1 }
        }
        let command = try ProbeMessagesCommand.parse(["--from-fixture", Fixtures.mainWindowPath()])
        let output = try command.collect(reader: reader, redact: ProbeSession.redactor(command.options))
        #expect(tableReads == 1)
        #expect(output.messages.map(\.kind) == ["system", "timeSeparator", "message"])
        #expect(output.messages[0].messageKey == nil)
        #expect(output.messages[1].messageKey == nil)
        #expect(output.messages[2].messageKey != nil)
        #expect(output.messages[2].text?.hasPrefix("«") == true)
    }

    @Test func probeIsRegistered() {
        let names = IMCTL.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names.contains("probe"))
        let sub = ProbeCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["conversations", "messages", "watch", "select", "compose", "submit", "menu", "scrollback", "menubar", "contacts", "picker", "rowmenu", "addcustomer", "addmembers", "rail", "ax-timing"])
    }

    @Test func railReadsTheContactsBadgeFromRecordedRails() throws {
        let root = URL(fileURLWithPath: Fixtures.mainWindowPath()).deletingLastPathComponent()
        let wide = try ProbeRailCommand.parse(["--from-fixture", root.appendingPathComponent("wecom-5.0.11-new-customers.json").path]).collect()
        #expect(wide.contacts == 2 && wide.problem == nil && wide.spacing == 32)
        let narrow = try ProbeRailCommand.parse(["--from-fixture", root.appendingPathComponent("wecom-5.0.11-main-window.json").path]).collect()
        #expect(narrow.contacts == 0 && narrow.problem == nil && narrow.spacing == 56)
        // 5.0.10 lists its badge pairs in another order: unknown, never a guess.
        let old = try ProbeRailCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]).collect()
        #expect(old.contacts == nil && old.problem != nil)
    }

    @Test func menubarFromAppFixture() throws {
        let path = URL(fileURLWithPath: Fixtures.mainWindowPath()).deletingLastPathComponent().appendingPathComponent("wecom-5.0.11-app-menubar.json").path
        let out = try ProbeMenuBarCommand.parse(["--from-fixture", path]).collect()
        #expect(out.menu == "窗口" && out.reachable && out.items.map(\.title).contains("选择下一个会话"))
        let bare = try ProbeMenuBarCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]).collect()
        #expect(!bare.reachable && bare.items.isEmpty)
    }
}

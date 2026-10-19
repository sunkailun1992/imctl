import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("ConversationRowParser on 5.0.10 fixture")
struct ConversationRowParserTests {
    @Test func parsesSixRowsSkippingZeroHeight() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        let rows = try reader.conversations()
        #expect(rows.count == 6)
        #expect(rows.map(\.index) == [1, 2, 3, 4, 5, 6])
        #expect(rows.allSatisfy { $0.frame.height == 64 })
        let fta = try #require(rows.first { $0.title == "文件传输助手" })
        #expect(fta.selected)
        #expect(fta.timeLabel == "9:18")
        #expect(fta.preview?.hasPrefix("«") == true)
        #expect(rows.filter(\.selected).count == 1)
        #expect(rows.map(\.timeLabel) == ["10:17", "9:18", "9:18", "9:18", "9/2", "8/28"])
        #expect(rows[5].badge != nil)
        #expect(rows[0...4].allSatisfy { $0.badge == nil })
    }
}

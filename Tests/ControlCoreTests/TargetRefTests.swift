import Testing
@testable import ControlCore

@Suite("TargetRef")
struct TargetRefTests {
    @Test func parsesPrefixesAndFallsBackToTitle() {
        #expect(TargetRef.parse("chatId:wrABC") == .chatId("wrABC"))
        #expect(TargetRef.parse("externalUserId:wmXYZ") == .externalUserId("wmXYZ"))
        #expect(TargetRef.parse("文件传输助手") == .title("文件传输助手"))
        #expect(TargetRef.parse("chatId: wr1 ") == .chatId("wr1"))
        // an empty id is not a silent match: it stays a (never-existing) title
        #expect(TargetRef.parse("chatId:") == .title("chatId:"))
        #expect(TargetRef.parse("chatId:wr1").wire == "chatId:wr1")
        #expect(TargetRef.parse("x").isTitle && !TargetRef.parse("chatId:x").isTitle)
    }
}

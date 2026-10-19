import Testing
@testable import WeComAdapter

@Suite("WeComClient")
struct WeComClientTests {
    @Test func constantsAreTheAgreedOnes() {
        #expect(WeComClient.bundleID == "com.tencent.WeWorkMac")
        #expect(WeComClient.fileTransferAssistantTitle == "文件传输助手")
    }
}

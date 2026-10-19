import Foundation
import Testing
@testable import WeComAPI

@Suite("WeComProxySettings")
struct WeComProxySettingsTests {
    @Test func savesPrivatelyAndSummaryHidesTheToken() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-wecom-\(UUID().uuidString)/wecom-proxy.json")
        let s = WeComProxySettings(baseURL: "https://proxy.example.test/", token: "secret-token", corpId: "wwx", agentId: 1000002)
        try s.save(to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        let back = try WeComProxySettings.load(from: url)
        #expect(back == s && !back.summary.contains("secret-token") && back.summary.contains("wwx"))
        #expect(back.normalizedBaseURL.absoluteString == "https://proxy.example.test")
        #expect(WeComProxySettings.defaultURL.path.hasSuffix("/imctl/wecom-proxy.json"))
    }
}

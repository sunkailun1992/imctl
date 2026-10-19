import Foundation
import Testing
@testable import imctl
@testable import WeComAPI

@Suite("imctl wecom")
struct WeComCommandTests {
    @Test func enrollWritesPrivateSettingsAndStatusHidesToken() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-wecom-cli-\(UUID().uuidString)/wecom-proxy.json").path
        try WeComEnrollCommand.parse(["--proxy", "https://proxy.example.test", "--token", "abc123", "--corp-id", "wwx", "--agent-id", "7", "--config", file]).run()
        let s = try WeComProxySettings.load(from: URL(fileURLWithPath: file))
        #expect(s.token == "abc123" && s.corpId == "wwx" && s.agentId == 7)
        let status = try WeComStatusCommand.parse(["--config", file]).collect()
        #expect(status["present"] as? Bool == true && (status["summary"] as? String)?.contains("abc123") == false)
        #expect(throws: (any Error).self) { try WeComEnrollCommand.parse(["--proxy", "ftp://x", "--token", "t", "--config", file]).validate() }
        let sub = WeComCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["enroll", "status", "call", "sync-groups"])
    }
}

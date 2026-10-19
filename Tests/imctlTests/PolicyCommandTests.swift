import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("imctl policy")
struct PolicyCommandTests {
    func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-cli-\(UUID().uuidString)/policy.json").path
    }

    @Test func allowThenDenyRoundTripsThroughTheFile() throws {
        let file = tempFile()
        let allow = try PolicyAllowCommand.parse(["--title", "imctl测试群", "--type", "group", "--chat-id", "wr1", "--file", file])
        let after = try allow.apply()
        #expect(after.allowedTitles == ["imctl测试群"] && after.allowedTypes.group && after.allowedChatIds == ["wr1"])
        #expect(try SendPolicy.load(from: URL(fileURLWithPath: file)) == after)
        let deny = try PolicyDenyCommand.parse(["--type", "group", "--title", "imctl测试群", "--file", file])
        let denied = try deny.apply()
        #expect(denied.allowedTitles.isEmpty && !denied.allowedTypes.group && denied.allowedChatIds == ["wr1"])
        let list = try PolicyListCommand.parse(["--file", file])
        let view = try list.collect()
        #expect(view.compiled == ["文件传输助手"] && view.effectiveTitles == ["文件传输助手"] && view.policy.allowedChatIds == ["wr1"])
    }

    @Test func allowNeedsAtLeastOneRuleAndRejectsUnknownType() throws {
        #expect(throws: (any Error).self) { try PolicyAllowCommand.parse(["--file", "/tmp/x.json"]).validate() }
        #expect(throws: (any Error).self) { try PolicyAllowCommand.parse(["--type", "unknown", "--file", "/tmp/x.json"]).validate() }
        #expect(throws: Never.self) { try PolicyAllowCommand.parse(["--type", "customer", "--file", "/tmp/x.json"]).validate() }
    }

    @Test func policyIsRegisteredWithNineSubcommands() {
        let sub = PolicyCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["list", "allow", "deny", "requests", "remote", "all", "reads", "phones", "hosts"])
    }

    /// B14 (user 2026-09-22 「全部放开」): `all --enable` writes allowAll=true (0600), `--disable`
    /// resets it, `list` reflects it, and exactly one of --enable/--disable is required.
    @Test func allSubcommandWritesAllowAllAndListReflectsIt() throws {
        let file = tempFile()
        try PolicyAllCommand.parse(["--enable", "--file", file]).run()
        var policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(policy.allowAll)
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        var view = try PolicyListCommand.parse(["--file", file]).collect()
        #expect(view.policy.allowAll)

        try PolicyAllCommand.parse(["--disable", "--file", file]).run()
        policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(!policy.allowAll)
        view = try PolicyListCommand.parse(["--file", file]).collect()
        #expect(!view.policy.allowAll)

        #expect(throws: (any Error).self) { try PolicyAllCommand.parse(["--file", file]).validate() }
        #expect(throws: (any Error).self) { try PolicyAllCommand.parse(["--enable", "--disable", "--file", file]).validate() }
        #expect(throws: Never.self) { try PolicyAllCommand.parse(["--enable", "--file", file]).validate() }
    }

    @Test func requestsSubcommandWritesContactRequestPolicy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-req-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("policy.json").path
        let cmd = try PolicyRequestsCommand.parse(["--file", file, "--auto-accept", "rules", "--allow-name", "测试联系人A", "--greeting-contains", "示例公司", "--auto-group", "perPerson", "--default-member", "同事A", "--group-name-suffix", "群聊", "--max-accepts-per-hour", "5"])
        let policy = try cmd.apply()
        #expect(policy.contactRequests.autoAccept == .rules && policy.contactRequests.allowNames == ["测试联系人A"] && policy.contactRequests.groupDefaultMembers == ["同事A"] && policy.contactRequests.maxAcceptsPerHour == 5)
        #expect(try SendPolicy.load(from: URL(fileURLWithPath: file)).contactRequests.autoGroup == .perPerson)
        #expect(throws: (any Error).self) { try PolicyRequestsCommand.parse(["--auto-accept", "always"]).validate() }
        #expect(PolicyCommand.configuration.subcommands.compactMap { $0.configuration.commandName } == ["list", "allow", "deny", "requests", "remote", "all", "reads", "phones", "hosts"])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func hostsSubcommandWritesSendFilePolicy() throws {
        let file = tempFile()
        try PolicyHostsCommand.parse(["--file", file, "--allow", "cdn.example", ".aliyuncs.com", "--max-bytes", "1024"]).run()
        var policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(policy.sendFile.allowedHosts == ["cdn.example", ".aliyuncs.com"] && policy.sendFile.maxBytes == 1024)
        try PolicyHostsCommand.parse(["--file", file, "--deny", "cdn.example"]).run()
        policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(policy.sendFile.allowedHosts == [".aliyuncs.com"])
        #expect(throws: (any Error).self) { try PolicyHostsCommand.parse(["--file", file]).validate() }
    }
}

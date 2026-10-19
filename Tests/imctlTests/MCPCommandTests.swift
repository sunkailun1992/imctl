import ArgumentParser
import Foundation
import Testing
@testable import imctl

@Suite("imctl mcp")
struct MCPCommandTests {
    @Test func mcpHasServeConfigInstallWithServeAsDefault() throws {
        let names = MCPCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names == ["serve", "config", "install"])
        #expect(MCPCommand.configuration.defaultSubcommand == MCPServeCommand.self)
        let serve = try MCPServeCommand.parse([])
        #expect(serve.socket.hasSuffix("/run/imctl.sock") && serve.timeout == 120)
        #expect(throws: (any Error).self) { try MCPInstallCommand.parse([]) }   // at least one target
        let install = try MCPInstallCommand.parse(["--claude-code", "--codex", "--skills", "--dry-run"])
        #expect(install.claudeCode && install.codex && install.skills && install.dryRun && install.scope == "user")
    }

    @Test func agentConfigurationIsPureTextBuiltFromTheExecutablePath() {
        let exe = "/Users/x/Applications/imctl.app/Contents/MacOS/imctl"
        #expect(AgentIntegration.claudeAddCommand(executable: exe) == ["claude", "mcp", "add", "--scope", "user", "imctl", "--", exe, "mcp", "serve"])
        let block = AgentIntegration.codexBlock(executable: exe)
        #expect(block.hasPrefix("[mcp_servers.imctl]\n") && block.contains("command = \"\(exe)\"") && block.contains("args = [\"mcp\", \"serve\"]"))
        let first = AgentIntegration.mergeCodex(config: "[mcp_servers.other]\ncommand = \"x\"", executable: exe)
        #expect(first.changed && first.text.hasPrefix("[mcp_servers.other]\ncommand = \"x\"\n\n[mcp_servers.imctl]\n"))
        let again = AgentIntegration.mergeCodex(config: first.text, executable: exe)
        #expect(!again.changed && again.text == first.text)
        #expect(AgentIntegration.mergeCodex(config: "", executable: exe).text == block)
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(AgentIntegration.skillTargets(home: home).map(\.url.path) == ["/Users/x/.claude/skills/imctl/SKILL.md", "/Users/x/.codex/skills/imctl/SKILL.md"])
        #expect(AgentIntegration.codexConfig(home: home).path == "/Users/x/.codex/config.toml")
        #expect(AgentIntegration.claudeExecutable(environment: ["PATH": "/a:/b"], home: home, exists: { $0 == "/b/claude" }) == "/b/claude")
        #expect(AgentIntegration.claudeExecutable(environment: [:], home: home, exists: { _ in false }) == nil)
    }

    @Test func skillIsFoundInTheBundleOrTheRepo() {
        let bundle = URL(fileURLWithPath: "/tmp/x.app/Contents/Resources")
        #expect(AgentIntegration.skillSource(resources: bundle, executable: nil, exists: { $0.path.hasPrefix("/tmp/x.app") })?.path == "/tmp/x.app/Contents/Resources/agents/skills/imctl/SKILL.md")
        let dev = URL(fileURLWithPath: "/repo/.build/debug/imctl")
        #expect(AgentIntegration.skillSource(resources: nil, executable: dev, exists: { $0.path == "/repo/docs/agents/skills/imctl/SKILL.md" })?.path == "/repo/docs/agents/skills/imctl/SKILL.md")
        #expect(AgentIntegration.skillSource(resources: nil, executable: dev, exists: { _ in false }) == nil)
        // the real skill file ships with the repo and has the frontmatter Claude Code / Codex read
        let real = AgentIntegration.skillSource(resources: nil, executable: URL(fileURLWithPath: #filePath))
        let text = real.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        #expect(text.hasPrefix("---\nname: imctl\ndescription: ") && text.contains("idempotencyKey"))
    }
}

import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("Agent registration inspector")
struct AgentRegistrationTests {
    func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func claudeCommandIsReadFromTheUserScopeOnly() throws {
        let json = #"{"oauthAccount":{"token":"SECRET"},"mcpServers":{"other":{"command":"/bin/x","env":{"KEY":"SECRET"}},"imctl":{"type":"stdio","command":"/Apps/imctl","args":["mcp","serve"]}}}"#
        #expect(AgentRegistrationInspector.claudeCommand(in: Data(json.utf8)) == "/Apps/imctl")
        #expect(AgentRegistrationInspector.claudeCommand(in: Data(#"{"mcpServers":{}}"#.utf8)) == nil)
        #expect(AgentRegistrationInspector.claudeCommand(in: Data("not json".utf8)) == nil)
    }

    @Test func codexCommandIsReadFromItsOwnTable() {
        let toml = """
        model = "x"
        [mcp_servers.other]
        command = "/bin/other"
        [mcp_servers.imctl]
        enabled = true
        command = "/Apps/imctl"
        args = ["mcp", "serve"]
        [profiles.y]
        command = "/bin/never"
        """
        #expect(AgentRegistrationInspector.codexCommand(in: toml) == "/Apps/imctl")
        #expect(AgentRegistrationInspector.codexCommand(in: "[mcp_servers.other]\ncommand = \"/bin/other\"\n") == nil)
    }

    @Test func skillsCompareWithTheBundledCopy() throws {
        let dir = try home()
        let bundled = dir.appendingPathComponent("bundled.md"); try Data("v2".utf8).write(to: bundled)
        let target = dir.appendingPathComponent("SKILL.md")
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .missing)
        try Data("v1".utf8).write(to: target)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .stale)
        try Data("v2".utf8).write(to: target)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .current)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: nil) == .unknown)
    }

    @Test func inspectCombinesBothSides() throws {
        let dir = try home()
        let cli = dir.appendingPathComponent("imctl")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let link = dir.appendingPathComponent("imctl-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        try Data(#"{"mcpServers":{"imctl":{"command":"\#(link.path)"}}}"#.utf8).write(to: AgentPaths.claudeConfig(home: dir))
        let bundled = dir.appendingPathComponent("bundled.md"); try Data("skill".utf8).write(to: bundled)
        let claudeSkill = AgentPaths.skillTargets(home: dir)[0].url
        try FileManager.default.createDirectory(at: claudeSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: claudeSkill)
        let agents = AgentRegistrationInspector(home: dir, cliPath: cli.path, bundledSkill: bundled).inspect()
        #expect(agents.claude == ReadinessFacts.Agent(registered: true, commandMatches: true, skill: .current))
        #expect(agents.codex == ReadinessFacts.Agent())
        #expect(agents.cliPresent)
    }
}

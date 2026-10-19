import ControlCore
import Foundation

/// Where Claude Code and Codex keep their MCP registration and skills (B10 paths; shared with the daemon in B52).
public enum AgentPaths {
    public static let serverName = "imctl"
    public static let skillRelativePath = "agents/skills/imctl/SKILL.md"

    /// Claude Code keeps user-scope MCP servers in `~/.claude.json` → `mcpServers`.
    public static func claudeConfig(home: URL) -> URL { home.appendingPathComponent(".claude.json") }
    public static func codexConfig(home: URL) -> URL { home.appendingPathComponent(".codex/config.toml") }
    public static func skillTargets(home: URL) -> [(agent: String, url: URL)] {
        [("claude-code", home.appendingPathComponent(".claude/skills/imctl/SKILL.md")),
         ("codex", home.appendingPathComponent(".codex/skills/imctl/SKILL.md"))]
    }
}

/// Reads — never writes — how the two agents registered `imctl` (B52 readiness). Only the `imctl` entry's
/// command path is extracted: both files hold other servers and credentials, which are never read out.
public struct AgentRegistrationInspector {
    public var home: URL
    /// The CLI the agents should launch: the bundle's `imctl`.
    public var cliPath: String
    /// The bundle's SKILL.md; nil outside an app bundle (then skills are `unknown`).
    public var bundledSkill: URL?

    public init(home: URL, cliPath: String, bundledSkill: URL?) {
        self.home = home; self.cliPath = cliPath; self.bundledSkill = bundledSkill
    }

    public func inspect() -> ReadinessFacts.Agents {
        let claude = (try? Data(contentsOf: AgentPaths.claudeConfig(home: home))).flatMap(Self.claudeCommand(in:))
        let codex = (try? String(contentsOf: AgentPaths.codexConfig(home: home), encoding: .utf8)).flatMap(Self.codexCommand(in:))
        let targets = AgentPaths.skillTargets(home: home)
        return ReadinessFacts.Agents(claude: agent(command: claude, skill: targets[0].url),
                                     codex: agent(command: codex, skill: targets[1].url),
                                     cliPresent: FileManager.default.isExecutableFile(atPath: cliPath))
    }

    func agent(command: String?, skill: URL) -> ReadinessFacts.Agent {
        guard let command else { return ReadinessFacts.Agent() }
        return ReadinessFacts.Agent(registered: true, commandMatches: Self.samePath(command, cliPath),
                                    skill: Self.skillState(target: skill, bundled: bundledSkill))
    }

    static func claudeCommand(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[AgentPaths.serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// `command = "…"` inside the `[mcp_servers.imctl]` table (the form `imctl mcp install --codex` writes).
    static func codexCommand(in text: String) -> String? {
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTable = line == "[mcp_servers.\(AgentPaths.serverName)]"; continue }
            guard inTable, line.hasPrefix("command") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func skillState(target: URL, bundled: URL?) -> ReadinessFacts.SkillState {
        guard let installed = try? Data(contentsOf: target) else { return .missing }
        guard let bundled, let reference = try? Data(contentsOf: bundled) else { return .unknown }
        return installed == reference ? .current : .stale
    }
}

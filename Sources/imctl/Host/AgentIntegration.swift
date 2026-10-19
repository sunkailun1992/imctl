import Foundation
import MCPTransport

/// How a coding agent on this Mac reaches the daemon (B10): Claude Code and
/// Codex both speak MCP over stdio, so each gets `<this binary> mcp serve` as
/// an MCP server. Everything here is pure text; `MCPInstallCommand` does the
/// writing.
enum AgentIntegration {
    static let serverName = AgentPaths.serverName

    /// The absolute path agents will launch: this very binary, symlinks resolved.
    static func executable(arguments: [String] = CommandLine.arguments, bundle: URL? = Bundle.main.executableURL) -> String {
        let raw = bundle ?? URL(fileURLWithPath: arguments.first ?? "imctl")
        return raw.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func serveArguments() -> [String] { ["mcp", "serve"] }

    /// `claude mcp add --scope user imctl -- <exe> mcp serve`
    static func claudeAddCommand(executable: String, scope: String = "user") -> [String] {
        ["claude", "mcp", "add", "--scope", scope, serverName, "--", executable] + serveArguments()
    }

    /// The `[mcp_servers.imctl]` table for `~/.codex/config.toml`.
    static func codexBlock(executable: String) -> String {
        """
        [mcp_servers.\(serverName)]
        enabled = true
        command = "\(executable)"
        args = ["mcp", "serve"]
        startup_timeout_sec = 30

        """
    }

    /// Appends the table unless the file already has one; the rest of the file is untouched.
    static func mergeCodex(config: String, executable: String) -> (text: String, changed: Bool) {
        if config.contains("[mcp_servers.\(serverName)]") { return (config, false) }
        var text = config
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += codexBlock(executable: executable)
        return (text, true)
    }

    static let skillRelativePath = AgentPaths.skillRelativePath

    /// The bundled skill (`Contents/Resources/agents/skills/imctl/SKILL.md`) or, for a development
    /// binary under `<repo>/.build`, the repo's `docs/agents/skills/imctl/SKILL.md`.
    static func skillSource(resources: URL? = Bundle.main.resourceURL, executable: URL? = Bundle.main.executableURL,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        if let bundled = resources?.appendingPathComponent(skillRelativePath), exists(bundled) { return bundled }
        var dir = executable?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("docs/" + skillRelativePath)
            if exists(candidate) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Where Claude Code and Codex look for skills.
    static func skillTargets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(agent: String, url: URL)] {
        AgentPaths.skillTargets(home: home)
    }

    static func codexConfig(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AgentPaths.codexConfig(home: home)
    }

    /// `claude` on PATH or in its usual homes; nil when Claude Code is not installed.
    static func claudeExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        var candidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        candidates += [home.appendingPathComponent(".claude/local/claude").path, "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        return candidates.first(where: exists)
    }
}

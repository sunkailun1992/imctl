import ArgumentParser
import ControlCore
import Foundation
import MCPTransport

/// B10: coding agents (Claude Code, Codex) drive the client through the same
/// daemon as Java and the console — `mcp serve` is a stdio MCP bridge to the
/// daemon's socket; `config` / `install` wire it into the agents.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "MCP for coding agents (Claude Code, Codex): a stdio bridge to the running imctld, plus the agent-side configuration.",
        subcommands: [MCPServeCommand.self, MCPConfigCommand.self, MCPInstallCommand.self],
        defaultSubcommand: MCPServeCommand.self
    )
}

struct MCPServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Serve MCP on stdin/stdout; every tool call is forwarded to the daemon's Unix socket (one executor, one policy, one event log).")

    @Option(help: "Unix socket served by `imctld run --socket`.") var socket: String = IMCTLPaths.socket.path
    @Option(help: "Seconds to wait for one daemon reply (a send can take ~12 s, a 通讯录 walk longer).") var timeout: Double = 120

    func run() throws {
        let proxy = MCPProxy(client: UnixSocketClient(path: socket, timeout: timeout))
        let server = StdioServer(handler: proxy)
        server.log = { FileHandle.standardError.write(Data(("imctl mcp: " + $0 + "\n").utf8)) }
        server.serve()
    }
}

struct MCPConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Print the Claude Code command and the Codex config.toml block that register this binary as an MCP server.")

    @Option(help: "Claude Code scope: user (default) | project | local.") var scope: String = "user"

    func run() throws {
        let exe = AgentIntegration.executable()
        print("# Claude Code (run once; `claude mcp list` shows it, /mcp inside a session checks it):")
        print(AgentIntegration.claudeAddCommand(executable: exe, scope: scope).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        print("")
        print("# Codex: append to \(AgentIntegration.codexConfig().path)")
        print(AgentIntegration.codexBlock(executable: exe), terminator: "")
        print("# Skills (workflow + safety rules for the agent): imctl mcp install --skills")
        print("# Or everything at once: imctl mcp install --claude-code --codex --skills")
    }
}

struct MCPInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Register this binary with Claude Code (`claude mcp add`) and/or Codex (~/.codex/config.toml), and copy the imctl skill into both agents' skill folders.")

    @Flag(name: .customLong("claude-code"), help: "Run `claude mcp add --scope <scope> imctl -- <this binary> mcp serve`.") var claudeCode = false
    @Flag(help: "Append [mcp_servers.imctl] to ~/.codex/config.toml (skipped when present).") var codex = false
    @Flag(help: "Copy SKILL.md to ~/.claude/skills/imctl/ and ~/.codex/skills/imctl/.") var skills = false
    @Option(help: "Claude Code scope: user (default) | project | local.") var scope: String = "user"
    @Flag(name: .customLong("dry-run"), help: "Print what would change; write nothing.") var dryRun = false

    func validate() throws {
        if !claudeCode, !codex, !skills { throw ValidationError("pass at least one of --claude-code / --codex / --skills") }
    }

    func run() throws {
        let exe = AgentIntegration.executable()
        if claudeCode {
            let command = AgentIntegration.claudeAddCommand(executable: exe, scope: scope)
            if dryRun {
                print("would run: \(command.joined(separator: " "))")
            } else if let claude = AgentIntegration.claudeExecutable() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claude)
                process.arguments = Array(command.dropFirst())
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                try process.run()
                // drain before waiting: the claude CLI prints a lot of warnings, and a full pipe never exits (live 2026-09-16: hung 10 min)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.contains("[mcp-sdk]") }
                print("claude mcp add (exit \(process.terminationStatus)): \(lines.suffix(3).joined(separator: " | "))")
                if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
            } else {
                print("claude CLI not found on PATH; run this yourself:\n  \(command.joined(separator: " "))")
            }
        }
        if codex {
            let url = AgentIntegration.codexConfig()
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let merged = AgentIntegration.mergeCodex(config: existing, executable: exe)
            if !merged.changed {
                print("codex: \(url.path) already has [mcp_servers.imctl]")
            } else if dryRun {
                print("would append to \(url.path):\n\(AgentIntegration.codexBlock(executable: exe))")
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // keep the file's mode: config.toml can hold tokens and is often 0600
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
                try merged.text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                print("codex: appended [mcp_servers.imctl] to \(url.path) (mode \(String(mode, radix: 8)) kept)")
            }
        }
        if skills {
            guard let source = AgentIntegration.skillSource() else { throw ValidationError("SKILL.md not found next to this binary (bundle Resources/agents or repo docs/agents)") }
            for target in AgentIntegration.skillTargets() {
                if dryRun { print("would copy \(source.path) → \(target.url.path)"); continue }
                try FileManager.default.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.url.path) { try FileManager.default.removeItem(at: target.url) }
                try FileManager.default.copyItem(at: source, to: target.url)
                print("\(target.agent): skill installed at \(target.url.path)")
            }
        }
    }
}

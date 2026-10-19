import ArgumentParser
import Testing
@testable import imctl

@Suite("Command parsing")
struct CommandParsingTests {
    @Test func rootListsSubcommands() {
        let names = IMCTL.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names == ["version", "permission", "env", "dump-tree", "probe", "status", "call", "enroll", "mqtt", "agent", "policy", "identity", "wecom", "oss", "vision", "mcp", "setup", "doctor"])
    }

    @Test func dumpTreeDefaultsAreReadOnlyAndRedacted() throws {
        let cmd = try DumpTreeCommand.parse([])
        #expect(cmd.bundle == "com.tencent.WeWorkMac")
        #expect(cmd.depth == 12)
        #expect(cmd.raw == false)
        #expect(cmd.output == nil)
        #expect(cmd.keep == ["文件传输助手"])
        #expect(cmd.root == .app)
        #expect(try DumpTreeCommand.parse(["--root", "main-window"]).root == .mainWindow)
    }

    @Test func rawOutputMustUseRawSuffix() {
        #expect(throws: (any Error).self) { try DumpTreeCommand.parse(["--raw", "--output", "x.json"]).validate() }
        #expect(throws: Never.self) { try DumpTreeCommand.parse(["--raw", "--output", "x.raw.json"]).validate() }
    }

    @Test func envDefaultsToWeCom() throws {
        #expect(try EnvCommand.parse([]).bundle == "com.tencent.WeWorkMac")
    }

    @Test func probeSubcommandsIncludeAddMembers() {
        let names = ProbeCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names.contains("addmembers"))
    }
}

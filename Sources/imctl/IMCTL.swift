import ArgumentParser
import ControlCore

@main
struct IMCTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imctl",
        abstract: "IM Control Protocol controller for macOS. Every command here is read-only.",
        version: IMCTLVersion.string,
        subcommands: [VersionCommand.self, PermissionCommand.self, EnvCommand.self, DumpTreeCommand.self, ProbeCommand.self, StatusCommand.self, CallCommand.self, EnrollCommand.self, MQTTCommand.self, AgentCommand.self, PolicyCommand.self, IdentityCommand.self, WeComCommand.self, OSSCommand.self, CloudVisionCommand.self, MCPCommand.self, SetupCommand.self, DoctorCommand.self]
    )
}

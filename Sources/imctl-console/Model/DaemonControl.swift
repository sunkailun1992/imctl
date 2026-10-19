import ControlCore
import Foundation

/// launchd-side operations, delegated to `imctl agent …` and `launchctl`.
/// Nothing here touches TCC: the Accessibility grant stays a human click.
struct DaemonControl {
    var cli: CLIRunner
    var label = "com.sunkailun.imctl"

    struct AgentStatus: Codable, Equatable {
        var loaded: Bool
        var state: String?
        var pid: Int?
        var plistPresent: Bool?
        var lastExitCode: String?
        var logDirectory: String?
    }

    static func installArguments(mqttEnrolled: Bool, socket: String = IMCTLPaths.socket.path) -> [String] {
        var arguments = ["agent", "install", "--socket", socket]
        if mqttEnrolled { arguments.append("--mqtt") }
        return arguments
    }

    static func kickstartArguments(label: String) -> [String] { ["kickstart", "-k", "gui/\(getuid())/\(label)"] }

    func status() throws -> AgentStatus {
        let result = try cli.run(["agent", "status", "--json"])
        return try JSONDecoder().decode(AgentStatus.self, from: Data(result.output.utf8))
    }

    func install(mqttEnrolled: Bool) throws -> CLIRunner.Result { try cli.run(Self.installArguments(mqttEnrolled: mqttEnrolled)) }
    func uninstall() throws -> CLIRunner.Result { try cli.run(["agent", "uninstall"]) }
    func restart() throws -> CLIRunner.Result {
        try CLIRunner(executable: URL(fileURLWithPath: "/bin/launchctl")).run(Self.kickstartArguments(label: label))
    }
}

import Foundation

/// Point-in-time view of the host as it matters to the controller: TCC
/// state, clamshell/power/lock/display, the IM client, and our own signing
/// identity. Pure data so rendering and JSON are unit-testable; filled by
/// `HostProbe`.
struct HostEnvironment: Codable, Equatable {
    var timestamp: String
    var macOSVersion: String
    var architecture: String
    var accessibilityTrusted: Bool
    var clamshellClosed: Bool?
    var sleepDisabled: Bool?
    var onACPower: Bool?
    var screenLocked: Bool?
    var displayAsleep: Bool?
    var displayCount: Int
    var client: ClientInfo?
    var process: ProcessInfoSnapshot

    struct ClientInfo: Codable, Equatable {
        var bundleID: String
        var version: String?
        var pid: Int32
        var hidden: Bool
        var active: Bool
    }

    struct ProcessInfoSnapshot: Codable, Equatable {
        var executablePath: String
        var signingIdentifier: String?
        var signingTeam: String?
        var signed: Bool
    }

    func render() -> String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "unknown" }
        var lines: [String] = []
        lines.append("timestamp: \(timestamp)")
        lines.append("macos: \(macOSVersion) \(architecture)")
        lines.append("accessibility_trusted: \(flag(accessibilityTrusted))")
        lines.append("clamshell_closed: \(flag(clamshellClosed))")
        lines.append("sleep_disabled: \(flag(sleepDisabled))")
        lines.append("on_ac_power: \(flag(onACPower))")
        lines.append("screen_locked: \(flag(screenLocked))")
        lines.append("display_asleep: \(flag(displayAsleep))")
        lines.append("display_count: \(displayCount)")
        if let c = client {
            lines.append("client: \(c.bundleID) \(c.version ?? "?") pid=\(c.pid) hidden=\(c.hidden) active=\(c.active)")
        } else {
            lines.append("client: not running")
        }
        lines.append("executable: \(process.executablePath)")
        lines.append("signing: \(process.signingIdentifier ?? (process.signed ? "<unnamed>" : "unsigned")) (team: \(process.signingTeam ?? "-"))")
        return lines.joined(separator: "\n")
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

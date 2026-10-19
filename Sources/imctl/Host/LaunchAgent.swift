import Foundation

/// What `imctl agent install` renders: a per-user launchd job that keeps
/// `imctld` running inside the GUI session (`LimitLoadToSessionType = Aqua`,
/// which is what keeps Accessibility/TCC usable). Rendering is pure so it can
/// be tested and shown with `--dry-run`; nothing here touches launchd.
struct LaunchAgentSpec: Equatable {
    static let defaultLabel = "com.sunkailun.imctl"

    var label = LaunchAgentSpec.defaultLabel
    var daemonPath: String
    var arguments: [String]
    var logDirectory: String

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// `~/Library/Logs/imctl`
    static var defaultLogDirectory: URL { homeDirectory.appendingPathComponent("Library/Logs/imctl", isDirectory: true) }

    /// `~/Library/LaunchAgents/<label>.plist`
    static func defaultPlistPath(label: String = defaultLabel) -> URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true).appendingPathComponent("\(label).plist")
    }

    /// The `imctld` next to the running `imctl` binary: the pair that
    /// `scripts/build-signed.sh` signed with the identifier TCC already trusts.
    static var defaultDaemonPath: String {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "imctl").resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().appendingPathComponent("imctld").path
    }

    var stdoutPath: String { logDirectory + "/imctld.out.log" }
    var stderrPath: String { logDirectory + "/imctld.log" }

    func plistObject() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [daemonPath] + arguments,
            "RunAtLoad": true,
            // Restart after a crash or a non-zero exit; a clean exit (launchctl bootout, SIGTERM handled) stays down.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            // Not a background-priority job: AX polling and command latency must not be throttled.
            "ProcessType": "Interactive",
            // Only in the logged-in GUI session; Accessibility is unavailable elsewhere.
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
            "EnvironmentVariables": ["IMCTL_LAUNCHD": "1"],
        ]
    }

    func plistXML() throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: plistObject(), format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Parsed `launchctl print gui/<uid>/<label>`.
struct LaunchctlStatus: Equatable {
    var loaded: Bool
    var state: String?
    var pid: Int?
    var lastExitCode: String?

    static func parse(_ text: String) -> LaunchctlStatus {
        guard text.contains(" = {") else { return LaunchctlStatus(loaded: false, state: nil, pid: nil, lastExitCode: nil) }
        var status = LaunchctlStatus(loaded: true, state: nil, pid: nil, lastExitCode: nil)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = ") {
                status.state = String(line.dropFirst("state = ".count))
            } else if line.hasPrefix("pid = ") {
                status.pid = Int(line.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("last exit code = ") {
                status.lastExitCode = String(line.dropFirst("last exit code = ".count))
            }
        }
        return status
    }
}

/// Thin launchctl runner; tests replace `run`.
enum Launchctl {
    static var run: ([String]) throws -> (status: Int32, output: String) = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static var domain: String { "gui/\(getuid())" }
    static func serviceTarget(_ label: String) -> String { "\(domain)/\(label)" }

    /// Pause between launchd calls; tests replace it with a no-op.
    static var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    static func isLoaded(_ label: String) -> Bool {
        (try? run(["print", serviceTarget(label)])).map { LaunchctlStatus.parse($0.output).loaded } ?? false
    }
}

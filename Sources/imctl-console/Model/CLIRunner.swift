import Foundation

/// Runs the sibling `imctl` CLI (same bundle, same signing identity). Every
/// change the console makes to launchd or policy.json goes through the CLI,
/// so the console can never diverge from what the terminal would do.
struct CLIRunner {
    var executable: URL

    struct Result: Equatable {
        var status: Int32
        var output: String
    }

    /// `imctl` next to this executable (imctl.app/Contents/MacOS); `IMCTL_CLI` overrides in development.
    static func sibling() -> CLIRunner {
        if let override = ProcessInfo.processInfo.environment["IMCTL_CLI"] { return CLIRunner(executable: URL(fileURLWithPath: override)) }
        let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        return CLIRunner(executable: me.deletingLastPathComponent().appendingPathComponent("imctl"))
    }

    func run(_ arguments: [String], stdin: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

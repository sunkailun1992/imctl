import ArgumentParser
import Foundation

struct ProbeWatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch the WeCom window for changes: polling diff and/or AXObserver notifications (G0-4 / G0-5). Read-only."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "How long to watch; 0 = one poll.") var seconds: Double = 60
    @Option(help: "Polling interval in seconds.") var interval: Double = 1.0
    @Option(help: "both | poll | observer") var mode: String = "both"
    @Option(help: "Append JSONL events here (redacted unless --no-redact).") var log: String?

    func validate() throws {
        guard WatchRunner.Mode(rawValue: mode) != nil else { throw ValidationError("--mode must be both, poll or observer") }
        guard interval > 0 else { throw ValidationError("--interval must be > 0") }
    }

    func runWatch() throws -> WatchSummary {
        let runner = try WatchRunner(options: options, seconds: seconds, interval: interval,
                                     mode: WatchRunner.Mode(rawValue: mode) ?? .both, log: log)
        return try runner.run()
    }

    func run() throws {
        let summary = try runWatch()
        print(options.json ? try ProbeSession.encode(summary) : summary.render())
    }
}

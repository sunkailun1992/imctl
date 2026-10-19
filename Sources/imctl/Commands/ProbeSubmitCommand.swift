import AppKit
import ArgumentParser
import AXKit
import ControlCore
import Foundation
import WeComAdapter

extension SubmitStrategy: ExpressibleByArgument {}

struct SubmitReport: Codable {
    var staleCheckpoints: [SubmitCheckpoint]
    var before: ClientState
    var outcomes: [SubmitOutcome]
    var after: ClientState
    var outcome: SubmitOutcome? { outcomes.last }
}

struct ProbeSubmitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Phase 1: compose then attempt ONE submit strategy on the allowlisted conversation; checkpoint before the irreversible step; confirm by outbound bubble."
    )

    @OptionGroup var options: ProbeOptions
    @Option(name: .customLong("allow-submit"), help: "Text to send. Target must be the active, allowlisted conversation.")
    var allowSubmit: String
    @Option(help: "enter | ctrl-enter | send-button | context-menu | ax-confirm | newline") var strategy: SubmitStrategy = .enterKey
    @Flag(help: "Try every strategy in SubmitStrategy.autoOrder until one succeeds (or ends unknown).") var auto = false
    @Flag(help: "Activate the client (NSRunningApplication.activate, not synthetic input) before submitting and restore the previous app afterwards.")
    var activate = false
    @Option(help: "Seconds to wait for the outbound bubble.") var timeout: Double = 10
    @Option(name: .customLong("checkpoint-dir"), help: "Where pending/finished checkpoints live.") var checkpointDir: String?

    func collect() throws -> SubmitReport {
        let dir = checkpointDir.map { URL(fileURLWithPath: $0) } ?? FileCheckpointStore.defaultDirectory()
        let store = try FileCheckpointStore(directory: dir)

        // Anything still pending from a previous run is unknown forever; never re-run it.
        var stale: [SubmitCheckpoint] = []
        for var cp in try store.pending() {
            cp.state = .unknown
            cp.reason = "pending checkpoint found at startup"
            try store.write(cp)
            stale.append(cp)
        }

        let reader = try ProbeSession.reader(options)
        let fixture = options.fromFixture != nil
        let before = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        let actions = WeComActions(policy: ActionPolicy(
            allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: [.submit], phase: .phase1
        ))
        let previous = activate && !fixture ? NSWorkspace.shared.frontmostApplication : nil
        if activate, !fixture, let app = AXApp.runningApplication(bundleID: options.bundle) {
            app.activate()
            Thread.sleep(forTimeInterval: 0.8)
        }
        defer {
            if let previous { previous.activate() }
        }
        var outcomes: [SubmitOutcome] = []
        for candidate in (auto ? SubmitStrategy.autoOrder : [strategy]) {
            let outcome = try actions.submit(text: allowSubmit, strategy: candidate, reader: reader, checkpoints: store, timeout: timeout)
            outcomes.append(outcome)
            if outcome.state != .failed { break }
        }
        let after = ClientState.sample(bundleID: options.bundle, fixture: fixture)
        return SubmitReport(staleCheckpoints: stale, before: before, outcomes: outcomes, after: after)
    }

    func run() throws {
        let report = try collect()
        if options.json {
            print(try ProbeSession.encode(report))
            return
        }
        for cp in report.staleCheckpoints {
            print("stale checkpoint \(cp.id) (\(cp.text.count) chars, \(cp.strategy)) -> unknown")
        }
        print("before:  \(report.before.summary)")
        for o in report.outcomes {
            print("submit:  strategy=\(o.strategy) target=\(o.target ?? "-") state=\(o.state.rawValue) latency_ms=\(o.latencyMs.map(String.init) ?? "-") composer_after=\(o.composerAfter)")
            if let e = o.evidence { print("  evidence: \(e)") }
            if let r = o.reason { print("  reason:   \(r)") }
            for (k, v) in o.details.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
            print("  checkpoint: \(o.checkpointID)")
        }
        print("after:   \(report.after.summary)")
    }
}

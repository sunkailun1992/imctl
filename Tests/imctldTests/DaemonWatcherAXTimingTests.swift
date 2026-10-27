import AXKit
import ControlCore
import Foundation
import Testing
@testable import imctld

@Suite("Daemon watcher AX timings")
struct DaemonWatcherAXTimingTests {
    @Test func everyPollIsTimedAndTheStateCarriesTheAXSummary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let statePath = dir.appendingPathComponent("state.json")
        let timings = AXCallTimings()
        let reporter = AXTimingReporter(timings: timings, reportURL: dir.appendingPathComponent("ax-timings.json"), log: { _ in })
        // No such client is running, so the start poll fails; it must still be timed.
        let watcher = DaemonWatcher(store: try ControlStore(path: ":memory:"), bundleID: "com.example.imctl-tests.absent",
                                    backend: FakeAXBackend(root: AXNode(role: AXRole.application)),
                                    interval: 0, observe: false, debounce: 0,
                                    policyProvider: PolicyProvider(url: dir.appendingPathComponent("policy.json")),
                                    statePath: statePath, log: DaemonLog())
        watcher.axReporter = reporter
        watcher.start()
        watcher.stop()

        let scope = try #require(timings.report().scopes.first { $0.name == AXTimingReporter.pollScope })
        #expect(scope.count == 1 && scope.failures == 1)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: statePath)) as? [String: Any])
        let ax = try #require(state["ax"] as? [String: Any])
        #expect(ax["polls"] as? Int == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ax-timings.json").path))
    }
}

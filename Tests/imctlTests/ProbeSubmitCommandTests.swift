import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("probe submit command")
struct ProbeSubmitCommandTests {
    func tempDir() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-probe-submit-\(UUID().uuidString)").path
    }

    @Test func axConfirmOnFixtureFails() throws {
        let cmd = try ProbeSubmitCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--allow-submit", "p1",
                                                "--checkpoint-dir", tempDir(), "--timeout", "0.3"])
        let report = try cmd.collect()
        #expect(report.outcome?.state == .failed)
        #expect(report.staleCheckpoints.isEmpty)
    }

    @Test func stalePendingCheckpointBecomesUnknown() throws {
        let dir = tempDir()
        let store = try FileCheckpointStore(directory: URL(fileURLWithPath: dir))
        let stale = SubmitCheckpoint(target: "文件传输助手", text: "old", strategy: "ax-confirm")
        try store.write(stale)
        let cmd = try ProbeSubmitCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--allow-submit", "p1",
                                                "--checkpoint-dir", dir, "--timeout", "0.3"])
        let report = try cmd.collect()
        #expect(report.staleCheckpoints.map(\.id) == [stale.id])
        #expect(try store.load(id: stale.id)?.state == .unknown)
        #expect(try store.pending().isEmpty)
    }

    @Test func submitRequiresAllowFlag() {
        #expect(throws: (any Error).self) { try ProbeSubmitCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]) }
    }
}

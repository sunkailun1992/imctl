import Foundation
import Testing
@testable import ControlCore

@Suite("SubmitCheckpoint store")
struct SubmitCheckpointTests {
    func tempStore() throws -> FileCheckpointStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-cp-\(UUID().uuidString)/nested")
        return try FileCheckpointStore(directory: dir)
    }

    @Test func writeReadRoundTripAndPendingFilter() throws {
        let store = try tempStore()
        var cp = SubmitCheckpoint(target: "文件传输助手", text: "hi", strategy: "ax-confirm")
        try store.write(cp)
        #expect(try store.load(id: cp.id) == cp)
        #expect(try store.pending().map(\.id) == [cp.id])
        cp.state = .succeeded
        cp.evidence = "row #3"
        try store.write(cp)
        #expect(try store.pending().isEmpty)
        #expect(try store.load(id: cp.id)?.evidence == "row #3")
        #expect(try store.load(id: "nope") == nil)
    }

    @Test func pendingIsSortedByCreation() throws {
        let store = try tempStore()
        var a = SubmitCheckpoint(target: "t", text: "a", strategy: "s"); a.createdAtMs = 2
        var b = SubmitCheckpoint(target: "t", text: "b", strategy: "s"); b.createdAtMs = 1
        try store.write(a); try store.write(b)
        #expect(try store.pending().map(\.text) == ["b", "a"])
    }
}

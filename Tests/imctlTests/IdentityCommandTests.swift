import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("imctl identity")
struct IdentityCommandTests {
    @Test func setListRemove() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-id-\(UUID().uuidString)/imctl.sqlite").path
        try IdentitySetCommand.parse(["--kind", "group", "--id", "wr1", "--title", "imctl测试群", "--db", db]).run()
        try IdentitySetCommand.parse(["--kind", "customer", "--id", "wm1", "--title", "小明·a1b2c3", "--db", db]).run()
        let listed = try IdentityListCommand.parse(["--db", db]).collect()
        #expect(listed.map(\.id) == ["wm1", "wr1"])
        #expect(listed.first { $0.id == "wr1" }?.title == "imctl测试群")
        try IdentityRemoveCommand.parse(["--kind", "group", "--id", "wr1", "--db", db]).run()
        #expect(try IdentityListCommand.parse(["--db", db]).collect().map(\.id) == ["wm1"])
        #expect(throws: (any Error).self) { try IdentitySetCommand.parse(["--kind", "bot", "--id", "x", "--title", "y", "--db", db]) }
    }
}

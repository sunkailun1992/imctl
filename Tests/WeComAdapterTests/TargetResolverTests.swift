import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

struct MapIdentities: IdentityLookup {
    var items: [Identity]
    func identity(kind: IdentityKind, id: String) throws -> Identity? { items.first { $0.kind == kind && $0.id == id } }
    func identities(title: String) throws -> [Identity] { items.filter { $0.title == title } }
}

@Suite("TargetResolver")
struct TargetResolverTests {
    let bridge = MapIdentities(items: [
        Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1),
        Identity(kind: .customer, id: "wm1", title: "小明·a1b2c3", updatedMs: 1),
    ])

    @Test func idsResolveThroughTheBridgeAndTitlesReverseLookUp() throws {
        let r = TargetResolver(identities: bridge)
        #expect(try r.title(for: .chatId("wr1")) == "imctl测试群")
        #expect(try r.title(for: .externalUserId("wm1")) == "小明·a1b2c3")
        #expect(try r.title(for: .title("任意")) == "任意")
        #expect(throws: ControlError.targetNotFound("chatId:nope")) { try r.title(for: .chatId("nope")) }
        #expect(throws: ControlError.targetNotFound("externalUserId:wr1")) { try r.title(for: .externalUserId("wr1")) }
        let byId = try r.resolve(.chatId("wr1"), row: nil)
        #expect(byId == ResolvedTarget(title: "imctl测试群", type: .group, chatId: "wr1"))
        let byTitle = try r.resolve(.title("小明·a1b2c3"), row: nil)
        #expect(byTitle == ResolvedTarget(title: "小明·a1b2c3", type: .customer, externalUserId: "wm1"))
        #expect(try r.resolve(.title("陌生"), row: nil) == ResolvedTarget(title: "陌生"))
    }

    @Test func clientEvidenceWinsOverBridgeKind() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let r = TargetResolver(identities: MapIdentities(items: []))
        let row = try reader.activeConversationRow()
        let resolved = try r.resolve(.title("imctl测试群"), row: row, header: try reader.activeConversationHeader(), messages: try reader.messages())
        #expect(resolved.type == .group && resolved.chatId == nil)
        let customerRow = try #require(try reader.conversations().first { $0.title == "小明·a1b2c3" })
        #expect(try r.resolve(.title("小明·a1b2c3"), row: customerRow).type == .customer)
    }
}

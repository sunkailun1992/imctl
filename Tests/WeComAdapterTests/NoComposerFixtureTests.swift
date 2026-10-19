import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("No-composer fixture")
struct NoComposerFixtureTests {
    @Test func layoutToleratesMissingComposer() throws {
        let reader = try WeComReader(window: try Fixtures.noComposer().rootElement)
        #expect(reader.layout.composer == nil)
        #expect(try reader.composerValue() == nil)
        #expect(try reader.activeConversationTitle() != "文件传输助手")
        let rows = try reader.conversations()
        #expect(rows.count == 8)
        #expect(rows.first { $0.title == "文件传输助手" }?.index == 6)
        let messages = try reader.messages()
        #expect(messages.count == 1)
        #expect(messages[0].text != nil && messages[0].timeLabel == "14:48")
    }

    @Test func selectVerifiesTargetAndReportsMismatchOnFake() throws {
        let fake = try Fixtures.noComposer()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(
            policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation]),
            verifyTimeout: 0.2, verifyInterval: 0.05
        )
        // The fake does not move the active title, so verify_target must fail loudly.
        #expect(throws: ActionError.self) { try actions.selectConversation("文件传输助手", reader: reader) }
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.selectedRows])
    }

    @Test func composeWithoutComposerIsARegionError() throws {
        let fake = try Fixtures.noComposer()
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("文件传输助手"))
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.composeText]))
        #expect(throws: WeComError.region("composer")) { try actions.composeText("x", reader: reader) }
        #expect(fake.recordedSets.isEmpty)
    }
}

@Suite("5.0.11 fresh-launch fixture (no active conversation)")
struct FreshLaunchFixtureTests {
    static func fixture() throws -> FakeAXBackend {
        let url = URL(fileURLWithPath: Fixtures.mainWindowPath()).deletingLastPathComponent().appendingPathComponent("wecom-5.0.11-main-window.json")
        return FakeAXBackend(root: try AXNode.load(from: url))
    }

    @Test func layoutToleratesMissingMessageTableAndReportsNoMessages() throws {
        let reader = try WeComReader(window: try Self.fixture().rootElement)
        #expect(reader.layout.messageTable == nil)
        #expect(try reader.messages().isEmpty)
        #expect(try reader.conversations().count >= 6)
    }

    @Test func submitRefusesWithoutMessageTable() throws {
        let fake = try Self.fixture()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.submit], phase: .phase1))
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-fresh-\(UUID().uuidString)"))
        // Whatever the active title is, the composer/table guard fires before any AX write.
        #expect(throws: (any Error).self) { try actions.submit(text: "x", strategy: .enterKey, reader: reader, checkpoints: cps, timeout: 0.2) }
        #expect(fake.recordedSets.isEmpty)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Media row subtype evidence")
struct MediaTypeTests {
    static func emptyMediaRow(y: CGFloat) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 240), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 240)),
        ])
    }

    static func handler(_ fake: FakeAXBackend) throws -> WeComCommandHandler {
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-type-\(UUID().uuidString)"))
        return WeComCommandHandler(rootProvider: { fake.rootElement },
                                   policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation, .scrollHistory], phase: .phase1),
                                   checkpoints: checkpoints)
    }

    @Test func exactLatestImagePreviewReachesHistoryAndObservedEvent() throws {
        let first = GroupFixture.messageRow(y: 64, text: "hello")
        let fake = GroupFixture.backend(messages: [first])
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        #expect(try engine.poll().isEmpty)

        let preview = try #require(fake.handle(atPath: GroupFixture.groupRowPreviewPath))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("[图片]"))
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        fake.replaceChildren(of: table, with: [first, Self.emptyMediaRow(y: 144)])

        let draft = try #require(try engine.poll().first { $0.kind == .messageObserved })
        #expect(draft.payload["kind"] == "media" && draft.payload["mediaType"] == "image")
        #expect(draft.payload["direction"] == "unknown")

        let history = try Self.handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(history.count == 2 && history[1]["kind"] == "media" && history[1]["mediaType"] == "image")
        #expect(history[1]["messageKey"] == draft.payload["messageKey"])
    }

    @Test func olderAndAmbiguousMediaStayUnknown() throws {
        let fake = GroupFixture.backend(messages: [Self.emptyMediaRow(y: 64), Self.emptyMediaRow(y: 304)])
        let preview = try #require(fake.handle(atPath: GroupFixture.groupRowPreviewPath))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("[图片]"))
        let history = try Self.handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(history.map { $0["mediaType"] } == ["unknown", "image"])

        fake.mutate(preview, attribute: AXAttribute.value, to: .string("[表情]"))
        let noImageProof = try Self.handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(noImageProof.map { $0["mediaType"] } == ["unknown", "unknown"])
    }

    @Test func selectedPreviewCannotClassifyADifferentActiveHeader() throws {
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [Self.emptyMediaRow(y: 64)], headerTitle: "«other»"))
        let preview = try #require(fake.handle(atPath: GroupFixture.groupRowPreviewPath))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("[图片]"))
        let history = try Self.handler(fake).messageHistory(limit: 10, scrollback: false)
        #expect(history.count == 1 && history[0]["kind"] == "media" && history[0]["mediaType"] == "unknown")
    }

    @Test func explicitHistoryUsesVisualEvidenceOnlyForRequestedUnknownMedia() throws {
        let fake = GroupFixture.backend(messages: [Self.emptyMediaRow(y: 64), Self.emptyMediaRow(y: 304)])
        let handler = try Self.handler(fake)
        var requested: [Int] = []
        handler.resolveVisualDirections = { _, rows, positions in
            requested = positions
            for position in positions where rows[position].kind == .media {
                rows[position].direction = .outbound
            }
        }
        let history = try handler.messageHistory(limit: 1, scrollback: false)
        #expect(requested == [1])
        #expect(history.count == 1 && history[0]["direction"] == "outbound")
    }

    @Test func watcherResolvesOnlyAppendedUnknownMediaBeforeMQTTEvent() throws {
        let first = GroupFixture.messageRow(y: 64, text: "hello")
        let fake = GroupFixture.backend(messages: [first])
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        var calls: [[Int]] = []
        engine.resolveVisualDirections = { _, rows, positions in
            calls.append(positions)
            for position in positions where rows[position].kind == .media {
                rows[position].direction = .inbound
            }
        }
        #expect(try engine.poll().isEmpty)
        #expect(calls.isEmpty) // existing history is a baseline, not a new MQTT message

        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        fake.replaceChildren(of: table, with: [first, Self.emptyMediaRow(y: 144)])
        let event = try #require(try engine.poll().first { $0.kind == .messageObserved })
        #expect(calls == [[1]])
        #expect(event.payload["kind"] == "media")
        #expect(event.payload["direction"] == "inbound" && event.payload["origin"] == "peer")
        _ = try engine.poll(forceMessages: true)
        #expect(calls == [[1]]) // no capture on repeated polling
        #expect(engine.previous?.messages.last?.direction == "inbound")

        // Re-reading the old AX media row yields unknown again; the resolved
        // direction must survive, or a later history prepend looks like an
        // appended row and fabricates message.observed events.
        let older = GroupFixture.messageRow(y: 16, text: "older")
        fake.replaceChildren(of: table, with: [older, first, Self.emptyMediaRow(y: 144)])
        #expect(try engine.poll().isEmpty)
        #expect(engine.previous?.messages.last?.direction == "inbound")
        #expect(calls == [[1]])
    }

    @Test func firstMediaInPreviouslyEmptyConversationAlsoGetsVisualDirection() throws {
        let fake = GroupFixture.backend(messages: [])
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.resolveVisualDirections = { _, rows, positions in
            for position in positions where rows[position].kind == .media { rows[position].direction = .outbound }
        }
        #expect(try engine.poll().isEmpty)
        let table = try #require(fake.handle(atPath: GroupFixture.messageTablePath))
        fake.replaceChildren(of: table, with: [Self.emptyMediaRow(y: 144)])
        let event = try #require(try engine.poll().first { $0.kind == .messageObserved })
        #expect(event.payload["direction"] == "outbound" && event.payload["origin"] == "other")
    }
}

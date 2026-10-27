import AXKit
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter
@testable import imctl

@Suite("probe ax-timing")
struct ProbeAXTimingTests {
    private static func batchingFixture() throws -> FakeAXBackend {
        let fake = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())))
        fake.batchesReads = true
        return fake
    }

    @Test func fixtureRunReportsBothModesAndEquality() throws {
        let fake = try Self.batchingFixture()
        let result = try AXTimingProbe.run(rounds: 2, base: fake, root: { AXElement(handle: fake.rootHandle, backend: $0) })
        #expect(result.rounds == 2 && result.messageTable)
        #expect(result.single.mode == "single" && result.batch.mode == "batch")
        #expect(result.single.locateMs.count == 2 && result.single.conversationsMs.count == 2 && result.single.messagesMs.count == 2)
        #expect(result.batch.conversationsMs.count == 2)
        #expect(result.batch.calls < result.single.calls)
        #expect(result.conversationsEqual && result.messagesEqual)
        #expect(result.conversationDiffs == 0 && result.messageDiffs == 0)
        #expect(result.batch.fallbacks == 0)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func aBackendThatCannotBatchShowsFallbacks() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())))
        fake.batchesReads = false   // asserts the single-read path, whatever IMCTL_FAKE_BATCH says
        let result = try AXTimingProbe.run(rounds: 1, base: fake, root: { AXElement(handle: fake.rootHandle, backend: $0) })
        #expect(result.batch.fallbacks > 0)
        #expect(result.conversationsEqual && result.messagesEqual)
    }

    /// Every text of the recording: none of it may reach the report.
    private static func texts(_ node: AXNode) -> [String] {
        var out = [node.title, node.description, node.help, node.placeholder, node.value.flatMap { if case .string(let s) = $0 { s } else { nil } }]
            .compactMap { $0 }
        for child in node.children { out += texts(child) }
        return out
    }

    @Test func renderedReportHasNoText() throws {
        let fake = try Self.batchingFixture()
        let result = try AXTimingProbe.run(rounds: 1, base: fake, root: { AXElement(handle: fake.rootHandle, backend: $0) })
        let rendered = AXTimingProbe.render(result) + (try ProbeSession.encode(result))
        let tree = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let candidates = Set(Self.texts(tree).filter { text in
            text.count >= 3 && text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        })
        #expect(!candidates.isEmpty)
        for text in candidates { #expect(!rendered.contains(text), "\(text) leaked") }
    }

    /// A message that arrives between the passes is the client changing, not the
    /// two read paths disagreeing: the batched parse matches the later single pass.
    @Test func aClientChangeBetweenPassesIsNoiseNotADiff() throws {
        let fake = try Self.batchingFixture()
        let first = try #require(try WeComReader(window: fake.rootElement).conversations().first)
        let title = try #require(first.title)
        let text = try #require(AXElement(handle: first.handle, backend: fake).descendants().first { (try? $0.valueString()) == title })
        var roots = 0
        let result = try AXTimingProbe.run(rounds: 1, base: fake, root: { backend in
            roots += 1
            if roots == 2 { fake.mutate(text.handle, attribute: AXAttribute.value, to: .string("changed between passes")) }
            return AXElement(handle: fake.rootHandle, backend: backend)
        })
        #expect(result.conversationsEqual && result.conversationDiffs == 0)
        #expect(result.conversationNoise == 1)
        #expect(result.single.conversationsMs.count == 1)
    }

    /// The batched path itself reading something else is still a diff.
    @Test func aRealParseDifferenceIsCounted() throws {
        let fake = try Self.batchingFixture()
        let first = try #require(try WeComReader(window: fake.rootElement).conversations().first)
        let title = try #require(first.title)
        let text = try #require(AXElement(handle: first.handle, backend: fake).descendants().first { (try? $0.valueString()) == title })
        let skewed = BatchSkewBackend(fake: fake, skewed: text.handle)
        let result = try AXTimingProbe.run(rounds: 1, base: skewed, root: { AXElement(handle: fake.rootHandle, backend: $0) })
        #expect(!result.conversationsEqual && result.conversationDiffs == 1)
        #expect(result.conversationNoise == 0)
    }

    @Test func repeatOutsideRangeIsRejected() throws {
        #expect(try ProbeAXTimingCommand.parse([]).rounds == 3)
        #expect(try ProbeAXTimingCommand.parse(["--repeat", "20"]).rounds == 20)
        #expect(throws: (any Error).self) { try ProbeAXTimingCommand.parse(["--repeat", "0"]) }
        #expect(throws: (any Error).self) { try ProbeAXTimingCommand.parse(["--repeat", "21"]) }
    }

    @Test func diffCountsIgnoreHandles() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        func row(_ title: String, handle: Int) -> ConversationRow {
            ConversationRow(index: 0, title: title, preview: nil, timeLabel: nil, badge: nil, avatarTitle: nil,
                            markers: [], selected: false, frame: frame, handle: AXElementHandle(id: handle))
        }
        #expect(AXTimingProbe.diffCount([row("a", handle: 1)], [row("a", handle: 2)]) == 0)
        #expect(AXTimingProbe.diffCount([row("a", handle: 1)], [row("b", handle: 1)]) == 1)
        #expect(AXTimingProbe.diffCount([row("a", handle: 1), row("b", handle: 2)], [row("a", handle: 1)]) == 1)
    }

    @Test func fixtureCommandRunsAndIsListed() throws {
        let result = try ProbeAXTimingCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--repeat", "1"]).collect()
        #expect(result.rounds == 1 && result.conversationsEqual)
        let names = ProbeCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names.contains("ax-timing"))
    }
}

/// Forwards to a fake, but its batched reads report a different AXValue for one element.
private final class BatchSkewBackend: AXBackend {
    let fake: FakeAXBackend
    let skewed: AXElementHandle
    init(fake: FakeAXBackend, skewed: AXElementHandle) { self.fake = fake; self.skewed = skewed }

    var name: String { fake.name }
    func isProcessTrusted(prompt: Bool) -> Bool { fake.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { fake.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try fake.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? { try fake.attribute(name, of: element) }
    func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        var results = try fake.attributesBySingleReads(names, of: element)
        if element == skewed, results[AXAttribute.value] != nil { results[AXAttribute.value] = .success(.string("batched-only")) }
        return results
    }
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool { try fake.isAttributeSettable(name, of: element) }
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws { try fake.setAttribute(name, to: value, of: element) }
    func actionNames(of element: AXElementHandle) throws -> [String] { try fake.actionNames(of: element) }
    func performAction(_ name: String, on element: AXElementHandle) throws { try fake.performAction(name, on: element) }
    func pid(of element: AXElementHandle) throws -> pid_t { try fake.pid(of: element) }
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try fake.makeObserver(pid: pid, handler: handler)
    }
}

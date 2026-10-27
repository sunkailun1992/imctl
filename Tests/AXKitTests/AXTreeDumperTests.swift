import Testing
@testable import AXKit

@Suite("AXTreeDumper")
struct AXTreeDumperTests {
    @Test func dumpOfFakeReproducesSourceTree() {
        let source = SampleTree.make()
        let fake = FakeAXBackend(root: source)
        let dumped = AXTreeDumper(extraAttributes: ["AXSelectedRows"]).dump(fake.rootElement)
        #expect(dumped == source)
    }

    @Test func depthAndChildLimitsMarkTruncation() {
        let fake = FakeAXBackend(root: SampleTree.make())
        let shallow = AXTreeDumper(maxDepth: 1).dump(fake.rootElement)
        #expect(shallow.children.count == 1)
        #expect(shallow.children[0].children.isEmpty)
        #expect(shallow.children[0].truncated)
        let narrow = AXTreeDumper(maxChildren: 2).dump(fake.rootElement)
        #expect(narrow.children[0].children.count == 2)
        #expect(narrow.children[0].truncated)
    }

    /// B61: one batched read per node instead of one round trip per attribute.
    @Test func dumperUsesOneBatchPerNode() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.batchesReads = true
        let timings = AXCallTimings()
        let measured = MeasuredAXBackend(base: fake, timings: timings)
        let dumped = AXTreeDumper(extraAttributes: ["AXSelectedRows"]).dump(AXElement(handle: fake.rootHandle, backend: measured))
        #expect(dumped == SampleTree.make())
        let batches = timings.report().operations.filter { $0.operation == AXCallOperation.getMany.rawValue }
        #expect(batches.reduce(0) { $0 + $1.count } == 7)
        #expect(!timings.report().operations.contains { $0.operation == AXCallOperation.get.rawValue })
    }

    @Test func attributeErrorsBecomeNilAndAreCounted() {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("title")
        let (node, stats) = AXTreeDumper().dumpWithStats(fake.rootElement)
        #expect(node.title == nil)
        #expect(stats.nodes == 7)
        #expect(stats.errors >= 1)
    }
}

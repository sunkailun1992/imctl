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

    @Test func attributeErrorsBecomeNilAndAreCounted() {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("title")
        let (node, stats) = AXTreeDumper().dumpWithStats(fake.rootElement)
        #expect(node.title == nil)
        #expect(stats.nodes == 7)
        #expect(stats.errors >= 1)
    }
}

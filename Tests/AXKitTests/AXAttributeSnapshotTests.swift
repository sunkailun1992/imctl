import CoreGraphics
import Testing
@testable import AXKit

@Suite("AXAttributeSnapshot and batched reads")
struct AXAttributeSnapshotTests {
    private static let standard = [
        AXAttribute.role, AXAttribute.subrole, AXAttribute.title, AXAttribute.value, AXAttribute.description,
        AXAttribute.identifier, AXAttribute.enabled, AXAttribute.selected, AXAttribute.focused,
        AXAttribute.frame, AXAttribute.position, AXAttribute.size, AXAttribute.children, "AXSelectedRows",
    ]
    private static let rect = CGRect(x: 10, y: 20, width: 300, height: 180)

    /// One window with every attribute the transient tests touch, batching like a live element.
    private static func window() -> FakeAXBackend {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, value: .string("draft"), frame: rect))
        fake.batchesReads = true
        return fake
    }

    private static func counting(_ fake: FakeAXBackend) -> () -> [String: Int] {
        var reads: [String: Int] = [:]
        fake.onRead = { _, name in reads[name, default: 0] += 1 }
        return { reads }
    }

    @Test(arguments: [false, true])
    func snapshotMatchesSingleGetters(batching: Bool) throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.batchesReads = batching
        let elements = [fake.rootElement] + fake.rootElement.descendants()
        #expect(elements.count == 7)
        for element in elements {
            let snapshot = try element.read(Self.standard)
            #expect(try snapshot.role() == element.role())
            #expect(try snapshot.subrole() == element.subrole())
            #expect(try snapshot.title() == element.title())
            #expect(try snapshot.value() == element.value())
            #expect(try snapshot.valueString() == element.valueString())
            #expect(try snapshot.axDescription() == element.axDescription())
            #expect(try snapshot.identifier() == element.identifier())
            #expect(try snapshot.isEnabled() == element.isEnabled())
            #expect(try snapshot.isSelected() == element.isSelected())
            #expect(try snapshot.isFocused() == element.isFocused())
            #expect(try snapshot.frame() == element.frame())
            #expect(try snapshot.children().map(\.handle) == element.children().map(\.handle))
            #expect(try snapshot.string("AXSelectedRows") == element.string("AXSelectedRows"))
        }
    }

    @Test func unsupportedAndNullReadTheSame() throws {
        let fake = Self.window()
        let unsupported = AXAttributeSnapshot(element: fake.rootElement, results: [
            AXAttribute.title: .failure(.attributeUnsupported(AXAttribute.title)),
            AXAttribute.frame: .failure(.attributeUnsupported(AXAttribute.frame)),
            AXAttribute.position: .success(.point(Self.rect.origin)),
            AXAttribute.size: .success(.size(Self.rect.size)),
        ])
        let null = AXAttributeSnapshot(element: fake.rootElement, results: [
            AXAttribute.title: .success(nil),
            AXAttribute.frame: .success(nil),
            AXAttribute.position: .success(.point(Self.rect.origin)),
            AXAttribute.size: .success(.size(Self.rect.size)),
        ])
        #expect(try unsupported.title() == nil)
        #expect(try null.title() == nil)
        #expect(try unsupported.frame() == Self.rect)
        #expect(try null.frame() == Self.rect)
    }

    @Test func itemFailureThrowsOnlyWhenAccessed() throws {
        let fake = Self.window()
        fake.injectedFailures["get:AXTitle"] = .invalidElement
        let snapshot = try fake.rootElement.read([AXAttribute.role, AXAttribute.title])
        #expect(try snapshot.role() == AXRole.window)
        #expect(throws: AXKitError.invalidElement) { try snapshot.title() }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    private static let transientNames = [AXAttribute.role, AXAttribute.value, AXAttribute.frame, AXAttribute.position, AXAttribute.size]
    private static let batch = [AXAttribute.role, AXAttribute.value, AXAttribute.frame, AXAttribute.position, AXAttribute.size]

    /// The accessor that reads `name` (frame covers position and size).
    private static func access(_ snapshot: AXAttributeSnapshot, _ name: String) throws {
        switch name {
        case AXAttribute.role: _ = try snapshot.role()
        case AXAttribute.value: _ = try snapshot.value()
        default: _ = try snapshot.frame()
        }
    }

    private static func fixture(for name: String) -> FakeAXBackend {
        let fake = window()
        if name == AXAttribute.position || name == AXAttribute.size {
            fake.mutate(fake.rootHandle, attribute: AXAttribute.frame, to: nil)
        }
        return fake
    }

    @Test(arguments: transientNames)
    func oneTransientFailureIsRetriedOnce(name: String) throws {
        let fake = Self.fixture(for: name)
        var reads: [String: Int] = [:]
        fake.onRead = { _, attribute in
            reads[attribute, default: 0] += 1
            guard attribute == name else { return }
            fake.injectedFailures["get:\(name)"] = reads[attribute] == 1
                ? .apiFailure(code: -25201, operation: "get \(name)") : nil
        }
        let snapshot = try fake.rootElement.read(Self.batch)
        try Self.access(snapshot, name)
        #expect(reads[name] == 2)
        switch name {
        case AXAttribute.role: #expect(try snapshot.role() == AXRole.window)
        case AXAttribute.value: #expect(try snapshot.valueString() == "draft")
        default: #expect(try snapshot.frame() == Self.rect)
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test(arguments: transientNames)
    func repeatedTransientFailurePropagatesTheSecondError(name: String) throws {
        let fake = Self.fixture(for: name)
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25201, operation: "get \(name)")
        fake.onRead = { _, attribute in
            guard attribute == name else { return }
            reads += 1
            fake.injectedFailures["get:\(name)"] = expected
        }
        let snapshot = try fake.rootElement.read(Self.batch)
        #expect(throws: expected) { try Self.access(snapshot, name) }
        #expect(reads == 2)
    }

    @Test(arguments: transientNames)
    func otherFailureIsNotRetried(name: String) throws {
        let fake = Self.fixture(for: name)
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25204, operation: "get \(name)")
        fake.onRead = { _, attribute in
            guard attribute == name else { return }
            reads += 1
            fake.injectedFailures["get:\(name)"] = expected
        }
        let snapshot = try fake.rootElement.read(Self.batch)
        #expect(throws: expected) { try Self.access(snapshot, name) }
        #expect(reads == 1)
    }

    @Test func frameFallsBackToPositionAndSizeWithoutAnotherRead() throws {
        let fake = Self.window()
        fake.mutate(fake.rootHandle, attribute: AXAttribute.frame, to: nil)
        let snapshot = try fake.rootElement.read([AXAttribute.frame, AXAttribute.position, AXAttribute.size])
        let reads = Self.counting(fake)
        #expect(try snapshot.frame() == Self.rect)
        #expect(reads().isEmpty)
    }

    @Test func missingAttributeFallsBackToSingleRead() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, title: "Main"))
        fake.batchesReads = true
        let snapshot = try fake.rootElement.read([AXAttribute.role])
        let reads = Self.counting(fake)
        #expect(try snapshot.title() == "Main")
        #expect(reads() == [AXAttribute.title: 1])
    }

    @Test func duplicateNamesAreReadOnce() throws {
        let fake = Self.window()
        let reads = Self.counting(fake)
        let snapshot = try fake.rootElement.read([AXAttribute.role, AXAttribute.role])
        #expect(try snapshot.role() == AXRole.window)
        #expect(reads() == [AXAttribute.role: 1])
    }

    @Test func withoutBatchingNothingIsReadUntilAccessed() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, title: "Main"))
        fake.batchesReads = false   // asserts the single-read path, whatever IMCTL_FAKE_BATCH says
        let reads = Self.counting(fake)
        let snapshot = try fake.rootElement.read([AXAttribute.role, AXAttribute.title, AXAttribute.frame])
        #expect(reads().isEmpty)
        #expect(try snapshot.role() == AXRole.window)
        #expect(reads() == [AXAttribute.role: 1])
    }

    @Test func batchingFakeKeepsEveryRequestedName() throws {
        let fake = Self.window()
        let results = try fake.attributes([AXAttribute.role, AXAttribute.title, AXAttribute.role], of: fake.rootHandle)
        #expect(results.count == 2)
        #expect(results[AXAttribute.role] == .success(.string(AXRole.window)))
        #expect(results[AXAttribute.title] == .failure(.attributeUnsupported(AXAttribute.title)))
    }

    @Test func childrenStayOnTheSameBackend() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let window = try #require(fake.element(atPath: [0]))
        let children = try window.read([AXAttribute.children]).children()
        #expect(children.count == 3)
        #expect(children.allSatisfy { $0.backend === fake })
    }
}

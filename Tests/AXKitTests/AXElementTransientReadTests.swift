import CoreGraphics
import Testing
@testable import AXKit

@Suite("AXElement transient role and frame reads")
struct AXElementTransientReadTests {
    private static let expectedFrame = CGRect(x: 10, y: 20, width: 300, height: 180)

    private static func fixture() -> FakeAXBackend {
        FakeAXBackend(root: AXNode(role: AXRole.window, frame: expectedFrame))
    }

    @Test func oneTransientRoleReadRecoversWithoutClientAction() throws {
        let fake = Self.fixture()
        var reads = 0
        fake.onRead = { _, name in
            guard name == AXAttribute.role else { return }
            reads += 1
            fake.injectedFailures["get:AXRole"] = reads == 1
                ? .apiFailure(code: -25201, operation: "get AXRole") : nil
        }

        #expect(try fake.rootElement.role() == AXRole.window)
        #expect(reads == 2)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func oneTransientFrameReadRecoversWithoutReadingTheFallback() throws {
        let fake = Self.fixture()
        var reads: [String: Int] = [:]
        fake.onRead = { _, name in
            reads[name, default: 0] += 1
            guard name == AXAttribute.frame else { return }
            fake.injectedFailures["get:AXFrame"] = reads[name] == 1
                ? .apiFailure(code: -25201, operation: "get AXFrame") : nil
        }

        #expect(try fake.rootElement.frame() == Self.expectedFrame)
        #expect(reads == [AXAttribute.frame: 2])
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test(arguments: [AXAttribute.position, AXAttribute.size])
    func fallbackRetriesOnlyTheTransientAttribute(name: String) throws {
        let fake = Self.fixture()
        fake.mutate(fake.rootHandle, attribute: AXAttribute.frame, to: nil)
        var reads: [String: Int] = [:]
        fake.onRead = { _, attribute in
            reads[attribute, default: 0] += 1
            guard attribute == name else { return }
            fake.injectedFailures["get:\(name)"] = reads[attribute] == 1
                ? .apiFailure(code: -25201, operation: "get \(name)") : nil
        }

        #expect(try fake.rootElement.frame() == Self.expectedFrame)
        #expect(reads[AXAttribute.frame] == 1)
        #expect(reads[name] == 2)
        #expect(reads[name == AXAttribute.position ? AXAttribute.size : AXAttribute.position] == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test(arguments: [AXAttribute.role, AXAttribute.frame, AXAttribute.position, AXAttribute.size])
    func repeatedTransientFailurePropagatesTheSecondError(name: String) throws {
        let fake = Self.fixture()
        if name == AXAttribute.position || name == AXAttribute.size {
            fake.mutate(fake.rootHandle, attribute: AXAttribute.frame, to: nil)
        }
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25201, operation: "get \(name)")
        fake.onRead = { _, attribute in
            guard attribute == name else { return }
            reads += 1
            fake.injectedFailures["get:\(name)"] = expected
        }

        #expect(throws: expected) {
            if name == AXAttribute.role { _ = try fake.rootElement.role() }
            else { _ = try fake.rootElement.frame() }
        }
        #expect(reads == 2)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test(arguments: [AXAttribute.role, AXAttribute.frame, AXAttribute.position, AXAttribute.size])
    func otherFailureNeverRetries(name: String) throws {
        let fake = Self.fixture()
        if name == AXAttribute.position || name == AXAttribute.size {
            fake.mutate(fake.rootHandle, attribute: AXAttribute.frame, to: nil)
        }
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25204, operation: "get \(name)")
        fake.onRead = { _, attribute in
            guard attribute == name else { return }
            reads += 1
            fake.injectedFailures["get:\(name)"] = expected
        }

        #expect(throws: expected) {
            if name == AXAttribute.role { _ = try fake.rootElement.role() }
            else { _ = try fake.rootElement.frame() }
        }
        #expect(reads == 1)
    }

    @Test func matchingCodeWithOtherOperationDoesNotRetry() throws {
        let fake = Self.fixture()
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25201, operation: "get AXValue")
        fake.onRead = { _, name in
            guard name == AXAttribute.role else { return }
            reads += 1
            fake.injectedFailures["get:AXRole"] = expected
        }
        #expect(throws: expected) { _ = try fake.rootElement.role() }
        #expect(reads == 1)
    }

    @Test func secondFailureIsPropagatedUnchanged() throws {
        let fake = Self.fixture()
        var reads = 0
        fake.onRead = { _, name in
            guard name == AXAttribute.role else { return }
            reads += 1
            fake.injectedFailures["get:AXRole"] = reads == 1
                ? .apiFailure(code: -25201, operation: "get AXRole") : .invalidElement
        }

        #expect(throws: AXKitError.invalidElement) { _ = try fake.rootElement.role() }
        #expect(reads == 2)
    }

    @Test func otherNamedGetterDoesNotAcquireAReadRetry() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, title: "Sample"))
        var reads = 0
        let expected = AXKitError.apiFailure(code: -25201, operation: "get AXTitle")
        fake.onRead = { _, name in
            guard name == AXAttribute.title else { return }
            reads += 1
            fake.injectedFailures["get:AXTitle"] = expected
        }

        #expect(throws: expected) { _ = try fake.rootElement.title() }
        #expect(reads == 1)
    }

    @Test func unsupportedRoleAndFrameKeepTheirOptionalSemantics() throws {
        let fake = FakeAXBackend(root: AXNode())
        #expect(try fake.rootElement.role() == nil)
        #expect(try fake.rootElement.frame() == nil)

        let fallback = Self.fixture()
        fallback.mutate(fallback.rootHandle, attribute: AXAttribute.frame, to: nil)
        #expect(try fallback.rootElement.frame() == Self.expectedFrame)
    }
}

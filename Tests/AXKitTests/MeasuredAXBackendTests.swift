import Foundation
import Testing
@testable import AXKit

/// Advances by `stepMs` on every reading, so each timed call lasts exactly `stepMs`.
private final class StepClock {
    private var nanos: UInt64 = 0
    private let step: UInt64
    init(stepMs: Double) { step = UInt64(stepMs * 1_000_000) }
    func now() -> UInt64 { nanos += step; return nanos }
}

/// Forwards to a fake, except that `nilName` reads as present-without-value and
/// a set `batchError` fails every batched read as a whole.
private final class StubBackend: AXBackend {
    let fake: FakeAXBackend
    var nilName: String?
    var batchError: AXKitError?
    init(_ fake: FakeAXBackend) { self.fake = fake }

    var name: String { "stub" }
    func isProcessTrusted(prompt: Bool) -> Bool { fake.isProcessTrusted(prompt: prompt) }
    func applicationElement(pid: pid_t) -> AXElementHandle { fake.applicationElement(pid: pid) }
    func attributeNames(of element: AXElementHandle) throws -> [String] { try fake.attributeNames(of: element) }
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        name == nilName ? nil : try fake.attribute(name, of: element)
    }
    func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        if let batchError { throw batchError }
        return try attributesBySingleReads(names, of: element)
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

@Suite("MeasuredAXBackend")
struct MeasuredAXBackendTests {
    private static func measured(_ base: AXBackend, stepMs: Double = 2, batchReads: Bool = true) -> (MeasuredAXBackend, AXCallTimings) {
        let timings = AXCallTimings()
        let clock = StepClock(stepMs: stepMs)
        let backend = MeasuredAXBackend(base: base, timings: timings, batchReads: batchReads,
                                        now: clock.now, wallMs: { 42 }, threadLabel: { "t" })
        return (backend, timings)
    }

    @Test func everyTimedPrimitiveRecordsOneSample() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let (backend, timings) = Self.measured(fake)
        let root = fake.rootHandle
        let input = try #require(fake.handle(atPath: [0, 1]))
        let button = try #require(fake.handle(atPath: [0, 2]))

        _ = try backend.attribute(AXAttribute.role, of: root)
        _ = try backend.attributeNames(of: root)
        _ = try backend.isAttributeSettable(AXAttribute.value, of: input)
        try backend.setAttribute(AXAttribute.value, to: .string("x"), of: input)
        _ = try backend.actionNames(of: button)
        try backend.performAction(AXAction.press, on: button)
        _ = try backend.pid(of: root)

        let report = timings.report()
        #expect(report.calls == 7)
        let keys = Set(report.operations.map { "\($0.operation) \($0.name)" })
        #expect(keys == ["get AXRole", "attributeNames ", "isSettable AXValue", "set AXValue", "actionNames ", "perform AXPress", "pid "])
        #expect(report.operations.allSatisfy { $0.count == 1 && $0.maxMs == 2 && $0.outcomes == ["ok": 1] })
        #expect(report.threads.map(\.thread) == ["t"])
        #expect(fake.recordedSets.count == 1 && fake.recordedActions.count == 1)
    }

    @Test func errorsAreRethrownUnchangedAndClassified() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("title")
        let stub = StubBackend(fake)
        stub.nilName = AXAttribute.help
        let (backend, timings) = Self.measured(stub)

        #expect(throws: AXKitError.cannotComplete("title")) { try backend.attribute(AXAttribute.title, of: fake.rootHandle) }
        #expect(try backend.attribute(AXAttribute.help, of: fake.rootHandle) == nil)
        #expect(throws: AXKitError.attributeUnsupported("AXURL")) { try backend.attribute("AXURL", of: fake.rootHandle) }

        let outcomes = Dictionary(uniqueKeysWithValues: timings.report().operations.map { ($0.name, $0.outcomes) })
        #expect(outcomes[AXAttribute.title] == ["cannotComplete": 1])
        #expect(outcomes[AXAttribute.help] == ["noValue": 1])
        #expect(outcomes["AXURL"] == ["unsupported": 1])
        #expect(timings.report().timeouts == 1)
    }

    @Test func untimedPrimitivesRecordNothing() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let (backend, timings) = Self.measured(fake)
        _ = backend.isProcessTrusted(prompt: false)
        _ = backend.applicationElement(pid: 4242)
        _ = try backend.makeObserver(pid: 4242) { _ in }
        #expect(timings.report().calls == 0)
    }

    @Test func nameIsForwarded() {
        let fake = FakeAXBackend(root: SampleTree.make())
        #expect(Self.measured(fake).0.name == "fake")
        #expect(Self.measured(StubBackend(fake)).0.name == "stub")
    }

    private static let batch = [AXAttribute.role, AXAttribute.title, AXAttribute.frame, "AXURL", AXAttribute.role]

    @Test func batchModeRecordsOneRoundTrip() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.batchesReads = true
        let window = try #require(fake.handle(atPath: [0]))
        let (backend, timings) = Self.measured(fake, batchReads: true)
        let results = try backend.attributes(Self.batch, of: window)
        #expect(results == (try fake.attributes(Self.batch, of: window)))
        let report = timings.report()
        #expect(report.calls == 1)
        let op = try #require(report.operations.first)
        #expect(op.operation == AXCallOperation.getMany.rawValue)
        #expect(op.name == "AXRole,AXTitle,AXFrame,AXURL")
        #expect(op.outcomes == ["ok": 1, "item:unsupported": 1])
    }

    @Test func singleModeReadsOnlyWhatIsAccessed() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.batchesReads = true
        let window = try #require(fake.handle(atPath: [0]))
        let (backend, timings) = Self.measured(fake, batchReads: false)
        #expect(try backend.attributes(Self.batch, of: window).isEmpty)
        let snapshot = try AXElement(handle: window, backend: backend).read(Self.batch)
        #expect(timings.report().calls == 0)
        #expect(try snapshot.role() == AXRole.window)
        #expect(try snapshot.string("AXURL") == nil)
        let report = timings.report()
        #expect(report.calls == 2)
        #expect(Set(report.operations.map(\.operation)) == [AXCallOperation.get.rawValue])
        #expect(report.operations.first { $0.name == "AXURL" }?.outcomes == ["unsupported": 1])
    }

    @Test func batchModeOverANonBatchingBackendRecordsAFallback() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let (backend, timings) = Self.measured(fake, batchReads: true)
        #expect(try backend.attributes([AXAttribute.role], of: fake.rootHandle).isEmpty)
        #expect(timings.report().operations.first?.outcomes == ["fallback": 1])
    }

    @Test func batchCallFailureIsRecordedAndRethrown() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let stub = StubBackend(fake)
        stub.batchError = .cannotComplete("get multiple attributes")
        let (backend, timings) = Self.measured(stub)
        #expect(throws: AXKitError.cannotComplete("get multiple attributes")) {
            try backend.attributes([AXAttribute.role], of: fake.rootHandle)
        }
        #expect(timings.report().operations.first?.outcomes == ["cannotComplete": 1])
        #expect(timings.report().timeouts == 1)
    }

    @Test(arguments: [(999.0, 0), (1000.0, 1)])
    func slowCallbackOnlyAboveThreshold(stepMs: Double, expected: Int) throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let (backend, _) = Self.measured(fake, stepMs: stepMs)
        var slow: [AXCallSample] = []
        backend.onSlowCall = { slow.append($0) }
        _ = try backend.attribute(AXAttribute.role, of: fake.rootHandle)
        #expect(slow.count == expected)
        if let sample = slow.first {
            #expect(sample.name == AXAttribute.role && sample.nanos == 1_000_000_000 && sample.atMs == 42)
        }
    }

    @Test func threadLabelNamesTheMainThread() {
        #expect(Thread.isMainThread ? MeasuredAXBackend.currentThreadLabel() == "main" : true)
        let label = DispatchQueue(label: "com.example.timing-test").sync { MeasuredAXBackend.currentThreadLabel() }
        #expect(label == "com.example.timing-test")
    }
}

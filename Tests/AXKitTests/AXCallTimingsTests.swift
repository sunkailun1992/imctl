import Foundation
import Testing
@testable import AXKit

@Suite("AXCallTimings")
struct AXCallTimingsTests {
    private static func sample(_ operation: AXCallOperation = .get, _ name: String, ms: Double,
                               outcome: String = "ok", thread: String = "main") -> AXCallSample {
        AXCallSample(atMs: 0, operation: operation, name: name, nanos: UInt64(ms * 1_000_000),
                     outcome: outcome, thread: thread)
    }

    @Test func aggregatesByOperationAndName() throws {
        let timings = AXCallTimings()
        for ms in [1.0, 3.0, 40.0] { timings.record(Self.sample(.get, AXAttribute.role, ms: ms)) }
        timings.record(Self.sample(.get, AXAttribute.children, ms: 6000, outcome: "cannotComplete"))

        let report = timings.report()
        #expect(report.calls == 4)
        #expect(report.timeouts == 1)
        #expect(report.totalMs == 6044)
        #expect(report.operations.first?.name == AXAttribute.children)
        let role = try #require(report.operations.first { $0.name == AXAttribute.role })
        #expect(role.operation == AXCallOperation.get.rawValue)
        #expect(role.count == 3)
        #expect(role.maxMs == 40)
        #expect(role.p50Ms == 5)
        // The 50 ms bucket bound is capped at the observed maximum.
        #expect(role.p95Ms == 40)
        #expect(role.outcomes == ["ok": 3])
        let children = try #require(report.operations.first { $0.name == AXAttribute.children })
        #expect(children.outcomes == ["cannotComplete": 1])
    }

    @Test func percentileInOverflowBucketUsesMax() throws {
        let timings = AXCallTimings()
        timings.record(Self.sample(.get, AXAttribute.children, ms: 45_000))
        let op = try #require(timings.report().operations.first)
        #expect(op.p99Ms == 45_000)
        #expect(op.maxMs == 45_000)
    }

    @Test func outcomeLabelsCoverEveryError() {
        let cases: [(AXKitError, String)] = [
            (.notTrusted, "notTrusted"),
            (.applicationNotRunning(bundleID: "b"), "applicationNotRunning"),
            (.invalidElement, "invalidElement"),
            (.attributeUnsupported("AXTitle"), "unsupported"),
            (.attributeNotSettable("AXValue"), "notSettable"),
            (.actionUnsupported("AXPress"), "actionUnsupported"),
            (.cannotComplete("get AXChildren"), "cannotComplete"),
            (.notImplemented("x"), "notImplemented"),
            (.valueNotConvertible("x"), "valueNotConvertible"),
            (.apiFailure(code: -25201, operation: "get AXValue"), "error:-25201"),
        ]
        for (error, label) in cases { #expect(AXCallTimings.outcomeLabel(for: error) == label) }
        struct Other: Error {}
        #expect(AXCallTimings.outcomeLabel(for: Other()) == "error")
    }

    @Test func slowSamplesKeepTheNewestUpToTheLimit() {
        let timings = AXCallTimings(slowThresholdMs: 500, keepSlowSamples: 2)
        for ms in [499.0, 500, 700, 900] { timings.record(Self.sample(.get, AXAttribute.value, ms: ms)) }
        let report = timings.report()
        #expect(report.slowCalls == 3)
        #expect(report.slowThresholdMs == 500)
        #expect(report.slowSamples.map(\.nanos) == [700_000_000, 900_000_000])
    }

    @Test func threadsAndScopesAreSeparate() throws {
        let timings = AXCallTimings()
        timings.record(Self.sample(.get, AXAttribute.role, ms: 2, thread: "main"))
        timings.record(Self.sample(.get, AXAttribute.role, ms: 4, thread: "main"))
        timings.record(Self.sample(.perform, "AXPress", ms: 10, thread: "com.sunkailun.imctl.executor"))
        timings.recordScope("watch.poll", nanos: 2_000_000_000, ok: false)
        timings.recordScope("watch.poll", nanos: 1_000_000, ok: true)

        let report = timings.report()
        #expect(report.calls == 3)
        let main = try #require(report.threads.first { $0.thread == "main" })
        #expect(main.count == 2 && main.totalMs == 6 && main.maxMs == 4)
        #expect(report.threads.first?.thread == "com.sunkailun.imctl.executor")
        let scope = try #require(report.scopes.first)
        #expect(scope.name == "watch.poll")
        #expect(scope.count == 2 && scope.failures == 1)
        #expect(scope.maxMs == 2000)
        #expect(scope.p50Ms == 1)
    }

    @Test func resetClearsEverythingAndMovesSince() {
        var wall: Int64 = 1_000
        let timings = AXCallTimings(wallMs: { wall })
        timings.record(Self.sample(.get, AXAttribute.role, ms: 600))
        timings.recordScope("watch.poll", nanos: 1, ok: true)
        #expect(timings.report().sinceMs == 1_000)
        wall = 5_000
        timings.reset()
        let report = timings.report()
        #expect(report.calls == 0 && report.operations.isEmpty && report.threads.isEmpty)
        #expect(report.scopes.isEmpty && report.slowSamples.isEmpty && report.slowCalls == 0)
        #expect(report.sinceMs == 5_000 && report.generatedMs == 5_000)
    }

    @Test func topOperationsLimitsTheList() {
        let timings = AXCallTimings()
        for i in 0..<5 { timings.record(Self.sample(.get, "AXAttr\(i)", ms: Double(i + 1))) }
        let report = timings.report(topOperations: 2)
        #expect(report.operations.map(\.name) == ["AXAttr4", "AXAttr3"])
        #expect(report.calls == 5)
    }

    @Test func concurrentRecordsAreAllCounted() {
        let timings = AXCallTimings()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            timings.record(Self.sample(.get, i.isMultiple(of: 2) ? AXAttribute.role : AXAttribute.value, ms: 1))
        }
        #expect(timings.report().calls == 1000)
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let timings = AXCallTimings()
        timings.record(AXCallSample(atMs: 7, operation: .getMany, name: "AXRole,AXFrame", nanos: 3_000_000,
                                    outcome: "ok", thread: "main", itemOutcomes: ["item:unsupported": 1]))
        let report = timings.report()
        let decoded = try JSONDecoder().decode(AXCallTimingReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }
}

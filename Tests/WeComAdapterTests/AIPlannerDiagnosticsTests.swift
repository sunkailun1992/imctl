import AXKit
import Foundation
import Testing
@testable import WeComAdapter

@Suite("AI planner content-free diagnostics")
struct AIPlannerDiagnosticsTests {
    @Test func countersAreAtomicAndSnapshotsContainOnlyNumbers() {
        let counters = AIPlannerDiagnostics.Counters()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            counters.recordCapture()
            counters.recordRequest()
            counters.recordSuccess()
        }
        #expect(counters.snapshot() == .init(captureCount: 100, requestCount: 100,
                                              successCount: 100))
    }

    @Test func verifiedCaptureAndProviderAttemptIncrementProcessCounters() throws {
        let (fake, window) = AIPlannerObservationTests.fixture()
        let beforeCapture = AIPlannerDiagnostics.snapshot()
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid,
            capture: { _, _ in AIPlannerObservationTests.shot() }
        )
        #expect(AIPlannerDiagnostics.snapshot().captureCount > beforeCapture.captureCount)

        let context = try AIPlannerStepDecisionTests.context()
        let settings = try AIPlannerVisionClientTests.settings()
        let beforeSuccess = AIPlannerDiagnostics.snapshot()
        let accepted = AIPlannerStepClient { request in
            (AIPlannerStepDecisionTests.body("{\"step\":\"stop\"}"),
             AIPlannerStepDecisionTests.http(request))
        }
        let result = try accepted.decide(observation: observation, context: context,
                                         settings: settings)
        #expect(result.step == .stop)
        let afterSuccess = AIPlannerDiagnostics.snapshot()
        #expect(afterSuccess.requestCount > beforeSuccess.requestCount)
        #expect(afterSuccess.successCount > beforeSuccess.successCount)

        let beforeFailure = AIPlannerDiagnostics.snapshot()
        let rejected = AIPlannerStepClient { request in
            (Data(), AIPlannerStepDecisionTests.http(request, status: 429))
        }
        #expect(throws: AIPlannerVisionError.self) {
            _ = try rejected.decide(observation: observation, context: context,
                                    settings: settings)
        }
        #expect(AIPlannerDiagnostics.snapshot().requestCount > beforeFailure.requestCount)
    }
}

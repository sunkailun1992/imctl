import Testing
@testable import AXKit
@testable import WeComAdapter

@Suite("AvailabilityTracker")
struct AvailabilityTrackerTests {
    @Test func hardFailuresPauseAtOnce() {
        var t = AvailabilityTracker(threshold: 10)
        #expect(t.failed(AXKitError.applicationNotRunning(bundleID: "x")) == .unavailable("application x is not running"))
        #expect(t.failed(AXKitError.notTrusted) == .unavailable("process is not trusted for Accessibility"))
        #expect(t.failed(WeComError.noWindow) == .unavailable(WeComError.noWindow.description))
        #expect(t.succeeded() == .available && t.consecutiveFailures == 0)
    }

    @Test func transientFailuresDegradeUntilTheThreshold() {
        var t = AvailabilityTracker(threshold: 3)
        #expect(t.failed(AXKitError.invalidElement) == .degraded(count: 1))
        #expect(t.failed(WeComError.region("conversationTable")) == .degraded(count: 2))
        #expect(t.failed(AXKitError.invalidElement) == .unavailable(AXKitError.invalidElement.description))
        #expect(t.succeeded() == .available)
        #expect(t.failed(AXKitError.cannotComplete("read")) == .degraded(count: 1))
    }
}

import Testing
@testable import ControlCore

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func perTargetIntervalAndGlobalWindow() {
        let l = RateLimiter(perTargetMinIntervalMs: 3000, globalLimit: 3, windowMs: 60_000)
        #expect(l.admit(target: "a", nowMs: 0) == nil)
        #expect(l.admit(target: "a", nowMs: 2999) != nil)          // too soon for a
        #expect(l.admit(target: "b", nowMs: 2999) == nil)          // other target fine
        #expect(l.admit(target: "a", nowMs: 3000) == nil)          // exactly the interval
        #expect(l.admit(target: "c", nowMs: 3001) != nil)          // 3 attempts in window: global cap
        #expect(l.check(target: "c", nowMs: 60_000) == nil)        // the first attempt left the window
        #expect(l.admit(target: "c", nowMs: 60_000) == nil)
        #expect(l.check(target: "a", nowMs: 60_001) != nil)        // window holds 2999, 3000, 60000 again
    }

    @Test func checkDoesNotRecord() {
        let l = RateLimiter(perTargetMinIntervalMs: 1000, globalLimit: 1, windowMs: 1000)
        #expect(l.check(target: "a", nowMs: 0) == nil)
        #expect(l.check(target: "a", nowMs: 0) == nil)
        l.record(target: "a", nowMs: 0)
        #expect(l.check(target: "b", nowMs: 1) != nil)
    }
}

import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness live-test state")
struct ReadinessOnlineStateTests {
    @Test func offlineNeverStarts() {
        var s = ReadinessOnlineState()
        #expect(s.request(online: false, refresh: true, nowMs: 0) == .skip)
        #expect(s.info(online: false, nowMs: 0).state == "skipped" && !s.running)
    }

    @Test func oneRunAtATimeThenCachedForFiveMinutes() {
        var s = ReadinessOnlineState()
        #expect(s.request(online: true, refresh: false, nowMs: 0) == .start)
        #expect(s.request(online: true, refresh: true, nowMs: 100) == .serve)
        #expect(s.info(online: true, nowMs: 100).state == "running")
        s.finish([.mqtt: .success(latencyMs: 5)], nowMs: 2_000)
        #expect(s.info(online: true, nowMs: 2_000) == ReadinessOnlineInfo(state: "done", testedMs: 2_000, nextRefreshAllowedMs: 60_000))
        #expect(s.results?[.mqtt]?.ok == true)
        #expect(s.request(online: true, refresh: false, nowMs: 301_999) == .serve)
        #expect(s.request(online: true, refresh: false, nowMs: 302_000) == .start)
    }

    @Test func refreshWaitsSixtySecondsFromTheLastStart() {
        var s = ReadinessOnlineState()
        _ = s.request(online: true, refresh: false, nowMs: 0)
        s.finish([:], nowMs: 1_000)
        #expect(s.request(online: true, refresh: true, nowMs: 59_999) == .serve)
        #expect(s.request(online: true, refresh: true, nowMs: 60_000) == .start)
    }

    /// Review I1: results tested against another configuration are never served, cache or refresh floor alike.
    @Test func aConfigChangeStartsANewRoundEvenInsideTheRefreshFloor() {
        var s = ReadinessOnlineState()
        #expect(s.request(online: true, refresh: false, nowMs: 0, fingerprint: "a") == .start)
        s.finish([:], nowMs: 1_000)
        #expect(s.request(online: true, refresh: false, nowMs: 2_000, fingerprint: "a") == .serve)
        #expect(s.request(online: true, refresh: false, nowMs: 3_000, fingerprint: "b") == .start)
        s.finish([:], nowMs: 4_000)
        #expect(s.request(online: true, refresh: true, nowMs: 5_000, fingerprint: "c") == .start)
    }
}

@Suite("Readiness probe runner")
struct ReadinessProbeRunnerTests {
    @Test func probesRunConcurrently() {
        let started = Date()
        let results = ReadinessProbeRunner.run([
            .oss: { Thread.sleep(forTimeInterval: 0.3); return .success(latencyMs: 300) },
            .mqtt: { Thread.sleep(forTimeInterval: 0.3); return .success(latencyMs: 300) },
        ], deadline: 5)
        #expect(results.count == 2 && results.values.allSatisfy(\.ok))
        #expect(Date().timeIntervalSince(started) < 0.55)
    }

    @Test func aProbeThatNeverFinishesTimesOutWithoutHidingTheOthers() {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let results = ReadinessProbeRunner.run([
            .mqtt: { gate.wait(); return .success(latencyMs: 1) },
            .oss: { .success(latencyMs: 2) },
        ], deadline: 0.3)
        #expect(results[.mqtt] == .failure("timeout", latencyMs: 300))
        #expect(results[.oss]?.ok == true)
    }

    @Test func nothingToRunIsEmpty() {
        #expect(ReadinessProbeRunner.run([:], deadline: 1).isEmpty)
    }
}

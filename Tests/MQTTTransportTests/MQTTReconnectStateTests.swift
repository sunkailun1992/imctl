import Foundation
import Testing
@testable import MQTTTransport

@Suite("MQTT reconnect state")
struct MQTTReconnectStateTests {
    /// Jitter at the top of its range, so every delay is its whole base.
    static func make(jitter: Double = 1) -> MQTTReconnectState {
        var state = MQTTReconnectState()
        state.jitter = { jitter }
        return state
    }

    @Test func aRefusedConnectAndItsCloseScheduleOneRetry() {
        var failureFirst = Self.make()
        #expect(failureFirst.start() == .connect(attempt: 1))
        #expect(failureFirst.connectFailed(attempt: 1) == .retry(attempt: 1, after: 1))
        #expect(failureFirst.connectionClosed(active: false, now: 0) == .ignore)

        var closeFirst = Self.make()
        _ = closeFirst.start()
        #expect(closeFirst.connectionClosed(active: false, now: 0) == .ignore)
        #expect(closeFirst.connectFailed(attempt: 1) == .retry(attempt: 1, after: 1))
    }

    @Test func theCloseOfAReplacedConnectionKeepsTheCurrentOne() {
        var state = Self.make()
        _ = state.start()
        _ = state.connectFailed(attempt: 1)
        #expect(state.retryDue(attempt: 1) == .connect(attempt: 2))
        #expect(state.connectSucceeded(attempt: 2, active: true, now: 10) == .online)
        #expect(state.connectionClosed(active: true, now: 12) == .staleClose)
        #expect(state.isConnected)
        #expect(state.connectionClosed(active: false, now: 13) == .retry(attempt: 2, after: 2))
        #expect(!state.isConnected)
    }

    @Test func connectionsDroppedRightAfterConnackBackOffEachTime() {
        var state = Self.make()
        var attempt = 1
        var now: TimeInterval = 0
        var delays: [TimeInterval] = []
        #expect(state.start() == .connect(attempt: 1))
        for _ in 1...7 {
            #expect(state.connectSucceeded(attempt: attempt, active: true, now: now) == .online)
            guard case .retry(let retrying, let delay) = state.connectionClosed(active: false, now: now + 0.1) else {
                Issue.record("a dropped connection was not retried")
                return
            }
            delays.append(delay)
            now += 0.1 + delay
            #expect(state.retryDue(attempt: retrying) == .connect(attempt: attempt + 1))
            attempt += 1
        }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func refusedConnectsBackOffToThirtySeconds() {
        var state = Self.make()
        _ = state.start()
        var delays: [TimeInterval] = []
        for attempt in 1...7 {
            guard case .retry(_, let delay) = state.connectFailed(attempt: attempt) else {
                Issue.record("a refused connect was not retried")
                return
            }
            delays.append(delay)
            #expect(state.retryDue(attempt: attempt) == .connect(attempt: attempt + 1))
        }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func onlyAConnectionThatLastedAMinuteResetsTheBackoff() {
        for (lasted, delay) in [(59.9, 8.0), (60, 1)] as [(TimeInterval, TimeInterval)] {
            var state = Self.make()
            _ = state.start()
            for attempt in 1...3 { // retried after 1, 2 and 4 s
                _ = state.connectFailed(attempt: attempt)
                _ = state.retryDue(attempt: attempt)
            }
            #expect(state.connectSucceeded(attempt: 4, active: true, now: 100) == .online)
            #expect(state.connectionClosed(active: false, now: 100 + lasted) == .retry(attempt: 4, after: delay))
        }
    }

    @Test func aConnectWhoseSocketClosedFirstIsRetried() {
        var state = Self.make()
        _ = state.start()
        #expect(state.connectSucceeded(attempt: 1, active: false, now: 0) == .retry(attempt: 1, after: 1))
        #expect(!state.isConnected)
    }

    @Test func aRetryConnectsOnceAndOnlyTheCurrentAttemptCounts() {
        var state = Self.make()
        _ = state.start()
        _ = state.connectFailed(attempt: 1)
        #expect(state.retryDue(attempt: 1) == .connect(attempt: 2))
        #expect(state.retryDue(attempt: 1) == .ignore)
        #expect(state.connectFailed(attempt: 1) == .ignore)
        #expect(state.connectSucceeded(attempt: 1, active: true, now: 0) == .ignore)
        #expect(!state.isConnected)
    }

    @Test func stopEndsRetries() {
        var waiting = Self.make()
        _ = waiting.start()
        _ = waiting.connectFailed(attempt: 1)
        waiting.stop()
        #expect(waiting.retryDue(attempt: 1) == .ignore)
        #expect(waiting.start() == .ignore)

        var connected = Self.make()
        _ = connected.start()
        _ = connected.connectSucceeded(attempt: 1, active: true, now: 0)
        connected.stop()
        #expect(!connected.isConnected)
        #expect(connected.connectionClosed(active: false, now: 1) == .ignore)
    }

    @Test func jitterPutsEachDelayInTheUpperHalfOfItsBase() {
        for (fraction, delay) in [(0.0, 0.5), (0.5, 0.75), (1.0, 1.0)] {
            var state = Self.make(jitter: fraction)
            _ = state.start()
            #expect(state.connectFailed(attempt: 1) == .retry(attempt: 1, after: delay))
        }
    }

    @Test func theDefaultJitterVaries() {
        let delays = (0..<50).map { _ -> TimeInterval in
            var state = MQTTReconnectState()
            _ = state.start()
            guard case .retry(_, let delay) = state.connectFailed(attempt: 1) else { return -1 }
            return delay
        }
        #expect(delays.allSatisfy { (0.5...1).contains($0) })
        #expect(Set(delays).count > 1)
    }
}

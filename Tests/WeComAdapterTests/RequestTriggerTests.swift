import Testing
@testable import ControlCore
@testable import WeComAdapter

/// Live 2026-09-15: the 通讯录 badge is the client's unread "new customers"
/// count — a human opening the page clears it while the card still says 接受,
/// and it came back after the daemon's own read. User decision 2026-09-23:
/// even so, a round never starts while the badge reads zero — nothing is
/// pending, so switching the client to that view would only be visible for
/// no reason. A human clearing the badge while cards remain is handled by an
/// explicit `contact.request.list` call, not by another round.
@Suite("RequestRoundTrigger")
struct RequestTriggerTests {
    let minute: Int64 = 60_000

    /// B49: while the rail cannot be attributed the watcher passes nil. That is neither a drop to
    /// zero nor, when the reading returns, an increase — N → unknown → N starts no extra round.
    @Test func anUnattributedReadingChangesNothing() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: nil, mode: .all, nowMs: 0) == nil)                 // unknown at start: no .start
        #expect(t.poll(badge: 2, mode: .all, nowMs: 1_000) == .start)           // the first attributed reading
        t.finished(success: true, nowMs: 2_000)
        #expect(t.poll(badge: nil, mode: .all, nowMs: 2 * minute) == nil)       // unknown: not a drop
        #expect(t.poll(badge: 2, mode: .all, nowMs: 3 * minute) == nil)         // same count again: not an increase
        #expect(t.poll(badge: nil, mode: .off, nowMs: 4 * minute) == nil)       // a mode seen only with unknown is not noted
        #expect(t.poll(badge: 3, mode: .all, nowMs: 5 * minute) == .badgeChanged)
    }

    @Test func daemonStartWithAutomationOnAndBadgeZeroRunsNoRound() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 0, mode: .remote, nowMs: 1_000) == nil)
        #expect(!t.running)
        #expect(t.poll(badge: 0, mode: .remote, nowMs: 6_000) == nil)
    }

    @Test func daemonStartWithAPositiveBadgeRunsOneRoundAtOnce() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 3, mode: .remote, nowMs: 1_000) == .start)
        #expect(t.running)
    }

    @Test func automationOffWaitsAndRunsWhenSwitchedOn() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 0, mode: .off, nowMs: 1_000) == nil)
        #expect(t.poll(badge: 3, mode: .off, nowMs: 2_000) == nil)          // growth while off: nothing enters 通讯录
        #expect(t.poll(badge: 3, mode: .rules, nowMs: 3_000) == .switchedOn)
    }

    @Test func switchingOnWithAZeroBadgeRunsNothingUntilTheBadgeRises() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 0, mode: .off, nowMs: 0) == nil)
        #expect(t.poll(badge: 0, mode: .all, nowMs: 1_000) == nil)             // switched on, but nothing pending
        #expect(t.poll(badge: 1, mode: .all, nowMs: 2_000) == .badgeChanged)   // the first positive badge still runs at once
        t.finished(success: true, nowMs: 2_500)
        #expect(t.poll(badge: 1, mode: .all, nowMs: 30_000) == nil)           // < 60 s since that round: minIntervalMs
    }

    @Test func aBadgeDecreaseNeverStartsARoundEvenWhileItStaysAtZero() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        t.finished(success: true, nowMs: 3_000)
        #expect(t.poll(badge: 0, mode: .all, nowMs: 2 * minute) == nil)      // decrease: never starts a round
        #expect(t.poll(badge: 0, mode: .all, nowMs: 40 * minute) == nil)     // stays at 0: no latched round surfaces later
        #expect(t.poll(badge: 2, mode: .all, nowMs: 41 * minute) == .badgeChanged)
    }

    @Test func badgeGrowthRunsAtOnceAndClearingNeverStartsARound() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        t.finished(success: true, nowMs: 4_000)
        #expect(t.poll(badge: 2, mode: .all, nowMs: 20 * minute) == nil)   // unchanged, sweep not due yet
        #expect(t.poll(badge: 3, mode: .all, nowMs: 21 * minute) == .badgeChanged)
        t.finished(success: true, nowMs: 21 * minute + 5_000)
        #expect(t.poll(badge: 0, mode: .all, nowMs: 40 * minute) == nil)   // cleared: never starts a round
        #expect(t.poll(badge: 0, mode: .all, nowMs: 60 * minute) == nil)   // stays cleared: no sweep either
    }

    @Test func noRoundWhileRunningOrInsideTheMinimumInterval() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 1, mode: .all, nowMs: 0) == .start)
        #expect(t.poll(badge: 5, mode: .all, nowMs: 10_000) == nil)        // still running
        t.finished(success: true, nowMs: 20_000)
        #expect(t.poll(badge: 6, mode: .all, nowMs: 30_000) == nil)        // < 60 s since the last round
        #expect(t.poll(badge: 6, mode: .all, nowMs: minute) == .badgeChanged)   // the change was remembered
    }

    @Test func badgeAboveZeroIsSweptEveryHalfHour() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .remote, nowMs: 0) == .start)
        t.finished(success: true, nowMs: 3_000)
        #expect(t.poll(badge: 2, mode: .remote, nowMs: 29 * minute) == nil)
        #expect(t.poll(badge: 2, mode: .remote, nowMs: 30 * minute) == .sweep)
        t.finished(success: true, nowMs: 30 * minute + 3_000)
        #expect(t.poll(badge: 0, mode: .remote, nowMs: 61 * minute) == nil)   // cleared: never starts a round
        #expect(t.poll(badge: 0, mode: .remote, nowMs: 90 * minute) == nil)   // stays cleared: no further sweep either
    }

    @Test func failedRoundIsRetriedAfterTheRetryIntervalNotOnTheNextPoll() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 1, mode: .all, nowMs: 0) == .start)
        t.finished(success: false, nowMs: 12_000)
        #expect(t.poll(badge: 1, mode: .all, nowMs: 2 * minute) == nil)
        #expect(t.poll(badge: 1, mode: .all, nowMs: 12_000 + t.retryMs) == .retry)
        t.finished(success: true, nowMs: 12_000 + t.retryMs + 5_000)
        #expect(t.poll(badge: 1, mode: .all, nowMs: 12_000 + t.retryMs + 2 * minute) == nil)   // success clears the retry
    }

    struct Round: Equatable {
        var ms: Int64
        var reason: RequestRoundTrigger.Reason
    }

    /// Polls once a second from `fromMs` through `throughMs`; the first round that starts, if any.
    func firstRound(_ t: inout RequestRoundTrigger, badge: Int, fromMs: Int64, throughMs: Int64) -> Round? {
        var now = fromMs
        while now <= throughMs {
            if let reason = t.poll(badge: badge, mode: .all, nowMs: now) { return Round(ms: now, reason: reason) }
            now += 1_000
        }
        return nil
    }

    /// Fails the round running since `startedMs` and then up to `retries` retries, each 20 s long; returns when the last one failed.
    func failRepeatedly(_ t: inout RequestRoundTrigger, badge: Int, startedMs: Int64, retries: Int) -> Int64 {
        var failedAt = startedMs + 20_000
        t.finished(success: false, nowMs: failedAt)
        for _ in 0..<retries {
            guard let round = firstRound(&t, badge: badge, fromMs: failedAt, throughMs: failedAt + 60 * minute) else { break }
            failedAt = round.ms + 20_000
            t.finished(success: false, nowMs: failedAt)
        }
        return failedAt
    }

    /// Live 2026-09-23 (macOS 27.0, 5.0.11): after a locator failure the daemon switched the client
    /// to 通讯录 every 5 minutes with the badge at 0 — nothing to process, and every retry is visible.
    @Test func aFailedRoundIsNeverRetriedWhileTheBadgeIsZero() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 1, mode: .all, nowMs: 0) == .start)
        t.finished(success: false, nowMs: 20_000)
        #expect(t.poll(badge: 0, mode: .all, nowMs: 20_000 + t.retryMs) == nil)   // retry due, but the badge is 0: nothing to process
        #expect(firstRound(&t, badge: 0, fromMs: 20_000 + t.retryMs, throughMs: 24 * 60 * minute) == nil)
        #expect(t.poll(badge: 1, mode: .all, nowMs: 24 * 60 * minute + 1_000) == .badgeChanged)   // a new request still runs at once
    }

    @Test func failedRoundsWithABadgeBackOffFiveTimesThenWaitForTheBadgeToChange() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        var failedAt: Int64 = 20_000
        t.finished(success: false, nowMs: failedAt)
        for delay in [5, 10, 20, 30, 30] as [Int64] {
            let round = firstRound(&t, badge: 2, fromMs: failedAt, throughMs: failedAt + 60 * minute)
            #expect(round == Round(ms: failedAt + delay * minute, reason: .retry))
            failedAt = (round?.ms ?? failedAt) + 20_000
            t.finished(success: false, nowMs: failedAt)
        }
        // five failed retries: neither a retry nor the half-hour sweep while the badge stays at 2
        #expect(firstRound(&t, badge: 2, fromMs: failedAt, throughMs: failedAt + 24 * 60 * minute) == nil)
        let changedAt = failedAt + 24 * 60 * minute + 1_000
        #expect(t.poll(badge: 3, mode: .all, nowMs: changedAt) == .badgeChanged)
        t.finished(success: false, nowMs: changedAt + 20_000)                  // the backoff starts over
        #expect(firstRound(&t, badge: 3, fromMs: changedAt + 20_000, throughMs: changedAt + 60 * minute)
                == Round(ms: changedAt + 20_000 + 5 * minute, reason: .retry))
    }

    @Test func aSuccessfulRoundResetsTheBackoff() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        t.finished(success: false, nowMs: 20_000)
        #expect(firstRound(&t, badge: 2, fromMs: 20_000, throughMs: 60 * minute) == Round(ms: 20_000 + 5 * minute, reason: .retry))
        t.finished(success: false, nowMs: 40_000 + 5 * minute)
        #expect(firstRound(&t, badge: 2, fromMs: 40_000 + 5 * minute, throughMs: 120 * minute)
                == Round(ms: 40_000 + 15 * minute, reason: .retry))                // doubled: 10 min
        t.finished(success: true, nowMs: 60_000 + 15 * minute)
        #expect(firstRound(&t, badge: 2, fromMs: 60_000 + 15 * minute, throughMs: 120 * minute)
                == Round(ms: 40_000 + 45 * minute, reason: .sweep))                // back to the half-hour sweep
        t.finished(success: false, nowMs: 60_000 + 45 * minute)
        #expect(firstRound(&t, badge: 2, fromMs: 60_000 + 45 * minute, throughMs: 180 * minute)
                == Round(ms: 60_000 + 50 * minute, reason: .retry))                // 5 min again, not 20
    }

    @Test func aBadgeChangeDuringTheBackoffRunsAtOnceAndRestartsIt() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        t.finished(success: false, nowMs: 20_000)
        #expect(t.poll(badge: 2, mode: .all, nowMs: 20_000 + 5 * minute) == .retry)
        t.finished(success: false, nowMs: 40_000 + 5 * minute)                     // two failures: the next retry would wait 10 min
        #expect(t.poll(badge: 3, mode: .all, nowMs: 50_000 + 5 * minute) == nil)            // 30 s after the retry started: minIntervalMs
        #expect(t.poll(badge: 3, mode: .all, nowMs: 20_000 + 6 * minute) == .badgeChanged)  // 60 s after it: at once, not after the backoff
        t.finished(success: false, nowMs: 40_000 + 6 * minute)
        #expect(firstRound(&t, badge: 3, fromMs: 40_000 + 6 * minute, throughMs: 60 * minute)
                == Round(ms: 40_000 + 11 * minute, reason: .retry))                // 5 min again, not 20
    }

    @Test func switchingAutomationBackOnAfterTheRetriesGaveUpRunsARoundAndRestartsTheBackoff() {
        var t = RequestRoundTrigger()
        #expect(t.poll(badge: 2, mode: .all, nowMs: 0) == .start)
        let gaveUpAt = failRepeatedly(&t, badge: 2, startedMs: 0, retries: 5)
        #expect(firstRound(&t, badge: 2, fromMs: gaveUpAt, throughMs: gaveUpAt + 3 * 60 * minute) == nil)
        #expect(t.poll(badge: 2, mode: .off, nowMs: gaveUpAt + 3 * 60 * minute + 1_000) == nil)
        let onAt = gaveUpAt + 3 * 60 * minute + 2_000
        #expect(t.poll(badge: 2, mode: .all, nowMs: onAt) == .switchedOn)
        t.finished(success: false, nowMs: onAt + 20_000)
        #expect(firstRound(&t, badge: 2, fromMs: onAt + 20_000, throughMs: onAt + 60 * minute)
                == Round(ms: onAt + 20_000 + 5 * minute, reason: .retry))
    }
}

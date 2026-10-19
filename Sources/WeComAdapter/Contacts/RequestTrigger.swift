import ControlCore

/// When the daemon's request automation runs a round. Pure state, so the
/// scheduling is testable without a client. Live 2026-09-15: the 通讯录
/// badge is the client's unread "new customers" count — a human opening the
/// page clears it while the card still says 接受, and it came back after the
/// daemon's own read.
///
/// User decision 2026-09-23: every round is a visible switch to 通讯录, so
/// none may start unless the badge is above zero at that moment — a start-up
/// or switch-on round with nothing to process is still a visible navigation
/// for no reason. `.start` (first poll after daemon start with automation on)
/// and `.switchedOn` (mode off → on) fire only when the badge is already
/// positive right then; otherwise nothing is pending, and the next increase
/// from zero fires `.badgeChanged` as usual. `.badgeChanged` itself fires
/// only on an increase to a positive count — a decrease or a clearing never
/// starts a round, even while cards remain unaccepted; that case is now
/// handled only by an explicit `contact.request.list` call from the console /
/// Java / an agent, never by the daemon on its own. `.sweep` (every
/// `sweepMs`) and `.retry` (after a failed round) were already conditioned on
/// the badge being above zero and are unchanged. Never inside `minIntervalMs`
/// of the previous round, never while one is running, never while
/// `autoAccept` is `off`.
///
/// Live 2026-09-23 (macOS 27.0, 5.0.11): before the above, an unconditional
/// `retryMs` retry after a locator failure switched the client every 5
/// minutes with the badge at 0. So a failed round is retried only while the
/// badge is above zero: `retryMs` after the failure, doubled with every
/// further failure up to `sweepMs` (5, 10, 20, 30, 30 min), at most
/// `maxRetries` times in a row, with no sweep in between. A success, a badge
/// change or a switch-on starts the count over; once the last retry has
/// failed, nothing runs until the badge changes or automation is switched on
/// again.
public struct RequestRoundTrigger: Equatable {
    public enum Reason: String { case start, badgeChanged, switchedOn, sweep, retry }

    public var minIntervalMs: Int64 = 60_000
    public var sweepMs: Int64 = 30 * 60_000
    public var retryMs: Int64 = 5 * 60_000
    /// Retries after a failed round before the trigger waits for a badge change or a switch-on.
    public var maxRetries = 5
    public private(set) var running = false
    /// Failed rounds in a row since the last success, badge change or switch-on.
    public private(set) var failures = 0

    private var lastBadge: Int?
    private var lastMode: ContactRequestPolicy.AcceptMode?
    private var pending: Reason?
    private var lastRoundMs: Int64?
    private var failedAtMs: Int64?

    public init() {}

    /// One poll with the current badge and policy mode. Returns the reason
    /// when a round should start now; the trigger then counts it as running
    /// until `finished`. A round never starts while the current badge is
    /// zero: an increase to a positive count (or a start / switch-on already
    /// at a positive count) is remembered until `running` / `minIntervalMs`
    /// let it fire, but a later decrease is never noted, so a stale reason
    /// can only ever fire while the badge is still above zero at the moment
    /// it does.
    ///
    /// B49: `badge` is nil while the rail cannot be attributed (`RailBadges`).
    /// Such a poll changes nothing and starts nothing — it is neither a drop
    /// to zero nor, once the reading returns, an increase: N → unknown → N is
    /// no badge change and no extra visible switch to 通讯录.
    public mutating func poll(badge: Int?, mode: ContactRequestPolicy.AcceptMode, nowMs: Int64) -> Reason? {
        guard let badge else { return nil }
        if let last = lastBadge {
            if badge > last, badge > 0 { pending = .badgeChanged }
        } else if badge > 0 {
            pending = .start
        }
        if let lastMode, lastMode == .off, mode != .off, badge > 0 { pending = .switchedOn }
        lastBadge = badge
        lastMode = mode
        guard mode != .off, !running, lastRoundMs.map({ nowMs - $0 >= minIntervalMs }) ?? true else { return nil }
        let reason: Reason
        if let pending, badge > 0 {
            reason = pending
        } else if badge > 0, let failedAtMs, failures <= maxRetries, nowMs - failedAtMs >= retryDelayMs(afterFailures: failures) {
            reason = .retry
        } else if badge > 0, failures == 0, let lastRoundMs, nowMs - lastRoundMs >= sweepMs {
            reason = .sweep
        } else {
            return nil
        }
        // A badge change or a switch-on starts the backoff over.
        if pending == .badgeChanged || pending == .switchedOn { failures = 0 }
        pending = nil
        failedAtMs = nil
        running = true
        lastRoundMs = nowMs
        return reason
    }

    public mutating func finished(success: Bool, nowMs: Int64) {
        running = false
        failures = success ? 0 : failures + 1
        failedAtMs = success ? nil : nowMs
    }

    /// The wait after the `failures`-th failed round in a row: `retryMs`, doubled per further failure, at most `sweepMs`.
    func retryDelayMs(afterFailures failures: Int) -> Int64 {
        var delay = retryMs
        for _ in 1..<max(failures, 1) where delay < sweepMs { delay *= 2 }
        return min(delay, sweepMs)
    }
}

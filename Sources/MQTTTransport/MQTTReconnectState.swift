import Foundation

/// B63: when `MQTTNIOLink` connects and reconnects, kept apart from the client and its timers so it is testable offline.
///
/// One attempt is in flight or waiting at a time. A refused connect whose socket also closes, a close while an attempt
/// is pending, or the late close of a connection the client has already replaced schedules nothing more; before B63
/// each of these started another reconnect chain, and the chains kept replacing one another's connection under the
/// same client id. The delay doubles from `minDelay` to `maxDelay` and only resets after a connection lasted
/// `stableAfter`, so a broker that drops every connection right after CONNACK is retried less and less often; each
/// delay lands in the upper half of its base.
struct MQTTReconnectState {
    enum Decision: Equatable {
        /// Nothing to do.
        case ignore
        /// Connect now as `attempt`.
        case connect(attempt: Int)
        /// The attempt connected: run the on-connect work.
        case online
        /// A connection the client had already replaced closed; the current one stays up.
        case staleClose
        /// Call `retryDue(attempt:)` after this many seconds.
        case retry(attempt: Int, after: TimeInterval)
    }

    private enum Phase: Equatable {
        case idle
        case connecting(attempt: Int)
        case connected(attempt: Int, since: TimeInterval)
        case waiting(attempt: Int)
        case stopped
    }

    let minDelay: TimeInterval = 1
    let maxDelay: TimeInterval = 30
    /// A connection that lasted this long resets the delay to `minDelay`.
    let stableAfter: TimeInterval = 60
    /// A fraction in 0...1 per delay: the delay is `base × (0.5 + 0.5 × fraction)`.
    var jitter: () -> Double = { Double.random(in: 0...1) }

    private var phase = Phase.idle
    /// Retries since the last stable connection; the next base is `minDelay × 2^retries`, at most `maxDelay`.
    private var retries = 0

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    mutating func start() -> Decision {
        guard phase == .idle else { return .ignore }
        phase = .connecting(attempt: 1)
        return .connect(attempt: 1)
    }

    /// `active`: the client still has a live connection when the CONNACK is handled.
    mutating func connectSucceeded(attempt: Int, active: Bool, now: TimeInterval) -> Decision {
        guard phase == .connecting(attempt: attempt) else { return .ignore }
        guard active else { return retry(attempt) }
        phase = .connected(attempt: attempt, since: now)
        return .online
    }

    mutating func connectFailed(attempt: Int) -> Decision {
        guard phase == .connecting(attempt: attempt) else { return .ignore }
        return retry(attempt)
    }

    /// Some connection of the client closed. `active`: the client still has a live connection, so the closed one
    /// had been replaced. While an attempt is pending or a retry is due, its own outcome decides instead.
    mutating func connectionClosed(active: Bool, now: TimeInterval) -> Decision {
        guard case .connected(let attempt, let since) = phase else { return .ignore }
        if active { return .staleClose }
        if now - since >= stableAfter { retries = 0 }
        return retry(attempt)
    }

    mutating func retryDue(attempt: Int) -> Decision {
        guard phase == .waiting(attempt: attempt) else { return .ignore }
        phase = .connecting(attempt: attempt + 1)
        return .connect(attempt: attempt + 1)
    }

    mutating func stop() {
        phase = .stopped
    }

    private mutating func retry(_ attempt: Int) -> Decision {
        let base = min(minDelay * pow(2, Double(retries)), maxDelay)
        retries = min(retries + 1, 30)
        phase = .waiting(attempt: attempt)
        return .retry(attempt: attempt, after: base * (0.5 + 0.5 * jitter()))
    }
}

import AXKit

/// Decides when a failing poll means "the client is unavailable" (the
/// `system` pause) and when it is just a pane the client does not expose to
/// AX. 2026-09-15 on 5.0.11: some conversations render nothing readable while
/// active — no header, no message table, no composer — and reads throw stale
/// elements; pausing at once left the controller unable to switch away
/// (every command answered PAUSED). Hard failures still pause immediately;
/// transient ones only after `threshold` consecutive failing polls.
public struct AvailabilityTracker: Equatable {
    public enum Verdict: Equatable {
        case available
        /// Transient failure; the client stays available so commands can recover the state.
        case degraded(count: Int)
        case unavailable(String)
    }

    public var threshold: Int
    public private(set) var consecutiveFailures = 0

    public init(threshold: Int = 10) { self.threshold = threshold }

    /// The client is gone or unreadable as a whole, not just the active pane.
    public static func isHardFailure(_ error: Error) -> Bool {
        if let ax = error as? AXKitError {
            switch ax {
            case .applicationNotRunning, .notTrusted: return true
            default: return false
            }
        }
        if let wecom = error as? WeComError, case .noWindow = wecom { return true }
        return false
    }

    public mutating func succeeded() -> Verdict {
        consecutiveFailures = 0
        return .available
    }

    public mutating func failed(_ error: Error) -> Verdict {
        consecutiveFailures += 1
        if Self.isHardFailure(error) || consecutiveFailures >= threshold {
            return .unavailable(String(describing: error))
        }
        return .degraded(count: consecutiveFailures)
    }
}

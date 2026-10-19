import Foundation

/// Hard send-rate cap enforced by the executor, beneath any consumer policy:
/// one attempt per target every `perTargetMinIntervalMs` and at most
/// `globalLimit` attempts per sliding `windowMs`. Attempts count, not
/// successes, so a failing loop cannot hammer the client. In-memory on
/// purpose: a daemon restart (≥ 5 s launchd throttle) is longer than the
/// per-target interval, and the global window simply restarts empty.
public final class RateLimiter {
    public var perTargetMinIntervalMs: Int64
    public var globalLimit: Int
    public var windowMs: Int64
    private var lastByTarget: [String: Int64] = [:]
    private var recent: [Int64] = []
    private let lock = NSLock()

    public init(perTargetMinIntervalMs: Int64 = 3000, globalLimit: Int = 20, windowMs: Int64 = 60_000) {
        self.perTargetMinIntervalMs = perTargetMinIntervalMs
        self.globalLimit = globalLimit
        self.windowMs = windowMs
    }

    /// nil when an attempt may proceed now; otherwise the reason (wire message). Records nothing.
    public func check(target: String, nowMs: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return reason(target: target, nowMs: nowMs)
    }

    public func record(target: String, nowMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        lastByTarget[target] = nowMs
        recent.append(nowMs)
    }

    /// `check` + `record` under one lock.
    public func admit(target: String, nowMs: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let why = reason(target: target, nowMs: nowMs) { return why }
        lastByTarget[target] = nowMs
        recent.append(nowMs)
        return nil
    }

    private func reason(target: String, nowMs: Int64) -> String? {
        recent.removeAll { nowMs - $0 >= windowMs }
        if let last = lastByTarget[target], nowMs - last < perTargetMinIntervalMs {
            return "target \"\(target)\" was attempted \(nowMs - last) ms ago; minimum interval \(perTargetMinIntervalMs) ms"
        }
        if recent.count >= globalLimit {
            return "\(recent.count) sends attempted in the last \(windowMs / 1000) s; limit \(globalLimit)"
        }
        return nil
    }
}

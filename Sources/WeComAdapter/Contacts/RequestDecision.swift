import ControlCore

/// Which cards of one round to report and which to accept. Pure, so the
/// daemon's automation is testable without a client.
public enum RequestDecision {
    public static func key(name: String, greeting: String?) -> String { name + "\u{1f}" + (greeting ?? "") }

    /// The idempotency key for one automated attempt. The executor replays any
    /// record with the same key — failed ones included (live 2026-09-15 16:39:
    /// an accept that failed on a stale element would have replayed as failed
    /// in every later round) — so a previous attempt that failed, expired or
    /// was cancelled gets a fresh key; success, unknown and in-flight records
    /// keep replaying (an unknown accept must never be re-run blindly).
    public static func attemptKey(base: String, previous: CommandStateV1?, nowMs: Int64) -> String {
        switch previous {
        case .failed?, .expired?, .cancelled?: return "\(base)-r\(nowMs)"
        default: return base
        }
    }

    public static func plan(cards: [(name: String, greeting: String?, status: String)], policy: ContactRequestPolicy, seen: Set<String>)
        -> (observe: [String], accept: [String], seen: Set<String>) {
        var seen = seen
        var observe: [String] = []
        var accept: [String] = []
        for card in cards where card.status == "pending" {
            let k = key(name: card.name, greeting: card.greeting)
            if !seen.contains(k) { observe.append(card.name); seen.insert(k) }
            if policy.decides(name: card.name, greeting: card.greeting) { accept.append(card.name) }
        }
        return (observe, accept, seen)
    }
}

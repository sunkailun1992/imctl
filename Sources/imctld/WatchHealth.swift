import ControlCore
import Foundation

/// The watcher's latest poll, readable from any thread (B52 readiness). The watcher writes it on the main run
/// loop; `controller.readiness` reads it on the socket or MQTT queue. States and counts only — never titles.
final class WatchHealth: @unchecked Sendable {
    struct Snapshot: Equatable {
        /// When the last poll attempt ended (success or failure); 0 = none yet.
        var lastPollMs: Int64 = 0
        var lastPollOK = false
        var clientAvailable: Bool?
        var conversationCount = 0
        var railRead = false
        var railProblem: String?
        var errorTimes: [Int64] = []
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.lock(); body(&value); lock.unlock()
    }

    /// A failed poll with the client unreachable or degraded (not the Contacts tab); kept for one hour.
    func noteError(nowMs: Int64) {
        update { s in
            s.errorTimes.append(nowMs)
            s.errorTimes.removeAll { nowMs - $0 > 3_600_000 }
        }
    }

    func facts(nowMs: Int64) -> ReadinessFacts.Watch {
        let s = snapshot
        return ReadinessFacts.Watch(lastPollAgeMs: s.lastPollMs > 0 ? max(0, nowMs - s.lastPollMs) : nil, lastPollOK: s.lastPollOK,
                                    clientAvailable: s.clientAvailable, conversationCount: s.conversationCount,
                                    railRead: s.railRead, railProblem: s.railProblem,
                                    errorsLastHour: s.errorTimes.filter { nowMs - $0 <= 3_600_000 }.count)
    }
}

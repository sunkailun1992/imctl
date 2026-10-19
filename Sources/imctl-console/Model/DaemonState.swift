import Foundation

/// `state.json` as imctld writes it every 5 s. Everything but `pid` is
/// optional so a state file from an older daemon still decodes.
struct DaemonState: Codable, Equatable {
    var pid: Int
    var version: String?
    var startedMs: Int64?
    var lastPollMs: Int64?
    var polls: Int?
    var errors: Int?
    var relocations: Int?
    var active: String?
    var conversations: Int?
    var observer: Bool?
    var notifications: Int?
    var observedViaNotification: Int?
    var lastEventId: Int64?
    var paused: [String]?
    var policy: String?
    var trusted: Bool?
    var socket: String?

    init(pid: Int) { self.pid = pid }

    static func load(from url: URL) throws -> DaemonState {
        try JSONDecoder().decode(DaemonState.self, from: Data(contentsOf: url))
    }

    var isAlive: Bool { kill(pid_t(pid), 0) == 0 }
    var pausedReasons: [String] { paused ?? [] }
    var uptimeSeconds: Int? { startedMs.map { Int(Date().timeIntervalSince1970) - Int($0 / 1000) } }
}

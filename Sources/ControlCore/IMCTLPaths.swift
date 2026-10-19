import Foundation

/// Where the controller keeps its per-user runtime data. Shared by every
/// target so the CLI edits the same files the daemon reads.
public enum IMCTLPaths {
    public static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imctl", isDirectory: true)
    }

    /// `imctl.sqlite`: commands, events, pause reasons, identities.
    public static var database: URL { dataDirectory.appendingPathComponent("imctl.sqlite") }
    /// `state.json`, rewritten by imctld every few seconds.
    public static var stateFile: URL { dataDirectory.appendingPathComponent("state.json") }
    /// Owner-only directory for the daemon's socket (`UnixSocketServer` verifies 0700).
    public static var runDirectory: URL { dataDirectory.appendingPathComponent("run", isDirectory: true) }
    /// Newline-delimited JSON-RPC served by `imctld run --socket` (console, `imctl call`, local Java).
    public static var socket: URL { runDirectory.appendingPathComponent("imctl.sock") }
    /// `~/Library/Logs/imctl` (launchd stdout / stderr of the daemon).
    public static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/imctl", isDirectory: true)
    }
    /// B13: files fetched for `message.sendFile`, owner-only, deleted after every attempt and swept at start.
    public static var outboxDirectory: URL { dataDirectory.appendingPathComponent("outbox", isDirectory: true) }
}

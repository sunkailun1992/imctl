import Foundation

/// Command state as seen by the controller. `unknown` is terminal: the
/// controller never retries; Java must issue a new idempotency key.
public enum CommandState: String, Codable, Equatable {
    case pending, succeeded, failed, unknown
}

/// Written to disk *before* the irreversible submit step. A `pending`
/// checkpoint found at startup means "we may have sent this" → `unknown`.
public struct SubmitCheckpoint: Codable, Equatable {
    public var id: String
    public var target: String
    public var text: String
    public var strategy: String
    /// Milliseconds since 1970 (exact round-trip, unlike Date).
    public var createdAtMs: Int
    public var state: CommandState
    public var evidence: String?
    public var reason: String?

    public init(target: String, text: String, strategy: String) {
        id = UUID().uuidString
        self.target = target
        self.text = text
        self.strategy = strategy
        createdAtMs = Int(Date().timeIntervalSince1970 * 1000)
        state = .pending
    }
}

public protocol CheckpointStore {
    func write(_ checkpoint: SubmitCheckpoint) throws
    func load(id: String) throws -> SubmitCheckpoint?
    func pending() throws -> [SubmitCheckpoint]
}

import Foundation
import GRDB

public enum CommandStateV1: String, Codable {
    case accepted, running, succeeded, failed, unknown, cancelled, expired

    public var isTerminal: Bool {
        switch self {
        case .accepted, .running: return false
        case .succeeded, .failed, .unknown, .cancelled, .expired: return true
        }
    }
}

/// One accepted command. Persisted so idempotency and crash recovery survive restarts.
public struct CommandRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commands"

    public var id: String
    public var idempotencyKey: String?
    public var method: String
    public var paramsJSON: String
    public var state: CommandStateV1
    public var createdMs: Int64
    public var updatedMs: Int64
    public var resultJSON: String?
    public var errorCode: String?
    public var errorMessage: String?
    /// Set right before the irreversible step; `running` + checkpoint after a restart means `unknown`.
    public var checkpointMs: Int64?
    /// B54: `CommandDiagnosis` JSON when a visual round ended this command without success.
    public var diagnosisJSON: String?

    enum CodingKeys: String, CodingKey {
        case id
        case idempotencyKey = "idempotency_key"
        case method
        case paramsJSON = "params_json"
        case state
        case createdMs = "created_ms"
        case updatedMs = "updated_ms"
        case resultJSON = "result_json"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case checkpointMs = "checkpoint_ms"
        case diagnosisJSON = "diagnosis_json"
    }

    public init(method: RPCMethod, paramsJSON: String, idempotencyKey: String?, nowMs: Int64) {
        id = UUID().uuidString
        self.idempotencyKey = idempotencyKey
        self.method = method.rawValue
        self.paramsJSON = paramsJSON
        state = .accepted
        createdMs = nowMs
        updatedMs = nowMs
    }

    public var isTerminal: Bool { state.isTerminal }
}

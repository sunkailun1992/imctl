import Foundation
import GRDB

/// Events are the truth; `eventId` is a monotonic cursor for replay.
public enum ControlEventKind: String, Codable, CaseIterable {
    case controllerState = "controller.state"
    case accountChanged = "account.changed"
    case conversationActivity = "conversation.activity"
    case messageObserved = "message.observed"
    case commandState = "command.state"
    // Contacts route (B7).
    case contactRequestObserved = "contact.request.observed"
    case contactRequestAccepted = "contact.request.accepted"
    case groupCreated = "group.created"
    /// B14: `group.addMembers` pressed 确定 and actually added at least one member (never for dryRun or nothing-to-add).
    case groupMembersAdded = "group.membersAdded"
}

public struct ControlEvent: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "events"

    public var eventId: Int64?
    public var tsMs: Int64
    public var kind: ControlEventKind
    public var payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case tsMs = "ts_ms"
        case kind
        case payloadJSON = "payload_json"
    }

    public init(eventId: Int64? = nil, tsMs: Int64, kind: ControlEventKind, payloadJSON: String) {
        self.eventId = eventId; self.tsMs = tsMs; self.kind = kind; self.payloadJSON = payloadJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        eventId = inserted.rowID
    }
}

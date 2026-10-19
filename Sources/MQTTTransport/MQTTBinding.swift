import ControlCore
import Foundation
import MCPTransport

/// MQTT binding of the protocol: commands arrive on `…/cmd` as JSON-RPC 2.0,
/// responses go to the MQTT 5 Response Topic (else `…/rsp`) with the
/// Correlation Data echoed; every stored event is published once to `…/evt`
/// in `event_id` order with a persisted cursor, so the event stream is
/// replayable and the response is only a convenience.
public final class MQTTBinding {
    public let settings: MQTTSettings
    public let dispatcher: RPCDispatcher
    public let store: ControlStore
    public let link: MQTTLink
    public static let cursorKey = "mqtt.lastPublishedEventId"

    public init(settings: MQTTSettings, dispatcher: RPCDispatcher, store: ControlStore, link: MQTTLink) {
        self.settings = settings
        self.dispatcher = dispatcher
        self.store = store
        self.link = link
    }

    // MARK: Commands

    /// A Response Topic outside this controller's own subtree is ignored and
    /// the default `…/rsp` is used: the per-machine broker ACL only lets the
    /// controller publish under `im/{id}/`, so honouring it would drop the reply.
    public func resolvedResponseTopic(_ requested: String?) -> String {
        guard let requested, !requested.isEmpty, requested.hasPrefix(settings.ownTopicPrefix) else { return settings.responseTopic }
        return requested
    }

    private let activityLock = NSLock()
    private var lastCommandValue: Int64?
    /// B53 readiness: when the last command arrived over MQTT; nil before the first.
    public var lastCommandMs: Int64? {
        activityLock.lock(); defer { activityLock.unlock() }
        return lastCommandValue
    }

    /// Dispatches one inbound command payload and publishes the response.
    /// Notifications (no id) produce no response. Returns the response text for logging/tests.
    @discardableResult
    public func handleCommand(payload: Data, responseTopic: String?, correlationData: Data?) throws -> String? {
        activityLock.lock(); lastCommandValue = Clock.nowMs(); activityLock.unlock()
        let line = String(decoding: payload, as: UTF8.self)
        guard let response = dispatcher.handle(line: line) else { return nil }
        try link.publish(OutboundMessage(
            topic: resolvedResponseTopic(responseTopic), payload: Data(response.utf8), qos: 1, retain: false,
            correlationData: correlationData, userProperties: [("controller_id", settings.controllerID)]
        ))
        return response
    }

    // MARK: Events

    public func lastPublishedEventId() throws -> Int64 {
        Int64(try store.value(forKey: Self.cursorKey) ?? "0") ?? 0
    }

    /// Publishes events after the cursor, advancing it after each successful publish.
    @discardableResult
    public func pumpEvents(limit: Int = 200) throws -> Int {
        let cursor = try lastPublishedEventId()
        let events = try store.events(after: cursor, limit: limit)
        var published = 0
        for event in events {
            guard let id = event.eventId else { continue }
            try link.publish(OutboundMessage(
                topic: settings.eventTopic, payload: try Self.encode(event, controllerID: settings.controllerID),
                qos: 1, retain: false, correlationData: nil,
                userProperties: [("controller_id", settings.controllerID), ("event_id", String(id)), ("kind", event.kind.rawValue)]
            ))
            try store.setValue(String(id), forKey: Self.cursorKey)
            published += 1
        }
        return published
    }

    static func encode(_ event: ControlEvent, controllerID: String) throws -> Data {
        var object: [String: Any] = [
            "eventId": event.eventId ?? 0, "tsMs": event.tsMs, "kind": event.kind.rawValue, "controllerId": controllerID,
        ]
        if let payload = try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) {
            object["payload"] = payload
        } else {
            object["payload"] = event.payloadJSON
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: State (retained + will)

    public func statePayload(online: Bool, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "online": online, "controllerId": settings.controllerID, "version": IMCTLVersion.string,
            "tsMs": Clock.nowMs(), "protocol": "im-control/0.1",
        ]
        for (k, v) in extra { object[k] = v }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

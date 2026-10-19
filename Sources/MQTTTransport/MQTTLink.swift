import Foundation

/// The little the binding needs from an MQTT client, so the binding is
/// unit-testable without a broker.
public struct OutboundMessage: Equatable {
    public var topic: String
    public var payload: Data
    public var qos: Int
    public var retain: Bool
    public var correlationData: Data?
    public var userProperties: [(String, String)]

    public init(topic: String, payload: Data, qos: Int = 1, retain: Bool = false, correlationData: Data? = nil,
                userProperties: [(String, String)] = []) {
        self.topic = topic; self.payload = payload; self.qos = qos; self.retain = retain
        self.correlationData = correlationData; self.userProperties = userProperties
    }

    public static func == (l: OutboundMessage, r: OutboundMessage) -> Bool {
        l.topic == r.topic && l.payload == r.payload && l.qos == r.qos && l.retain == r.retain
            && l.correlationData == r.correlationData
            && l.userProperties.map { "\($0.0)=\($0.1)" } == r.userProperties.map { "\($0.0)=\($0.1)" }
    }
}

public protocol MQTTLink: AnyObject {
    func publish(_ message: OutboundMessage) throws
}

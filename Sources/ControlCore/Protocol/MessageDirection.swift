/// Direction of an observed message, as carried by `message.observed`.
/// `unknown` is a legitimate value: a message whose direction cannot be
/// derived never drives an automatic reply.
public enum MessageDirection: String, Codable, Equatable {
    case inbound
    case outbound
    case unknown
}

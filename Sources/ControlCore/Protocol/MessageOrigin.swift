/// Who produced an observed message, carried by `message.observed.origin`.
public enum MessageOrigin: String, Codable, Equatable {
    /// Outbound bubble matching a `message.send` this controller made; the
    /// payload also carries that `commandId`.
    case controller
    /// Outbound bubble the controller did not send: a human replied from the
    /// phone or this desktop. This is the takeover signal; whether to go
    /// silent on the conversation is the consumer's (Java's) policy.
    case other
    /// Inbound bubble: the conversation peer wrote it.
    case peer
    /// Direction could not be derived; never drives an automatic reply.
    case unknown
}

/// A send that may have produced an outbound bubble (`succeeded` or
/// `unknown`), used to attribute observed bubbles to the controller.
public struct ControllerSend: Equatable {
    public var commandId: String
    public var target: String
    public var text: String
    public var tsMs: Int64
    /// `text` (message.send) or `file` (message.sendFile, B13).
    public var kind: String
    /// The name the client shows for a file send; nil for pictures / videos and text.
    public var fileName: String?

    public init(commandId: String, target: String, text: String, tsMs: Int64, kind: String = "text", fileName: String? = nil) {
        self.commandId = commandId; self.target = target; self.text = text; self.tsMs = tsMs; self.kind = kind; self.fileName = fileName
    }
}

/// A file row proven to come from one successful controller send. The original source is kept in the
/// local command database; it is never added to message.history or an event payload.
public struct SentFileSource: Equatable {
    public var source: SendFileSource
    public var fileName: String
    public var bytes: Int64

    public init(source: SendFileSource, fileName: String, bytes: Int64) {
        self.source = source; self.fileName = fileName; self.bytes = bytes
    }
}

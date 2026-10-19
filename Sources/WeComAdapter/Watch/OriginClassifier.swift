import ControlCore

/// Attributes an observed bubble to this controller, to someone else using
/// the same account (takeover), or to the peer. Each controller send is
/// consumed once, so a second bubble with the same text is `other`.
public struct OriginClassifier {
    public private(set) var consumed: Set<String> = []

    public init() {}

    public mutating func classify(direction: MessageDirection, text: String?, conversation: String?, sends: [ControllerSend],
                                  kind: String = "message", fileName: String? = nil) -> (origin: MessageOrigin, commandId: String?) {
        if direction == .inbound { return (.peer, nil) }
        let sameConversation: (ControllerSend) -> Bool = { send in
            guard let conversation, !conversation.isEmpty else { return true }
            return send.target == conversation
        }
        let candidates = sends.sorted { $0.tsMs < $1.tsMs }.filter { !consumed.contains($0.commandId) && sameConversation($0) }
        let match: ControllerSend?
        switch kind {
        case MessageRowKind.message.rawValue:
            guard let text, !text.isEmpty else { return direction == .outbound ? (.other, nil) : (.unknown, nil) }
            match = candidates.first { $0.kind == "text" && $0.text == text }
        case MessageRowKind.file.rawValue:
            // B13: a file card shows the name we pasted, which is evidence on its own — even when the
            // bubble sits where the direction cannot be read.
            guard let fileName, !fileName.isEmpty else { return direction == .outbound ? (.other, nil) : (.unknown, nil) }
            match = candidates.first { $0.kind == "file" && $0.fileName == fileName }
        default:
            // A pasted picture / video carries neither text nor a name: only a bubble on our own side of the
            // pane can be ours, and only a send whose file is of that kind (a peer's picture must not consume
            // the pdf we sent — review 2026-09-22).
            guard direction == .outbound else { return (.unknown, nil) }
            let wanted = kind == MessageRowKind.video.rawValue ? "video" : "image"
            match = candidates.first { $0.kind == "file" && FileKind.info(forFileName: $0.fileName ?? "")?.kind == wanted }
        }
        if let match {
            consumed.insert(match.commandId)
            return (.controller, match.commandId)
        }
        return direction == .outbound ? (.other, nil) : (.unknown, nil)
    }
}

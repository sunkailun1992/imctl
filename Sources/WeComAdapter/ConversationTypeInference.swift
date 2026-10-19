import ControlCore

/// Derives a conversation's kind only from evidence the client shows; without
/// evidence the answer is `unknown`, which no type rule can allow. Marker texts
/// are the 5.0.x list tags and the "姓名@公司" title form of external company
/// contacts; both are calibrated against the test group during B4 live checks.
/// `internal` is never inferred (colleagues carry no tag).
public enum ConversationTypeInference {
    public static let customerMarkers: Set<String> = ["微信"]
    public static let groupMarkers: Set<String> = ["外部", "外部群"]

    /// From the conversation table row alone (before opening it).
    public static func infer(row: ConversationRow) -> ConversationType {
        if row.markers.contains(where: customerMarkers.contains) { return .customer }
        if row.markers.contains(where: groupMarkers.contains) { return .group }
        if let title = row.title, title.contains("@"), !title.hasPrefix("@") { return .customer }
        return .unknown
    }

    /// From the open conversation: a member count in the header or any sender
    /// label proves a group; otherwise fall back to the row.
    public static func infer(header: ConversationHeader?, messages: [MessageRow], row: ConversationRow?) -> ConversationType {
        if header?.memberCount != nil { return .group }
        if messages.contains(where: { $0.kind == .message && $0.senderLabel != nil }) { return .group }
        if let row { return infer(row: row) }
        return .unknown
    }
}

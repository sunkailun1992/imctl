import Foundation

/// The active-conversation header. Group chats append the member count,
/// "群名(12)", which the conversation table's title column does not show; the
/// normalised `title` is what target resolution and selection compare.
public struct ConversationHeader: Equatable {
    public var raw: String
    public var title: String
    public var memberCount: Int?

    public init(raw: String, title: String, memberCount: Int?) {
        self.raw = raw; self.title = title; self.memberCount = memberCount
    }

    private static let pattern = try? NSRegularExpression(pattern: "^(.*?)\\s*[（(]([0-9]+)[)）]$")

    public static func parse(_ raw: String) -> ConversationHeader {
        guard let pattern,
              let m = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let titleRange = Range(m.range(at: 1), in: raw), let countRange = Range(m.range(at: 2), in: raw),
              let count = Int(raw[countRange]), !raw[titleRange].isEmpty else {
            return ConversationHeader(raw: raw, title: raw, memberCount: nil)
        }
        return ConversationHeader(raw: raw, title: String(raw[titleRange]), memberCount: count)
    }
}

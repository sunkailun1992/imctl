import Foundation

/// How a caller names a conversation in `message.send.target` and
/// `conversation.read.target`: a platform id (resolved through the identity
/// bridge) or a bare title (development only; a title is not an identity).
public enum TargetRef: Equatable, CustomStringConvertible {
    case title(String)
    case chatId(String)
    case externalUserId(String)

    public static let chatIdPrefix = "chatId:"
    public static let externalUserIdPrefix = "externalUserId:"

    /// `chatId:<id>` / `externalUserId:<id>` / anything else is a title. An
    /// empty id after a prefix stays a literal title so it fails with
    /// TARGET_NOT_FOUND instead of matching anything.
    public static func parse(_ raw: String) -> TargetRef {
        if raw.hasPrefix(chatIdPrefix) {
            let id = raw.dropFirst(chatIdPrefix.count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? .title(raw) : .chatId(id)
        }
        if raw.hasPrefix(externalUserIdPrefix) {
            let id = raw.dropFirst(externalUserIdPrefix.count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? .title(raw) : .externalUserId(id)
        }
        return .title(raw)
    }

    public var wire: String {
        switch self {
        case .title(let t): return t
        case .chatId(let id): return Self.chatIdPrefix + id
        case .externalUserId(let id): return Self.externalUserIdPrefix + id
        }
    }

    public var isTitle: Bool { if case .title = self { return true }; return false }
    public var description: String { wire }
}

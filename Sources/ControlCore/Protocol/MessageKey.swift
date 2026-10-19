import CryptoKit
import Foundation

/// Stable per-message key carried by `message.observed` and `message.history`
/// so a consumer can deduplicate what it saw live against what it read back.
/// The row index is deliberately not an input: loading older history prepends
/// rows (B3), which shifts every index but changes none of these fields.
public enum MessageKey {
    public static let hexLength = 16

    public static func make(conversation: String, sender: String?, timeLabel: String?, text: String, ordinal: Int) -> String {
        let material = [conversation, sender ?? "", timeLabel ?? "", text, String(ordinal)].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(hexLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// Keys for rows in display order. Rows with the same (sender, timeLabel,
    /// text) get increasing ordinals, so two identical "ok" messages differ.
    public static func assign<T>(_ items: [T], conversation: String,
                                 sender: (T) -> String?, timeLabel: (T) -> String?, text: (T) -> String) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let tuple = [sender(item) ?? "", timeLabel(item) ?? "", text(item)].joined(separator: "\u{1F}")
            let ordinal = seen[tuple, default: 0]
            seen[tuple] = ordinal + 1
            return make(conversation: conversation, sender: sender(item), timeLabel: timeLabel(item), text: text(item), ordinal: ordinal)
        }
    }
}

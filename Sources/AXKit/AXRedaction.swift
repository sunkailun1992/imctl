import CryptoKit
import Foundation

/// Decides which text in a recorded tree may be committed. UI chrome (button
/// and menu labels), time/date labels and an explicit allowlist survive;
/// everything else becomes a salted, non-reversible placeholder that stays
/// consistent within one dump so structural relations (selected row title ==
/// window title) still hold in fixtures.
public struct AXRedactionPolicy {
    public var keepTexts: Set<String>
    public var keepRoles: Set<String>
    public var keepPattern: NSRegularExpression?
    public var salt: String

    public static let defaultKeepRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuItem",
        "AXMenuBar", "AXMenuBarItem", "AXTabGroup", "AXToolbar", "AXSplitter", "AXScrollBar", "AXSearchField",
        "AXApplication",
    ]

    /// Time/date/count labels (digits, separators, Chinese date words) and
    /// the structural summaries `AXAttributeValue.summary` produces for
    /// booleans and element references.
    public static let defaultKeepPattern = try? NSRegularExpression(
        pattern: "^(?:[0-9０-９:：/\\-\\.\\s年月日时分秒钟前小刚昨天今天上午下午周星期一二三四五六日]+|true|false|<element>|<[0-9]+ elements>|<unknown: [^>]*>)$"
    )

    public init(keepTexts: Set<String>, keepRoles: Set<String>, keepPattern: NSRegularExpression?, salt: String) {
        self.keepTexts = keepTexts
        self.keepRoles = keepRoles
        self.keepPattern = keepPattern
        self.salt = salt
    }

    public static func `default`(keepTexts: Set<String>, salt: String = UUID().uuidString) -> AXRedactionPolicy {
        AXRedactionPolicy(keepTexts: keepTexts, keepRoles: defaultKeepRoles, keepPattern: defaultKeepPattern, salt: salt)
    }

    /// Seven or more consecutive digits look like a phone number: never kept, whatever the keep pattern says (B12).
    static let longDigitRun = try? NSRegularExpression(pattern: "[0-9０-９]{7,}")

    public func redact(_ text: String) -> String {
        if text.isEmpty || keepTexts.contains(text) { return text }
        let range = NSRange(text.startIndex..., in: text)
        if let pattern = keepPattern, pattern.firstMatch(in: text, range: range) != nil,
           Self.longDigitRun?.firstMatch(in: text, range: range) == nil {
            return text
        }
        let digest = SHA256.hash(data: Data((salt + "\u{0}" + text).utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "«\(hex)»"
    }
}

public extension AXNode {
    func redacted(_ policy: AXRedactionPolicy) -> AXNode {
        var out = self
        let chrome = role.map(policy.keepRoles.contains) ?? false
        if !chrome {
            out.title = title.map(policy.redact)
            out.description = description.map(policy.redact)
            if case .string(let s)? = value { out.value = .string(policy.redact(s)) }
        }
        out.help = help.map(policy.redact)
        out.extra = extra.mapValues(policy.redact)
        out.children = children.map { $0.redacted(policy) }
        return out
    }
}

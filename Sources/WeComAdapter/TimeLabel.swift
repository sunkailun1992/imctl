import Foundation

/// Recognises the short time/date labels WeCom shows next to conversations
/// and messages ("9:18", "9/2", "昨天", "星期三", "2分钟前", "刚刚").
enum TimeLabel {
    private static let pattern = try? NSRegularExpression(
        pattern: "^[0-9０-９:：/\\-\\.\\s年月日时分秒钟前小刚昨天今天上午下午周星期一二三四五六日]+$"
    )

    static func matches(_ text: String) -> Bool {
        guard !text.isEmpty, let pattern else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

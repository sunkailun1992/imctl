import Foundation

/// Turns the time labels the client prints between messages into instants:
/// "21:37", "昨天 21:37", "前天 9:06", "星期一 21:37", "9月15日 21:37",
/// "2025年9月15日 21:37", "9/15 21:37", with an optional 上午 / 下午. Used to
/// bracket a media row between its neighbours' labels (B10 picture matching).
enum MessageTimeLabel {
    /// Key material uses the instant's UTC minute, not WeCom's relative
    /// display label: the same row can change from "16:36" to "昨天 16:36"
    /// at midnight. An unrecognized label remains unchanged rather than
    /// inventing a date; `MessageRow.timeLabel` still carries the UI text.
    static func canonicalKeyTime(_ label: String?, now: Date, calendar: Calendar) -> String? {
        guard let label else { return nil }
        guard let instant = parse(label, now: now, calendar: calendar) else { return label }
        let clockOnly = label.trimmingCharacters(in: .whitespaces)
            .range(of: #"^(?:(?:上午|下午|晚上|凌晨)\s*)?\d{1,2}[:：]\d{2}$"#, options: .regularExpression) != nil
        // At a date rollover, a not-yet-relabelled bare clock could resolve
        // to hours in the future. Resolve that ambiguous clock to yesterday.
        let resolved = clockOnly && instant > now.addingTimeInterval(120)
            ? (calendar.date(byAdding: .day, value: -1, to: instant) ?? instant) : instant
        return "utc-minute:\(Int64(floor(resolved.timeIntervalSince1970 / 60)))"
    }

    /// Candidate for a key written before absolute-minute keying, when an
    /// observed "16:36" row is now labelled "昨天 16:36". This is only a
    /// candidate: callers must verify the old binding's date and row identity.
    static func legacyBareClock(_ label: String?) -> String? {
        guard let label else { return nil }
        let text = label.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("昨天 ") else { return nil }
        let clock = String(text.dropFirst("昨天 ".count))
        guard clock.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
        return clock
    }

    static func parse(_ label: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = label.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
        guard let clockRange = text.range(of: #"(\d{1,2}):(\d{2})"#, options: .regularExpression) else { return nil }
        let clock = text[clockRange].split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]), hour < 24, minute < 60 else { return nil }
        let datePart = text[..<clockRange.lowerBound].trimmingCharacters(in: .whitespaces)
        if datePart.contains("下午") || datePart.contains("晚上"), hour < 12 { hour += 12 }
        let dateWords = datePart.replacingOccurrences(of: "上午", with: "").replacingOccurrences(of: "下午", with: "")
            .replacingOccurrences(of: "晚上", with: "").replacingOccurrences(of: "凌晨", with: "").trimmingCharacters(in: .whitespaces)
        var day = calendar.startOfDay(for: now)
        if dateWords.isEmpty || dateWords == "今天" {
            // today
        } else if dateWords == "昨天" {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        } else if dateWords == "前天" {
            day = calendar.date(byAdding: .day, value: -2, to: day)!
        } else if let weekday = weekday(dateWords) {
            // the most recent such weekday (the client only uses names inside the last week)
            let today = calendar.component(.weekday, from: day)
            var back = (today - weekday + 7) % 7
            if back == 0 { back = 7 }
            day = calendar.date(byAdding: .day, value: -back, to: day)!
        } else if let ymd = yearMonthDay(dateWords, now: now, calendar: calendar) {
            day = ymd
        } else {
            return nil
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static func weekday(_ s: String) -> Int? {
        let names = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        for prefix in ["星期", "周"] where s.hasPrefix(prefix) { return names[String(s.dropFirst(prefix.count))] }
        return nil
    }

    private static func yearMonthDay(_ s: String, now: Date, calendar: Calendar) -> Date? {
        let digits = s.replacingOccurrences(of: "年", with: "/").replacingOccurrences(of: "月", with: "/").replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: "-", with: "/").replacingOccurrences(of: ".", with: "/")
        let parts = digits.split(separator: "/").compactMap { Int($0) }
        var c = calendar.dateComponents([.year], from: now)
        switch parts.count {
        case 2: c.month = parts[0]; c.day = parts[1]
        case 3: c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        default: return nil
        }
        guard let d = calendar.date(from: c) else { return nil }
        // a month/day without a year that lands in the future means last year
        return d > now && parts.count == 2 ? calendar.date(byAdding: .year, value: -1, to: d) : d
    }
}

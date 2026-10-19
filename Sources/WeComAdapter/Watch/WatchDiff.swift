public enum WatchEvent: Equatable, Codable {
    case activeChanged(from: String?, to: String?)
    case conversationChanged(index: Int, title: String?, fields: [String])
    case conversationCountChanged(from: Int, to: Int)
    case messageAdded(index: Int, direction: String, timeLabel: String?)
    case messageChanged(index: Int, fields: [String])
    case messageCountChanged(from: Int, to: Int)
    /// Older rows appeared above the existing ones: history loaded by a scroll
    /// (ours via `message.history` scrollback, or a human's). Not new messages,
    /// never reported as observations.
    case messagesPrepended(count: Int)
    case composerChanged(from: Int, to: Int)
    case newCustomersBadgeChanged(from: Int, to: Int)

    public var summary: String {
        switch self {
        case .activeChanged(let f, let t): return "active \(f ?? "-") -> \(t ?? "-")"
        case .conversationChanged(let i, let title, let fields): return "conversation #\(i) \(title ?? "-") changed \(fields.joined(separator: ","))"
        case .conversationCountChanged(let f, let t): return "conversation count \(f) -> \(t)"
        case .messageAdded(let i, let d, let t): return "message #\(i) added dir=\(d) time=\(t ?? "-")"
        case .messageChanged(let i, let fields): return "message #\(i) changed \(fields.joined(separator: ","))"
        case .messageCountChanged(let f, let t): return "message count \(f) -> \(t)"
        case .messagesPrepended(let n): return "messages prepended \(n) (history loaded)"
        case .composerChanged(let f, let t): return "composer length \(f) -> \(t)"
        case .newCustomersBadgeChanged(let f, let t): return "new-customers badge \(f) -> \(t)"
        }
    }
}

public enum WatchDiff {
    /// Events worth reporting as observations. After a conversation switch the
    /// visible history is a new baseline, not a burst of new messages, so
    /// message-level events are dropped for that cycle.
    public static func observable(_ events: [WatchEvent]) -> [WatchEvent] {
        let switched = events.contains { if case .activeChanged = $0 { return true }; return false }
        guard switched else { return events }
        return events.filter {
            switch $0 {
            case .messageAdded, .messageChanged, .messageCountChanged, .messagesPrepended: return false
            default: return true
            }
        }
    }

    /// Rows inserted at the top: the new list ends with the old list (by text
    /// and direction) but does not start with it. nil for an append or an
    /// unrelated change. Identical head and tail (repeated texts) counts as an
    /// append, the common case for a genuinely new message.
    public static func prependedCount(old: [WatchSnapshot.Message], new: [WatchSnapshot.Message]) -> Int? {
        let k = new.count - old.count
        guard k > 0, !old.isEmpty else { return nil }
        func same(_ a: WatchSnapshot.Message, _ b: WatchSnapshot.Message) -> Bool { a.text == b.text && a.direction == b.direction && a.fileName == b.fileName }
        let tailMatches = zip(old, new.dropFirst(k)).allSatisfy(same)
        let headMatches = zip(old, new).allSatisfy(same)
        return tailMatches && !headMatches ? k : nil
    }

    public static func compare(_ old: WatchSnapshot, _ new: WatchSnapshot) -> [WatchEvent] {
        var events: [WatchEvent] = []
        if old.active != new.active { events.append(.activeChanged(from: old.active, to: new.active)) }
        if old.newCustomersBadge != new.newCustomersBadge {
            events.append(.newCustomersBadgeChanged(from: old.newCustomersBadge, to: new.newCustomersBadge))
        }

        if old.conversations.count != new.conversations.count {
            events.append(.conversationCountChanged(from: old.conversations.count, to: new.conversations.count))
        }
        for (a, b) in zip(old.conversations, new.conversations) {
            var fields: [String] = []
            if a.title != b.title { fields.append("title") }
            if a.preview != b.preview { fields.append("preview") }
            if a.timeLabel != b.timeLabel { fields.append("timeLabel") }
            if a.badge != b.badge { fields.append("badge") }
            if a.selected != b.selected { fields.append("selected") }
            if a.type != b.type { fields.append("type") }
            if !fields.isEmpty { events.append(.conversationChanged(index: b.index, title: b.title, fields: fields)) }
        }

        if let k = prependedCount(old: old.messages, new: new.messages) {
            events.append(.messagesPrepended(count: k))
            for (a, b) in zip(old.messages, new.messages.dropFirst(k)) {
                if let change = messageChange(a, b) { events.append(change) }
            }
        } else {
            if old.messages.count != new.messages.count {
                events.append(.messageCountChanged(from: old.messages.count, to: new.messages.count))
            }
            for (a, b) in zip(old.messages, new.messages) {
                if let change = messageChange(a, b) { events.append(change) }
            }
            for m in new.messages.dropFirst(old.messages.count) {
                events.append(.messageAdded(index: m.index, direction: m.direction, timeLabel: m.timeLabel))
            }
        }

        if old.composerLength != new.composerLength {
            events.append(.composerChanged(from: old.composerLength, to: new.composerLength))
        }
        return events
    }

    private static func messageChange(_ a: WatchSnapshot.Message, _ b: WatchSnapshot.Message) -> WatchEvent? {
        var fields: [String] = []
        if a.text != b.text { fields.append("text") }
        if a.timeLabel != b.timeLabel { fields.append("timeLabel") }
        if a.direction != b.direction { fields.append("direction") }
        return fields.isEmpty ? nil : .messageChanged(index: b.index, fields: fields)
    }
}

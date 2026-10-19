import AXKit
import ControlCore
import Foundation

/// Read-only facade over a located WeCom window.
public struct WeComReader {
    public let layout: WeComLayout
    public var conversationParser = ConversationRowParser()
    public var messageParser = MessageRowParser()

    public init(window: AXElement) throws {
        layout = try WeComLayout.locate(in: window)
    }

    public func conversations() throws -> [ConversationRow] {
        try conversationParser.parse(table: layout.conversationTable)
    }

    public func activeConversationHeader() throws -> ConversationHeader? {
        if let title = layout.activeTitle {
            guard let raw = try title.valueString() ?? title.title() else { return nil }
            return ConversationHeader.parse(raw)
        }
        // Panes the client renders without a readable header (2026-09-15, 5.0.11:
        // some conversations expose no message table, composer or title at all):
        // the selected list row is the only evidence of what is active.
        guard let selected = try conversations().first(where: \.selected), let title = selected.title else { return nil }
        return ConversationHeader.parse(title)
    }

    /// The normalised title (group member count removed).
    public func activeConversationTitle() throws -> String? {
        try activeConversationHeader()?.title
    }

    /// The selected row, else the row whose title equals the active title.
    public func activeConversationRow() throws -> ConversationRow? {
        let rows = try conversations()
        if let selected = rows.first(where: \.selected) { return selected }
        guard let active = try activeConversationTitle() else { return nil }
        return rows.first { $0.title == active }
    }

    public func activeConversationType() throws -> ConversationType {
        ConversationTypeInference.infer(header: try activeConversationHeader(), messages: try messages(), row: try activeConversationRow())
    }

    /// Every row of the message table (system notices and time separators
    /// included); empty when no conversation is active (no message table).
    public func messages() throws -> [MessageRow] {
        guard let table = layout.messageTable, let frame = layout.messageTableFrame else { return [] }
        return try messageParser.parse(table: table, tableFrame: frame, images: layout.messageImages)
    }

    /// Message rows only (system notices, time separators and empty rows
    /// dropped), each with its `messageKey`. Indices stay table indices.
    public func chatMessages(conversationTitle: String? = nil, now: Date = Date(), calendar: Calendar = .current) throws -> [MessageRow] {
        let conversation = try conversationTitle ?? activeConversationTitle() ?? ""
        return chatMessages(from: try messages(), conversationTitle: conversation, now: now, calendar: calendar)
    }

    /// Normalize a single, already parsed AX table. Read-only probes also show
    /// system and time rows, so they can reuse this result for keys without
    /// walking the same cross-process message table a second time.
    public func chatMessages(from parsedRows: [MessageRow], conversationTitle: String,
                             now: Date = Date(), calendar: Calendar = .current) -> [MessageRow] {
        var rows = parsedRows.filter { [.message, .media, .file, .video].contains($0.kind) }
        // The file transfer assistant is the current account's self chat. Its
        // bubbles can have no readable side (or appear on the left in AX), but
        // every message in this exact conversation was sent by this account.
        // Apply this before history and watcher consume the same rows.
        if conversationTitle == WeComClient.fileTransferAssistantTitle {
            for i in rows.indices { rows[i].direction = .outbound }
        }
        let keys = MessageKey.assign(rows, conversation: conversationTitle, sender: \.senderLabel,
                                     timeLabel: { MessageTimeLabel.canonicalKeyTime($0.timeLabel, now: now, calendar: calendar) },
                                     text: { $0.text ?? $0.fileName ?? "" })
        // A failed AXValue read can hide the text of a row that participates in
        // MessageKey's per-tuple occurrence count. Keys at or after that row
        // cannot be trusted until a complete read succeeds.
        let firstPartial = rows.firstIndex { $0.readError != nil } ?? rows.endIndex
        for i in rows.indices where i < firstPartial { rows[i].messageKey = keys[i] }
        return rows
    }

    /// nil when the active conversation has no composer.
    public func composerValue() throws -> String? {
        try layout.composer?.valueString()
    }
}

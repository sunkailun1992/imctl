import AXKit
import ControlCore
import Foundation

/// What the watcher compares between polls. Text is carried verbatim here
/// and redacted only at output time. Only message rows are kept (system
/// notices and time separators never become observations).
public struct WatchSnapshot: Equatable, Codable {
    /// Cheap evidence that the active message table has not changed since a
    /// complete read. Row handles are stable across AXChildren reads; comparing
    /// the whole vector also catches prepends and virtualized row replacements.
    struct MessageFingerprint: Equatable {
        var activeTitle: String?
        var activeMemberCount: Int?
        var selectedHandle: AXElementHandle?
        var selectedTitle: String?
        var selectedPreview: String?
        var selectedTimeLabel: String?
        var selectedMarkers: [String]
        var selectedAvatarTitle: String?
        var tableHandle: AXElementHandle?
        var rowHandles: [AXElementHandle]
    }

    struct Capture {
        var snapshot: WatchSnapshot
        var fingerprint: MessageFingerprint
    }

    public struct Conversation: Equatable, Codable {
        public var index: Int
        public var title: String?
        public var preview: String?
        public var timeLabel: String?
        public var badge: String?
        public var selected: Bool
        /// `ConversationType` inferred from the row's markers alone.
        public var type: String
    }

    public struct Message: Equatable, Codable {
        public var index: Int
        public var text: String?
        public var timeLabel: String?
        public var direction: String
        public var y: Double
        public var sender: String? = nil
        public var messageKey: String = ""
        /// `MessageRowKind` raw value: `message`, `media` (a bubble without accessible text), `file` or `video`.
        public var kind: String = MessageRowKind.message.rawValue
        /// file rows: the name, size label and icon type word; nil otherwise.
        public var fileName: String? = nil
        public var fileSize: String? = nil
        public var fileType: String? = nil
        /// video rows: the duration label ("01:14"); nil otherwise.
        public var duration: String? = nil
        /// `media` rows only: `image` when the latest selected-conversation preview says `[图片]`,
        /// otherwise `unknown`. Older media rows cannot be classified from AX alone.
        public var mediaType: String? = nil
    }

    public var active: String?
    /// `ConversationType` of the active conversation (header, senders, row).
    public var activeType: String = ConversationType.unknown.rawValue
    public var activeMemberCount: Int? = nil
    public var conversations: [Conversation]
    public var messages: [Message]
    public var composerLength: Int
    /// 通讯录 badge count read from the navigation rail: 0 when none; while the rail cannot be
    /// attributed, the last attributed count (0 before any), so an unreadable poll is not a change.
    public var newCustomersBadge: Int = 0
    /// Why the rail's 通讯录 badge could not be attributed (`RailBadges.Reading.problem`); nil when read.
    public var newCustomersBadgeProblem: String? = nil

    public static func take(_ reader: WeComReader) throws -> WatchSnapshot {
        try capture(reader).snapshot
    }

    /// The watcher reuses the last complete message parse only when the active
    /// title, selected preview and time, and every table row handle still match.
    /// Conversation metadata, composer and badge are always read afresh.
    static func capture(_ reader: WeComReader, previous: WatchSnapshot? = nil,
                        previousFingerprint: MessageFingerprint? = nil, forceMessages: Bool = false,
                        resolveVisualDirections: ((WeComReader, inout [MessageRow], [Int]) -> Void)? = nil) throws -> Capture {
        let header = try reader.activeConversationHeader()
        let rows = try reader.conversations()
        let activeRow = rows.first(where: \.selected) ?? rows.first { $0.title == header?.title }
        let fingerprint = MessageFingerprint(
            activeTitle: header?.title, activeMemberCount: header?.memberCount,
            selectedHandle: activeRow?.handle, selectedTitle: activeRow?.title,
            selectedPreview: activeRow?.preview, selectedTimeLabel: activeRow?.timeLabel,
            selectedMarkers: activeRow?.markers ?? [], selectedAvatarTitle: activeRow?.avatarTitle,
            tableHandle: reader.layout.messageTable?.handle,
            rowHandles: try reader.layout.messageTable?.children().map(\.handle) ?? []
        )
        let messages: [Message]
        let activeType: String
        if !forceMessages, previousFingerprint == fingerprint, let previous {
            messages = previous.messages
            activeType = previous.activeType
        } else {
            var chat = try reader.chatMessages(conversationTitle: header?.title)
            // WatchDiff must never treat an incomplete row as a new message or a
            // change to a previous one. Keep the previous snapshot and retry on
            // the next poll instead of publishing a fabricated observation.
            if chat.contains(where: { $0.readError != nil }) {
                throw WeComError.region("incomplete message AXValue")
            }
            MessageMediaTypeInference.enrichLatest(&chat, selected: activeRow, activeTitle: header?.title)
            // A later AX read may again expose only the timestamp of an image
            // already resolved from a window frame. Keep that evidence by its
            // stable key so a history prepend cannot look like new messages
            // merely because the old row reverted to `unknown`.
            if let previous, previous.active == header?.title {
                let known = Dictionary(grouping: previous.messages.filter { !$0.messageKey.isEmpty && $0.direction != MessageDirection.unknown.rawValue }, by: \.messageKey)
                for i in chat.indices where chat[i].kind == .media && chat[i].direction == .unknown {
                    guard let key = chat[i].messageKey,
                          let matches = known[key], matches.count == 1,
                          let direction = MessageDirection(rawValue: matches[0].direction) else { continue }
                    chat[i].direction = direction
                }
            }
            // The first page and a switched conversation are history baselines.
            // Only genuinely appended rows may generate message.observed, so
            // only those need a visual fallback before the event is drafted.
            if let previous, previous.active == header?.title,
               chat.count > previous.messages.count,
               zip(previous.messages, chat).allSatisfy({ $0.messageKey == $1.messageKey }),
               let resolveVisualDirections {
                resolveVisualDirections(reader, &chat, Array(previous.messages.count..<chat.count))
            }
            activeType = ConversationTypeInference.infer(header: header, messages: chat, row: activeRow).rawValue
            messages = chat.map {
                Message(index: $0.index, text: $0.text, timeLabel: $0.timeLabel, direction: $0.direction.rawValue, y: $0.frame.minY,
                        sender: $0.senderLabel, messageKey: $0.messageKey ?? "", kind: $0.kind.rawValue,
                        fileName: $0.fileName, fileSize: $0.fileSize, fileType: $0.fileType, duration: $0.duration,
                        mediaType: $0.mediaType?.rawValue)
            }
        }
        let rail = RailBadges.read(window: reader.layout.window)
        let snapshot = WatchSnapshot(
            active: header?.title,
            activeType: activeType,
            activeMemberCount: header?.memberCount,
            conversations: rows.map {
                Conversation(index: $0.index, title: $0.title, preview: $0.preview, timeLabel: $0.timeLabel, badge: $0.badge, selected: $0.selected,
                             type: ConversationTypeInference.infer(row: $0).rawValue)
            },
            messages: messages,
            composerLength: try reader.composerValue()?.count ?? 0,
            newCustomersBadge: rail.contacts ?? previous?.newCustomersBadge ?? 0,
            newCustomersBadgeProblem: rail.problem
        )
        return Capture(snapshot: snapshot, fingerprint: fingerprint)
    }
}

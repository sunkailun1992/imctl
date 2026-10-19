import AXKit
import ControlCore
import Foundation

/// One event the watcher wants persisted; the daemon appends it to the store.
public struct WatchDraft: Equatable {
    public var kind: ControlEventKind
    public var payload: [String: String]

    public init(kind: ControlEventKind, payload: [String: String]) {
        self.kind = kind; self.payload = payload
    }
}

/// Poll-and-diff core shared by `imctld`: locates the window lazily, diffs
/// snapshots, attributes outbound bubbles, and decides when to re-locate.
/// No timers, no store, no observer wiring: the daemon owns those and gets
/// `onRelocated` so it can (re)subscribe an AXObserver to the fresh layout.
public final class WatchEngine {
    public var readerProvider: () throws -> WeComReader
    public var recentSends: () -> [ControllerSend]
    /// Injected for tests; the default is an on-demand, one-frame visual
    /// fallback for newly appended AX-unknown media only.
    public var resolveVisualDirections: (WeComReader, inout [MessageRow], [Int]) -> Void = VisualDirectionResolver.resolve
    /// Reverse identity lookup (title → bridge rows) so event payloads can
    /// carry `chatId` / `externalUserId` when the bridge knows the title.
    public var identityLookup: (String) -> [Identity] = { _ in [] }
    /// Re-locate the layout every N successful polls so a rebuilt view never goes unnoticed.
    public var relocateEvery = 60
    /// Bound the fallback delay for an in-place message edit whose row handle
    /// and conversation preview did not change and sent no AX notification.
    public var fullMessageReadEvery = 10
    /// Polls between re-locations while the active pane exposes no message
    /// table or composer (each re-location also re-subscribes AX notifications).
    public var relocateWhenAbsentEvery = 5
    private var absentPolls = 0
    public var onRelocated: ((WeComLayout) -> Void)?
    public private(set) var reader: WeComReader?
    public private(set) var previous: WatchSnapshot?
    private var messageFingerprint: WatchSnapshot.MessageFingerprint?
    public private(set) var polls = 0
    public private(set) var relocations = 0
    public private(set) var errors = 0
    private var classifier = OriginClassifier()

    public init(readerProvider: @escaping () throws -> WeComReader, recentSends: @escaping () -> [ControllerSend] = { [] }) {
        self.readerProvider = readerProvider
        self.recentSends = recentSends
    }

    public var active: String? { previous?.active }
    public var newCustomersBadge: Int { previous?.newCustomersBadge ?? 0 }
    public var newCustomersBadgeProblem: String? { previous?.newCustomersBadgeProblem }
    public var conversationCount: Int { previous?.conversations.count ?? 0 }

    /// Forces a re-location on the next poll.
    public func invalidate() { reader = nil; messageFingerprint = nil }

    /// One observation cycle. Throws when the client is unreachable (the
    /// caller decides what that means); the layout is dropped so the next
    /// poll re-locates.
    public func poll(forceMessages: Bool = false) throws -> [WatchDraft] {
        do {
            if reader == nil {
                let located = try readerProvider()
                reader = located
                relocations += 1
                onRelocated?(located.layout)
            }
            guard let reader else { return [] }
            let periodic = fullMessageReadEvery <= 1 || (polls + 1) % fullMessageReadEvery == 0
            let capture = try WatchSnapshot.capture(
                reader, previous: previous, previousFingerprint: messageFingerprint,
                forceMessages: forceMessages || periodic || messageFingerprint == nil,
                resolveVisualDirections: resolveVisualDirections
            )
            let snapshot = capture.snapshot
            messageFingerprint = capture.fingerprint
            polls += 1
            var drafts: [WatchDraft] = []
            var switched = false
            if let previous {
                let events = WatchDiff.compare(previous, snapshot)
                switched = events.contains { if case .activeChanged = $0 { return true }; return false }
                var sends: [ControllerSend]?
                for event in WatchDiff.observable(events) {
                    if case .messageAdded = event, sends == nil { sends = recentSends() }
                    if let draft = draft(for: event, snapshot: snapshot, sends: sends ?? []) { drafts.append(draft) }
                }
            }
            previous = snapshot
            // Re-locate when the client changed shape: a conversation switch,
            // regions that were absent (fresh launch has no message table), or
            // simply every `relocateEvery` polls.
            let absent = reader.layout.messageTable == nil || reader.layout.composer == nil
            absentPolls = absent ? absentPolls + 1 : 0
            if switched || (absent && absentPolls % relocateWhenAbsentEvery == 0) || polls % relocateEvery == 0 {
                self.reader = nil
                messageFingerprint = nil
            }
            return drafts
        } catch {
            errors += 1
            reader = nil
            messageFingerprint = nil
            throw error
        }
    }

    /// `chatId` / `externalUserId` for a title the bridge knows; empty otherwise.
    private func ids(for title: String?) -> [String: String] {
        guard let title, !title.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for identity in identityLookup(title) {
            switch identity.kind {
            case .group: if out["chatId"] == nil { out["chatId"] = identity.id }
            case .customer: if out["externalUserId"] == nil { out["externalUserId"] = identity.id }
            }
        }
        return out
    }

    /// Same rule as `TargetResolver`: client evidence first; when it says
    /// nothing, the bridge's kind (a group chat_id, a customer external_userid).
    private func bridgedType(_ type: String, ids: [String: String]) -> String {
        guard type == ConversationType.unknown.rawValue else { return type }
        if ids["chatId"] != nil { return ConversationType.group.rawValue }
        if ids["externalUserId"] != nil { return ConversationType.customer.rawValue }
        return type
    }

    private func draft(for event: WatchEvent, snapshot: WatchSnapshot, sends: [ControllerSend]) -> WatchDraft? {
        switch event {
        case .conversationChanged(let index, let title, let fields):
            let row = snapshot.conversations.first { $0.index == index }
            let ids = ids(for: title)
            var payload: [String: String] = [
                "title": title ?? "", "fields": fields.joined(separator: ","),
                "preview": row?.preview ?? "", "timeLabel": row?.timeLabel ?? "", "badge": row?.badge ?? "",
                "conversationType": bridgedType(row?.type ?? ConversationType.unknown.rawValue, ids: ids),
            ]
            payload.merge(ids) { current, _ in current }
            return WatchDraft(kind: .conversationActivity, payload: payload)
        case .messageAdded(let index, let direction, let timeLabel):
            let message = snapshot.messages.first { $0.index == index }
            let attribution = classifier.classify(direction: MessageDirection(rawValue: direction) ?? .unknown,
                                                  text: message?.text, conversation: snapshot.active, sends: sends,
                                                  kind: message?.kind ?? "message", fileName: message?.fileName)
            let ids = ids(for: snapshot.active)
            var payload: [String: String] = [
                "conversation": snapshot.active ?? "", "direction": direction, "timeLabel": timeLabel ?? "",
                "text": message?.text ?? "", "origin": attribution.origin.rawValue,
                "messageKey": message?.messageKey ?? "",
                "conversationType": bridgedType(snapshot.activeType, ids: ids),
                "kind": message?.kind ?? MessageRowKind.message.rawValue,
            ]
            // Absent fields stay absent: no sender label means no `sender` key.
            if let sender = message?.sender, !sender.isEmpty { payload["sender"] = sender }
            if let id = attribution.commandId { payload["commandId"] = id }
            if let v = message?.fileName { payload["fileName"] = v }
            if let v = message?.fileSize { payload["fileSize"] = v }
            if let v = message?.fileType { payload["fileType"] = v }
            if let v = message?.duration { payload["duration"] = v }
            if let v = message?.mediaType { payload["mediaType"] = v }
            payload.merge(ids) { current, _ in current }
            return WatchDraft(kind: .messageObserved, payload: payload)
        case .activeChanged(let from, let to):
            let ids = ids(for: to)
            var payload: [String: String] = ["activeFrom": from ?? "", "activeTo": to ?? "", "conversationType": bridgedType(snapshot.activeType, ids: ids)]
            payload.merge(ids) { current, _ in current }
            return WatchDraft(kind: .conversationActivity, payload: payload)
        case .newCustomersBadgeChanged(_, let to):
            return WatchDraft(kind: .controllerState, payload: ["newCustomersBadge": String(to)])
        case .conversationCountChanged, .messageCountChanged, .messageChanged, .messagesPrepended, .composerChanged:
            return nil
        }
    }
}

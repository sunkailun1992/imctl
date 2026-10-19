import AXKit
import CoreGraphics

/// The regions the adapter reads, located by role + geometry + settable
/// attributes only. `_NS:*` identifiers are auto-generated nib ids and are
/// never used for selection.
public struct WeComLayout {
    public let window: AXElement
    public let windowFrame: CGRect
    public let conversationTable: AXElement
    public let conversationTableFrame: CGRect
    /// Absent right after launch (no active conversation) and on some non-chat views.
    public let messageTable: AXElement?
    public let messageTableFrame: CGRect?
    /// The `AXScrollArea` holding the message table (scroll bars live here); absent with the table.
    public let messageScrollArea: AXElement?
    /// Absent while a conversation that cannot be replied to (system / notice account) is active.
    public let composer: AXElement?
    public let composerFrame: CGRect?
    /// Multiple writable editors in the chat's bottom band are unsafe to guess between.
    public let composerAmbiguous: Bool
    public let activeTitle: AXElement?
    public let searchField: AXElement?
    /// The + button right of the search field (发起群聊 / 添加); absent on non-message views.
    public let plusButton: AXElement?
    /// Frames of the images drawn in the message pane (pictures, sender avatars; ≥ 40 px), for rows that expose no text.
    public var messageImages: [CGRect] = []

    private struct Candidate {
        let element: AXElement
        let role: String
        let frame: CGRect
    }

    public static func locate(in window: AXElement) throws -> WeComLayout {
        let windowFrame = try window.frame() ?? .zero
        var candidates: [Candidate] = []
        // A table may hold hundreds of rows. Layout needs the table's frame,
        // not every descendant's frame; the row parsers read its children
        // separately. Stop the layout walk at tables to avoid thousands of
        // synchronous cross-process AX calls on every history read.
        var queue: [(AXElement, Int)] = [(window, 0)]
        var head = 0
        var seen = 0
        while head < queue.count, seen < 2000 {
            let (parent, depth) = queue[head]
            head += 1
            guard depth < 12, let children = try? parent.children() else { continue }
            for element in children {
                seen += 1
                guard let role = try? element.role() else { continue }
                switch role {
                case AXRole.table, AXRole.scrollArea, AXRole.textArea, AXRole.staticText,
                     AXRole.textField, AXRole.image, AXRole.button:
                    let frame = (try? element.frame()) ?? .zero
                    candidates.append(Candidate(element: element, role: role, frame: frame))
                default:
                    break
                }
                if role != AXRole.table { queue.append((element, depth + 1)) }
                if seen >= 2000 { break }
            }
        }

        // The 会话筛选 side panel (2026-09-15, 5.0.11) is a 160 px split pane at the
        // window's left edge whose filter list is also an AXTable, but only ~240 px
        // tall; the conversation list always spans the window. The message table
        // can be short (few rows loaded), so only the conversation pick needs height.
        let tables = candidates.filter { $0.role == AXRole.table }.sorted { $0.frame.minX < $1.frame.minX }
        let tall = tables.filter { $0.frame.height >= windowFrame.height / 2 }
        guard let conversation = tall.first else { throw WeComError.region("conversationTable") }
        let message = tables.filter { $0.frame.minX > conversation.frame.minX }.max(by: { $0.frame.width < $1.frame.width })

        // The scroll area is normally the table's parent; fall back to the
        // scroll area overlapping the table most (frames differ by a border).
        var messageScrollArea: AXElement?
        if let message {
            if let parent = try? message.element.parent(), (try? parent.role()) == AXRole.scrollArea {
                messageScrollArea = parent
            } else {
                messageScrollArea = candidates
                    .filter { $0.role == AXRole.scrollArea && $0.frame.intersects(message.frame) }
                    .max(by: { area($0.frame.intersection(message.frame)) < area($1.frame.intersection(message.frame)) })?
                    .element
            }
        }

        // A writable text area elsewhere in the window (a floating note, search
        // panel or message row) is not a chat composer. The recorded 5.0.10/11
        // chat editor spans the pane below the message viewport. Require that
        // geometry and uniqueness instead of choosing the largest editor: a
        // visual guess between two writable drafts has no independent AX
        // postcondition and could stage the caller's text in the wrong field.
        let viewportFrame = (try? messageScrollArea?.frame()) ?? nil
        let composerCandidates = candidates.filter { candidate in
            guard candidate.role == AXRole.textArea,
                  let viewportFrame,
                  (try? candidate.element.isSettable(AXAttribute.value)) == true else { return false }
            let frame = candidate.frame
            return frame.width >= viewportFrame.width * 0.5 && frame.height >= 40
                && frame.minX >= conversation.frame.maxX - 8
                && frame.minY >= viewportFrame.maxY - 8
                && frame.maxX <= windowFrame.maxX + 8
                && frame.maxY <= windowFrame.maxY + 8
        }
        let composer = composerCandidates.count == 1 ? composerCandidates[0] : nil

        // The header sits above the message viewport. Use the scroll area's top,
        // not the table's: with more rows loaded than fit, the table's frame
        // origin goes negative (scrolled) and would hide the title.
        let viewportTop = (try? messageScrollArea?.frame())??.minY
        let titleCeiling = viewportTop ?? message?.frame.minY ?? (conversation.frame.minY + 1)
        // Rows scrolled above the viewport also have minY < ceiling; anything
        // inside the message scroll area is never the header.
        // An external group's header title is an editable AXTextField; the static
        // text below it is the "由企业微信用户创建的外部群…" banner (2026-09-15, 5.0.11).
        let title = candidates
            .filter {
                ($0.role == AXRole.staticText || $0.role == AXRole.textField)
                    && $0.frame.minY < titleCeiling
                    && $0.frame.minX >= conversation.frame.maxX
                    && !isInside($0.element, messageScrollArea)
            }
            .min { $0.frame.minY < $1.frame.minY }

        let searchCandidates = candidates.filter {
            $0.role == AXRole.textField && $0.frame.width > 0 && $0.frame.height > 0
                && $0.frame.minX >= conversation.frame.minX
                && $0.frame.maxX <= conversation.frame.maxX
                && (try? $0.element.isSettable(AXAttribute.value)) == true
        }
        let search = searchCandidates.count == 1 ? searchCandidates[0] : nil
        let images = candidates.filter { $0.role == AXRole.image && $0.frame.width >= 40 && $0.frame.minX >= conversation.frame.maxX }.map(\.frame)
        // The search field and + button are siblings above the conversation list. Anchor the
        // button to that live field and its height, not to the recorded window-top offset;
        // a wider neighboring action or two matches are unsafe.
        let searchParent = search.flatMap { try? $0.element.parent() }
        let plusCandidates = candidates.filter { candidate in
            guard candidate.role == AXRole.button, let search, let searchParent else { return false }
            let button = candidate.frame, field = search.frame
            let overlap = min(button.maxY, field.maxY) - max(button.minY, field.minY)
            guard button.width > 0, button.height > 0,
                  button.width >= field.height * 0.6, button.width <= field.height * 1.25,
                  button.height >= field.height * 0.6, button.height <= field.height * 1.25,
                  button.minX >= field.maxX,
                  button.minX - field.maxX <= field.height,
                  button.maxX <= conversation.frame.maxX,
                  overlap >= min(button.height, field.height) / 2 else { return false }
            return (try? candidate.element.parent())?.handle == searchParent.handle
                && (try? candidate.element.actions().contains(AXAction.press)) == true
                && (try? candidate.element.isEnabled()) != false
        }
        let plus = plusCandidates.count == 1 ? plusCandidates[0].element : nil

        return WeComLayout(
            window: window, windowFrame: windowFrame,
            conversationTable: conversation.element, conversationTableFrame: conversation.frame,
            messageTable: message?.element, messageTableFrame: message?.frame, messageScrollArea: messageScrollArea,
            composer: composer?.element, composerFrame: composer?.frame,
            composerAmbiguous: composerCandidates.count > 1,
            activeTitle: title?.element, searchField: search?.element, plusButton: plus,
            messageImages: images
        )
    }

    /// The message viewport as the live scroll area reports it. The conversation
    /// header lies above its top and a side panel (群成员) starts at or right of
    /// its right edge, so these relations replace window-offset bands recorded
    /// on one screen. nil without the scroll area: the table alone cannot bound
    /// the header, because its origin goes negative once it scrolls.
    public func messageViewportFrame() -> CGRect? {
        guard let frame = (try? messageScrollArea?.frame()) ?? nil, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Walks `AXParent` a few levels to tell whether `element` lives under `container`.
    private static func isInside(_ element: AXElement, _ container: AXElement?, maxDepth: Int = 8) -> Bool {
        guard let container else { return false }
        var current = element
        for _ in 0..<maxDepth {
            guard let parent = try? current.parent() else { return false }
            if parent.handle == container.handle { return true }
            current = parent
        }
        return false
    }
}

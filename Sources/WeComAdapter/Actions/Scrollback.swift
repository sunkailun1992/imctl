import AXKit
import ControlCore
import Foundation

/// How to move the message area to the top. `auto` = scroll bars when the
/// client exposes settable ones, else page actions.
public enum ScrollbackStrategy: String, Codable, CaseIterable {
    case auto
    case scrollBar = "bar"
    case pageAction = "page"
}

public struct ScrollbackOutcome: Equatable, Codable {
    public var scrolls: Int
    public var rowsBefore: Int
    public var rowsAfter: Int
    /// Whether the view was scrolled back to the bottom afterwards (best effort).
    public var restored: Bool
}

extension WeComActions {
    /// An explicit history read starts from the newest messages, even when a
    /// human left the client scrolled into older history. The watcher does not
    /// call this action. Setting the client's own scroll bar does not focus or
    /// switch its conversation. Returns whether the client was moved; callers
    /// only need to re-locate the message table after an actual move.
    public func showLatestMessages(reader: WeComReader, maxPages: Int = 20) throws -> Bool {
        guard let area = reader.layout.messageScrollArea else {
            if reader.layout.messageTable == nil { return false } // no active message pane to reposition
            throw ActionError.actionUnavailable("messageScrollArea")
        }
        let active = try reader.activeConversationTitle()
        try authorize(.scrollHistory, title: active)
        let bars = try area.children().filter { try $0.role() == AXRole.scrollBar && $0.isSettable(AXAttribute.value) }
        let verticalBars = try Self.messageAreaVerticalBars(in: area, settableBars: bars)
        // Explicit history reads use the command-owned visual round even when
        // AX exposes only one eligible bar. Read its value first: an already
        // current history must not capture a window or call the model.
        if verticalBars.count == 1, visualSelect != nil, let visualScrollRounds {
            if (try verticalBars[0].value()?.doubleValue ?? -1) >= 0.99 { return false }
            _ = try visualScrollRounds(reader, 1)
            return true
        }
        let vertical: AXElement?
        let needsVisualChoice = verticalBars.count > 1 && visualSelect != nil && !Self.coincidentBars(verticalBars)
        if needsVisualChoice {
            if let visualScrollRounds {
                // No single bar can be trusted from AX geometry alone. The
                // command-owned runner chooses and verifies one current bar.
                if try verticalBars.allSatisfy({ (try $0.value()?.doubleValue ?? -1) >= 0.99 }) {
                    return false
                }
                _ = try visualScrollRounds(reader, 1)
                return true
            }
            vertical = try visualChoice(window: reader.layout.window, goal: .control(.messageScrollBar), kind: .scroll,
                                        actionKind: .scrollHistory,
                                        expectedTitle: active, eligible: verticalBars, purpose: "message scroll bar")
        } else {
            vertical = verticalBars.first
        }
        if let bar = vertical {
            if (try bar.value()?.doubleValue ?? -1) >= 0.99 { return false }
            if needsVisualChoice {
                try visualActionGate?(.scrollHistory, active)
                let fresh = try WeComReader(window: reader.layout.window)
                guard try fresh.activeConversationTitle() == active,
                      try fresh.layout.messageScrollArea?.children().contains(where: { $0.handle == bar.handle }) == true else {
                    throw ActionError.actionUnavailable("message scroll bar")
                }
            }
            try bar.setAttribute(AXAttribute.value, to: .double(1))
            guard let value = try bar.value()?.doubleValue, value >= 0.99 else {
                throw ActionError.verifyFailed("message scroll bar did not reach the latest position")
            }
            return true
        }
        guard try area.actions().contains(AXAction.scrollDownByPage) else {
            throw ActionError.actionUnavailable(AXAction.scrollDownByPage)
        }
        // Some client builds expose page actions but no settable bar. Stop
        // when two successive page actions leave both the loaded tail and the
        // table geometry intact. The same rows can remain loaded as the view
        // moves through them, so handles alone are not enough.
        var previousLast = try reader.layout.messageTable?.children().last?.handle
        var previousFrame = try reader.layout.messageTable?.frame()
        var unchanged = 0
        for _ in 0..<maxPages {
            try area.perform(AXAction.scrollDownByPage)
            let last = try reader.layout.messageTable?.children().last?.handle
            let frame = try reader.layout.messageTable?.frame()
            unchanged = last == previousLast && frame == previousFrame ? unchanged + 1 : 0
            if unchanged >= 2 { return true }
            previousLast = last
            previousFrame = frame
        }
        throw ActionError.verifyFailed("latest message position not reached after \(maxPages) page actions")
    }

    /// Loads older history by scrolling the message area to the top until at
    /// least `minRows` rows are present or the table stops growing (two idle
    /// rounds). An explicit command can use its bounded visual round for the
    /// first needed scroll of one visible, writable message bar; subsequent
    /// scrolls and restoration use the same bar with fresh AX checks. Without
    /// that round, settable bars use AX directly; otherwise the message area
    /// receives page actions. Never touches the composer.
    public func loadOlderMessages(reader: WeComReader, minRows: Int, maxScrolls: Int = 20,
                                  strategy: ScrollbackStrategy = .auto, restore: Bool = true) throws -> ScrollbackOutcome {
        let active = try reader.activeConversationTitle()
        try authorize(.scrollHistory, title: active)
        guard let area = reader.layout.messageScrollArea else { throw WeComError.region("messageScrollArea") }
        let settableBars = try area.children().filter { try $0.role() == AXRole.scrollBar && $0.isSettable(AXAttribute.value) }
        let verticalBars = try Self.messageAreaVerticalBars(in: area, settableBars: settableBars)
        // Sample the pre-scroll baseline before the visual runner can move the
        // bar or cause WeCom to prepend older rows.
        let before = try reader.messages().count
        // A request already satisfied by visible rows must not upload a window
        // merely to identify a scroll bar. Zero scroll budget is likewise a
        // no-op, including when the bar is ambiguous.
        guard before < minRows, maxScrolls > 0 else {
            return ScrollbackOutcome(scrolls: 0, rowsBefore: before, rowsAfter: before, restored: false)
        }
        let bars: [AXElement]
        let needsVisualChoice = strategy != .pageAction && verticalBars.count > 1
            && visualSelect != nil && !Self.coincidentBars(verticalBars)
        var roundRecheck: (() throws -> Void)?
        var initialScrollPerformed = false
        if strategy == .pageAction {
            bars = []
        } else if verticalBars.count == 1, visualSelect != nil, let visualScrollRounds {
            // The destination remains command-owned. The runner observes the
            // current window, chooses only this AX bar, writes the fixed top
            // value and returns a gate for every later AX write.
            let choice = try visualScrollRounds(reader, 0)
            bars = [choice.bar]
            roundRecheck = choice.recheck
            initialScrollPerformed = true
        } else if needsVisualChoice {
            if let visualScrollRounds {
                let choice = try visualScrollRounds(reader, 0)
                bars = [choice.bar]
                roundRecheck = choice.recheck
                initialScrollPerformed = true
            } else {
                bars = [try visualChoice(window: reader.layout.window, goal: .control(.messageScrollBar), kind: .scroll,
                                         actionKind: .scrollHistory,
                                         expectedTitle: active, eligible: verticalBars, purpose: "message scroll bar")]
            }
        } else {
            bars = verticalBars.isEmpty ? settableBars : verticalBars
        }
        let canPage = strategy != .scrollBar && (try? area.actions().contains(AXAction.scrollUpByPage)) == true
        guard !bars.isEmpty || canPage else { throw ActionError.actionUnavailable(strategy == .scrollBar ? AXAttribute.value : AXAction.scrollUpByPage) }

        var count = before
        var scrolls = initialScrollPerformed ? 1 : 0
        let effectiveMaxScrolls = roundRecheck == nil ? maxScrolls : min(maxScrolls, 12)
        var stalls = 0
        func recheckVisualBar(_ bar: AXElement) throws {
            if let roundRecheck { try roundRecheck(); return }
            guard needsVisualChoice else { return }
            try visualActionGate?(.scrollHistory, active)
            let fresh = try WeComReader(window: reader.layout.window)
            guard try fresh.activeConversationTitle() == active,
                  try fresh.layout.messageScrollArea?.children().contains(where: { $0.handle == bar.handle }) == true else {
                throw ActionError.actionUnavailable("message scroll bar")
            }
        }
        if initialScrollPerformed {
            let grew = try waitUntil {
                let n = try reader.messages().count
                guard n > count else { return false }
                count = n
                return true
            }
            stalls = grew ? 0 : 1
        }
        while count < minRows, scrolls < effectiveMaxScrolls, stalls < 2 {
            if bars.isEmpty {
                for _ in 0..<3 { try area.perform(AXAction.scrollUpByPage) }
            } else {
                for bar in bars {
                    try recheckVisualBar(bar)
                    try bar.setAttribute(AXAttribute.value, to: .double(0))
                }
            }
            scrolls += 1
            let grew = try waitUntil {
                let n = try reader.messages().count
                guard n > count else { return false }
                count = n
                return true
            }
            stalls = grew ? 0 : stalls + 1
        }

        var restored = false
        if scrolls > 0, restore {
            restored = true
            if bars.isEmpty {
                for _ in 0..<(scrolls * 3) {
                    do { try area.perform(AXAction.scrollDownByPage) } catch { restored = false; break }
                }
            } else {
                for bar in bars {
                    do {
                        try recheckVisualBar(bar)
                        try bar.setAttribute(AXAttribute.value, to: .double(1))
                        if roundRecheck != nil {
                            try recheckVisualBar(bar)
                            guard let value = try bar.value()?.doubleValue, value >= 0.99 else {
                                restored = false
                                continue
                            }
                        }
                    } catch { restored = false }
                }
            }
        }
        if roundRecheck != nil, restore, !restored {
            throw ActionError.verifyFailed("message scroll bar restore to latest was not verified")
        }
        return ScrollbackOutcome(scrolls: scrolls, rowsBefore: before, rowsAfter: count, restored: restored)
    }

    /// WeCom 5.0.x can expose the same vertical scrollbar twice as sibling AX elements with
    /// identical geometry. Treat those as one visible control so normal history reads retain
    /// the AX fast path and do not upload a window only to choose between pixel-identical bars.
    static func coincidentBars(_ bars: [AXElement]) -> Bool {
        guard let first = bars.first, let reference = (try? first.frame()) ?? nil else { return false }
        return bars.dropFirst().allSatisfy { bar in
            guard let frame = (try? bar.frame()) ?? nil else { return false }
            return abs(frame.minX - reference.minX) <= 2 && abs(frame.minY - reference.minY) <= 2
                && abs(frame.width - reference.width) <= 2 && abs(frame.height - reference.height) <= 2
        }
    }

    /// WeCom can report an unrelated inner scrollbar as a direct child of the
    /// message scroll area. The area's own vertical track hugs its right edge
    /// and spans most of its height. Prefer those AX tracks only when at least
    /// one has that geometry; retain the old candidate set when AX gives no
    /// such evidence, so a different client layout still reaches visual choice.
    static func messageAreaVerticalBars(in area: AXElement, settableBars: [AXElement]) throws -> [AXElement] {
        let vertical = try settableBars.filter { bar in
            guard let frame = try bar.frame() else { return true }
            return frame.height >= frame.width
        }
        guard let areaFrame = (try? area.frame()) ?? nil, areaFrame.height > 0 else { return vertical }
        let edgeTracks = vertical.filter { bar in
            guard let frame = (try? bar.frame()) ?? nil else { return false }
            return abs(frame.maxX - areaFrame.maxX) <= 4
                && abs(frame.minY - areaFrame.minY) <= 4
                && frame.height >= areaFrame.height * 0.75
        }
        return edgeTracks.isEmpty ? vertical : edgeTracks
    }
}

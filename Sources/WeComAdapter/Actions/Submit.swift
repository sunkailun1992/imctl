import AXKit
import ControlCore
import Foundation

/// How the irreversible step is attempted. WeCom exposes no send button to
/// AX, so these are the zero-synthetic-input candidates tried in order.
public enum SubmitStrategy: String, Codable, CaseIterable {
    case axConfirm = "ax-confirm"
    case newline
    /// Open the composer's context menu (AXShowMenu) and press a 发送 item if one exists.
    case contextMenu = "context-menu"
    /// Press a button that appears after composing (or any button titled 发送).
    case sendButton = "send-button"
    /// Return key posted to the client's pid only (the sanctioned exception to "no synthetic input").
    case enterKey = "enter"
    case ctrlEnterKey = "ctrl-enter"

    /// Order used by `--auto`: most likely first, cheapest fallbacks last.
    public static let autoOrder: [SubmitStrategy] = [.enterKey, .ctrlEnterKey, .sendButton, .contextMenu, .axConfirm, .newline]
}

/// Executor hooks around the irreversible step (checkpoint persistence, crash injection).
public struct SubmitHooks {
    public var beforeIrreversible: () throws -> Void
    public var afterIrreversible: () throws -> Void
    public init(beforeIrreversible: @escaping () throws -> Void = {}, afterIrreversible: @escaping () throws -> Void = {}) {
        self.beforeIrreversible = beforeIrreversible
        self.afterIrreversible = afterIrreversible
    }
}

public struct SubmitOutcome: Codable, Equatable {
    public var state: CommandState
    public var strategy: String
    public var target: String?
    public var checkpointID: String
    public var reason: String?
    public var evidence: String?
    public var latencyMs: Int?
    public var composerAfter: Int
    /// Discovery output: menu items seen, buttons seen, etc.
    public var details: [String: String] = [:]
}

private struct ButtonSig: Hashable {
    let title: String?
    let description: String?
    let x: Int
    let y: Int
}

extension WeComActions {
    /// precheck_input → compose → checkpoint(pending) → verify_target → submit → confirm.
    /// Never retries. On `failed`, only the exact text we staged in the same
    /// active composer may be cleared; on `unknown` it is left for a human.
    public func submit(
        text: String, strategy: SubmitStrategy, reader: WeComReader, checkpoints: CheckpointStore,
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.2, hooks: SubmitHooks = SubmitHooks()
    ) throws -> SubmitOutcome {
        guard let active = try reader.activeConversationTitle(), !active.isEmpty else {
            throw ActionError.actionUnavailable("active conversation title")
        }
        try authorize(.submit, title: active)
        guard let composer = reader.layout.composer else {
            if reader.layout.composerAmbiguous { throw ActionError.actionUnavailable("ambiguous composer") }
            throw WeComError.region("composer")
        }
        guard reader.layout.messageTable != nil else { throw WeComError.region("messageTable") }
        let current = try composer.valueString() ?? ""
        guard current.isEmpty else { throw ActionError.localGuard("composer not empty") }
        var baselineRows = try reader.chatMessages(conversationTitle: active)
        guard baselineRows.allSatisfy({ $0.messageKey != nil }) else {
            throw ActionError.actionUnavailable("incomplete message baseline")
        }
        var baselineKeys = Set(baselineRows.compactMap(\.messageKey))
        let buttonsBefore = strategy == .sendButton ? buttons(in: reader.layout.window) : []

        try visualObserveComposer?(reader, composer, .beforeStaging, {
            let count = try composer.attributeIfSupported(AXAttribute.numberOfCharacters)
            let characters = count?.intValue ?? count?.stringValue.flatMap(Int.init) ?? 0
            let value = try composer.valueString() ?? ""
            let children = try composer.children()
            return value.isEmpty && children.isEmpty && characters == 0
        })
        try visualComposerStagingGate?()
        try setComposer(text, reader: reader)
        do {
            try visualObserveComposer?(reader, composer, .afterStaging, {
                let value = try composer.valueString()
                let children = try composer.children()
                return value == text && children.isEmpty
            })
            if visualObserveComposer != nil {
                // A human may send a similar row while the model is inferring.
                // Refresh the complete baseline as close as possible to the
                // irreversible step; it must not count as this command's row.
                let current = try WeComReader(window: reader.layout.window)
                guard try current.activeConversationTitle() == active,
                      current.layout.composer?.handle == composer.handle,
                      try composer.valueString() == text,
                      try composer.children().isEmpty else {
                    throw ActionError.localGuard("composer changed before submit")
                }
                let rows = try current.chatMessages(conversationTitle: active)
                guard rows.allSatisfy({ $0.messageKey != nil }) else {
                    throw ActionError.actionUnavailable("incomplete message baseline")
                }
                baselineRows = rows
                baselineKeys = Set(rows.compactMap(\.messageKey))
                try visualComposerCommitGate?()
            }
        } catch {
            // No checkpoint exists yet. A model veto or a changed window may
            // leave a draft, but only the exact text staged by this command in
            // this same active composer is safe to remove. Preserve human edits.
            if visualComposerStillCurrent?(reader, composer) == true,
               let fresh = try? WeComReader(window: reader.layout.window),
               (try? fresh.activeConversationTitle()) == active,
               fresh.layout.composer?.handle == composer.handle,
               (try? composer.valueString()) == text,
               (try? composer.children().isEmpty) == true {
                try? setComposer("", reader: fresh)
            }
            throw error
        }

        var checkpoint = SubmitCheckpoint(target: active, text: text, strategy: strategy.rawValue)
        try checkpoints.write(checkpoint)
        var details: [String: String] = [:]
        var restoreAfterConfirm: (() -> Void)?
        defer { restoreAfterConfirm?() }

        func fail(_ reason: String, clear: Bool = true) throws -> SubmitOutcome {
            checkpoint.state = .failed
            checkpoint.reason = reason
            try checkpoints.write(checkpoint)
            if clear,
               (visualComposerStillCurrent == nil || visualComposerStillCurrent?(reader, composer) == true),
               let fresh = try? WeComReader(window: reader.layout.window),
               (try? fresh.activeConversationTitle()) == active,
               fresh.layout.composer?.handle == composer.handle,
               let stagedValue = try? composer.valueString(),
               ([text] + (strategy == .newline ? [text + "\n"] : [])).contains(stagedValue) {
                try? setComposer("", reader: fresh)
            }
            return SubmitOutcome(state: .failed, strategy: strategy.rawValue, target: active, checkpointID: checkpoint.id,
                                 reason: reason, evidence: nil, latencyMs: nil,
                                 composerAfter: (try? composer.valueString())?.count ?? -1, details: details)
        }

        // verify_target again, immediately before the irreversible step.
        let fresh = try WeComReader(window: reader.layout.window)
        let activeNow = try fresh.activeConversationTitle()
        guard activeNow == active, fresh.layout.composer?.handle == composer.handle else {
            return try fail("target drifted before submit (active now: \(activeNow ?? "-"))")
        }
        guard (try? composer.valueString()) == text else {
            return try fail("composer changed before submit")
        }
        try hooks.beforeIrreversible()
        if let visualComposerCommitGate {
            do { try visualComposerCommitGate() }
            catch {
                checkpoint.state = .unknown
                checkpoint.reason = "visual command gate changed before submit"
                try checkpoints.write(checkpoint)
                return SubmitOutcome(state: .unknown, strategy: strategy.rawValue, target: active,
                                     checkpointID: checkpoint.id, reason: checkpoint.reason,
                                     evidence: nil, latencyMs: nil,
                                     composerAfter: (try? composer.valueString())?.count ?? -1)
            }
            guard (try? composer.valueString()) == text,
                  (try? composer.children().isEmpty) == true else {
                checkpoint.state = .unknown
                checkpoint.reason = "composer changed after checkpoint before submit"
                try checkpoints.write(checkpoint)
                return SubmitOutcome(state: .unknown, strategy: strategy.rawValue, target: active,
                                     checkpointID: checkpoint.id, reason: checkpoint.reason,
                                     evidence: nil, latencyMs: nil,
                                     composerAfter: (try? composer.valueString())?.count ?? -1)
            }
        }
        let started = Date()

        // ---- irreversible point ----
        do {
        switch strategy {
        case .axConfirm:
            try visualComposerCommitGate?()
            do { try composer.perform(AXAction.confirm) } catch AXKitError.actionUnsupported {
                return try fail("AXConfirm unsupported by composer")
            }
        case .newline:
            try visualComposerCommitGate?()
            try composer.setAttribute(AXAttribute.value, to: .string(text + "\n"))
        case .contextMenu:
            try visualComposerCommitGate?()
            do { try composer.perform(AXAction.showMenu) } catch AXKitError.actionUnsupported {
                return try fail("AXShowMenu unsupported by composer")
            }
            Thread.sleep(forTimeInterval: 0.4)
            guard let menu = try shownMenu(for: composer, reader: reader) else {
                return try fail("no menu appeared after AXShowMenu")
            }
            let items = try menu.children().filter { try $0.role() == AXRole.menuItem }
            let titles = try items.map { try $0.title() ?? "" }
            details["menuItems"] = titles.joined(separator: " | ")
            if let send = try items.first(where: { try Self.looksLikeSend($0.title()) }) {
                try visualComposerCommitGate?()
                try send.perform(AXAction.press)
            } else {
                try? menu.perform(AXAction.cancel)
                return try fail("context menu has no send item: [\(titles.joined(separator: " | "))]")
            }
        case .sendButton:
            Thread.sleep(forTimeInterval: 0.4)
            let after = buttons(in: reader.layout.window)
            let beforeSigs = Set(buttonsBefore.map(\.0))
            let fresh = after.filter { !beforeSigs.contains($0.0) }
            details["buttonsBefore"] = String(buttonsBefore.count)
            details["buttonsAfter"] = String(after.count)
            details["newButtons"] = fresh.map { "\($0.0.title ?? "-")/\($0.0.description ?? "-")@\($0.0.x),\($0.0.y)" }.joined(separator: " | ")
            let composerFrame = try composer.frame()
            func besideComposer(_ element: AXElement) -> Bool {
                guard let composerFrame, let frame = (try? element.frame()) ?? nil else { return false }
                return frame.maxY >= composerFrame.minY - 48 && frame.minY <= composerFrame.maxY + 48
                    && frame.minX >= composerFrame.midX && frame.maxX <= composerFrame.maxX + 48
            }
            let named = after.filter {
                (Self.looksLikeSend($0.0.title) || Self.looksLikeSend($0.0.description)) && besideComposer($0.1)
            }
            let candidate: (ButtonSig, AXElement)?
            var usedVisualChoice = false
            if named.count == 1 {
                candidate = named[0]
            } else if named.isEmpty && fresh.count == 1 {
                candidate = fresh[0]
            } else if visualSelect != nil {
                let pool = named.isEmpty ? fresh.filter { besideComposer($0.1) } : named
                guard !pool.isEmpty else { return try fail("no eligible send button in composer") }
                do {
                    let selected = try visualChoice(window: reader.layout.window, goal: .control(.sendButton), kind: .press,
                                                    actionKind: .submit,
                                                    expectedTitle: active, eligible: pool.map(\.1), purpose: "send button")
                    candidate = pool.first { $0.1.handle == selected.handle }
                    usedVisualChoice = true
                } catch {
                    // Cloud inference can take seconds. If a person switched chats or edited the
                    // draft during that wait, clearing the original AX handle could erase their
                    // work. Clear only the exact text we staged in the same active composer.
                    let current = try? WeComReader(window: reader.layout.window)
                    let sameTarget = (try? current?.activeConversationTitle()) == active
                    let sameComposer = current?.layout.composer?.handle == composer.handle
                    let sameText = (try? composer.valueString()) == text
                    return try fail("send button visual selection unavailable",
                                    clear: sameTarget && sameComposer && sameText)
                }
            } else {
                candidate = after.first { Self.looksLikeSend($0.0.title) || Self.looksLikeSend($0.0.description) }
            }
            guard let candidate else {
                return try fail("no send button (\(buttonsBefore.count) -> \(after.count) buttons, new: \(fresh.count))")
            }
            details["pressed"] = "\(candidate.0.title ?? "-")/\(candidate.0.description ?? "-")@\(candidate.0.x),\(candidate.0.y)"
            if usedVisualChoice {
                // The checkpoint exists, but the button has not been pressed.
                // A policy/pause change or client rebuild during inference must
                // leave this attempt unsubmitted.
                try visualActionGate?(.submit, active)
                let current = try WeComReader(window: reader.layout.window)
                guard try current.activeConversationTitle() == active,
                      current.layout.composer?.handle == composer.handle,
                      try composer.valueString() == text,
                      buttons(in: reader.layout.window).contains(where: {
                          $0.1.handle == candidate.1.handle && besideComposer($0.1)
                      }) else { return try fail("send button changed before press", clear: false) }
            }
            try visualComposerCommitGate?()
            try candidate.1.perform(AXAction.press)
        case .enterKey, .ctrlEnterKey:
            // Focus the composer inside the client via AX, then deliver one Return to the pid. The client only acts
            // on the key while it is the active application (live 2026-09-15: a console send failed with the
            // text left in the composer while the user worked elsewhere), so the front is asserted first and
            // handed back after the bubble check. `previous` is read before the composer focus: focusing the
            // composer already activates the client (live 2026-09-16: read afterwards, it named the client
            // itself and nothing was handed back).
            let previous = frontmostPid()
            if (try? composer.isSettable(AXAttribute.focused)) == true {
                try? composer.setAttribute(AXAttribute.focused, to: .bool(true))
            }
            let window = reader.layout.window
            let pid = try window.pid()
            let app = AXApp.byPID(pid, backend: window.backend)
            let refront = try withFront(app: app, pid: pid) {
                try visualComposerCommitGate?()
                guard try composer.valueString() == text,
                      try composer.children().isEmpty else {
                    throw ActionError.localGuard("composer changed before submit")
                }
                try postReturnKey(pid, strategy == .ctrlEnterKey)
            }
            details["keystroke"] = strategy == .ctrlEnterKey ? "ctrl+return -> pid \(pid)" : "return -> pid \(pid)"
            details["front"] = refront.isEmpty ? "kept" : "brought"
            if let previous, previous != pid { restoreAfterConfirm = { self.restoreFrontmost(previous) } }
        }
        } catch {
            if visualComposerCommitGate != nil {
                checkpoint.state = .unknown
                checkpoint.reason = "text submit could not be confirmed after checkpoint"
                try checkpoints.write(checkpoint)
                return SubmitOutcome(state: .unknown, strategy: strategy.rawValue, target: active,
                                     checkpointID: checkpoint.id, reason: checkpoint.reason,
                                     evidence: nil, latencyMs: nil,
                                     composerAfter: (try? composer.valueString())?.count ?? -1,
                                     details: details)
            }
            throw error
        }

        try hooks.afterIrreversible()

        // ---- confirm: a new outbound text row whose body equals `text` ----
        let deadline = started.addingTimeInterval(timeout)
        var evidence: String?
        var readFailed = false
        var targetDrifted = false
        while true {
            guard (try? reader.activeConversationTitle()) == active else { targetDrifted = true; break }
            let rows = try? reader.chatMessages(conversationTitle: active)
            guard (try? reader.activeConversationTitle()) == active else { targetDrifted = true; break }
            if rows == nil { readFailed = true }
            if let row = rows.flatMap({ SendEvidence.newRows(baseline: baselineRows, observed: $0) })?.first(where: {
                $0.kind == .message && $0.direction == .outbound && $0.text == text
                    && $0.messageKey.map { !baselineKeys.contains($0) } == true
            }) {
                evidence = "row #\(row.index) dir=\(row.direction.rawValue) time=\(row.timeLabel ?? "-")"
                break
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let composerAfter = try? composer.valueString()

        if targetDrifted {
            checkpoint.state = .unknown
            checkpoint.reason = "active conversation changed during submit confirmation"
            try checkpoints.write(checkpoint)
            return SubmitOutcome(state: .unknown, strategy: strategy.rawValue, target: active, checkpointID: checkpoint.id,
                                 reason: checkpoint.reason, evidence: nil, latencyMs: latency,
                                 composerAfter: composerAfter?.count ?? -1, details: details)
        }
        if let evidence {
            checkpoint.state = .succeeded
            checkpoint.evidence = evidence
            try checkpoints.write(checkpoint)
            return SubmitOutcome(state: .succeeded, strategy: strategy.rawValue, target: active, checkpointID: checkpoint.id,
                                 reason: nil, evidence: evidence, latencyMs: latency, composerAfter: composerAfter?.count ?? -1, details: details)
        }
        if !readFailed, composerAfter?.hasPrefix(text) == true {
            var out = try fail("no matching bubble within \(Int(timeout))s; composer still holds the text")
            out.latencyMs = latency
            return out
        }
        checkpoint.state = .unknown
        checkpoint.reason = readFailed || composerAfter == nil
            ? "client evidence unavailable after submit"
            : "composer no longer holds the text but no matching bubble was observed"
        try checkpoints.write(checkpoint)
        return SubmitOutcome(state: .unknown, strategy: strategy.rawValue, target: active, checkpointID: checkpoint.id,
                             reason: checkpoint.reason, evidence: nil, latencyMs: latency, composerAfter: composerAfter?.count ?? -1, details: details)
    }

    // MARK: Helpers

    static func looksLikeSend(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return s.contains("发送") || s.lowercased().contains("send")
    }

    private func buttons(in window: AXElement) -> [(ButtonSig, AXElement)] {
        window.descendants().compactMap { el in
            guard (try? el.role()) == AXRole.button else { return nil }
            let f = (try? el.frame()) ?? .zero
            return (ButtonSig(title: try? el.title(), description: try? el.axDescription(), x: Int(f.minX), y: Int(f.minY)), el)
        }
    }

    /// The menu opened by AXShowMenu: `AXShownMenu` on the element, else an
    /// `AXMenu` child of the application, else one under the window.
    private func shownMenu(for composer: AXElement, reader: WeComReader) throws -> AXElement? {
        if let m = try composer.element(AXAttribute.shownMenu) { return m }
        let backend = reader.layout.window.backend
        if let pid = try? reader.layout.window.pid() {
            let app = AXApp.byPID(pid, backend: backend)
            if let m = try app.children().first(where: { try $0.role() == AXRole.menu }) { return m }
        }
        return reader.layout.window.descendants(maxDepth: 3, maxNodes: 300).first { (try? $0.role()) == AXRole.menu }
    }
}

import AXKit
import ControlCore
import Foundation

/// B13: paste a fetched file into the composer (⌘V to the client's pid — the key the user approved
/// 2026-09-22 17:43) and send it with the same Return as text. Evidence = a new outbound `media` / `file` /
/// `video` row; a `file` row must also show the name we pasted. Live 2026-09-22 (5.0.11, macOS 27.0): a
/// pasted file URL becomes an inline picture, a "name · size" chip (pdf / docx) or a "视频 · size" chip
/// (mp4, sent as a native video); no dialog appears.
extension WeComActions {
    static let pasteStrategy = "paste-enter"

    /// Composer state as one comparable string: value length / AXNumberOfCharacters / child count. A pasted
    /// attachment changes at least one of them (calibration item §11.1 of the B13 spec; the fake changes the
    /// character count).
    func composerSignal(_ composer: AXElement) -> String {
        let value = (try? composer.valueString())?.count ?? 0
        // "0": an attribute the client hasn't reported yet (baseline) and one explicitly read back as zero
        // (after Return clears the attachment chip) are the same "no characters" state; a raw "" vs "0"
        // mismatch here would read as a still-attached composer even after the chip is gone.
        let count = try? composer.attributeIfSupported(AXAttribute.numberOfCharacters)
        let chars = count?.intValue.map(String.init) ?? count?.stringValue ?? "0"
        let children = (try? composer.children().count) ?? 0
        return "\(value)/\(chars)/\(children)"
    }

    public func sendFile(_ file: FetchedFile, reader: WeComReader, checkpoints: CheckpointStore,
                         timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.2, hooks: SubmitHooks = SubmitHooks()) throws -> SubmitOutcome {
        guard let active = try reader.activeConversationTitle(), !active.isEmpty else {
            throw ActionError.actionUnavailable("active conversation title")
        }
        try authorize(.sendFile, title: active)
        let expectedKind: MessageRowKind
        switch file.kind {
        case "image": expectedKind = .media
        case "video": expectedKind = .video
        case "file": expectedKind = .file
        default: throw ActionError.actionUnavailable("unsupported attachment kind")
        }
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
        let childrenBefore = try composer.children()
        let initialCount = try composer.attributeIfSupported(AXAttribute.numberOfCharacters)
        guard childrenBefore.isEmpty,
              (initialCount?.intValue ?? initialCount?.stringValue.flatMap(Int.init) ?? 0) == 0 else {
            throw ActionError.localGuard("composer not empty")
        }
        let composerBefore = composerSignal(composer)
        try visualObserveComposer?(reader, composer, .beforeStaging, {
            let count = try composer.attributeIfSupported(AXAttribute.numberOfCharacters)
            let characters = count?.intValue ?? count?.stringValue.flatMap(Int.init) ?? 0
            return try (composer.valueString() ?? "").isEmpty
                && composer.children().isEmpty && characters == 0
        })
        struct AttachmentStage: Equatable {
            let signal: String
            let value: String
            let objectHandle: AXElementHandle?
        }
        // WeCom 5.0.11 can expose a pasted file as one native text attachment (U+FFFC)
        // instead of an empty AXValue. The single AXUnknown child is the object token;
        // any real text, mixed text, or multiple tokens remain an unsafe human draft.
        func stagedAttachment() throws -> AttachmentStage? {
            let value = try composer.valueString() ?? ""
            let signal = composerSignal(composer)
            guard signal != composerBefore else { return nil }
            let count = try composer.attributeIfSupported(AXAttribute.numberOfCharacters)
            let characterCount = count?.intValue ?? count?.stringValue.flatMap(Int.init)
            let children = try composer.children()
            if value.isEmpty {
                // Older clients can expose one pasted attachment with an empty
                // AXValue. Accept only one character or one native child; two
                // chips must never be treated as one attachment.
                guard characterCount.map({ $0 <= 1 }) ?? true, children.count <= 1 else {
                    throw ActionError.localGuard("composer changed while staging attachment")
                }
                if let child = children.first {
                    guard try child.role() == AXRole.unknown else { return nil }
                } else {
                    guard characterCount == 1 else { return nil }
                }
                return AttachmentStage(signal: signal, value: value, objectHandle: children.first?.handle)
            }
            guard value == "\u{FFFC}" else {
                throw ActionError.localGuard("composer changed while staging attachment")
            }
            guard characterCount == 1 else { return nil }
            guard children.count == 1, try children[0].role() == AXRole.unknown else { return nil }
            return AttachmentStage(signal: signal, value: value, objectHandle: children[0].handle)
        }
        var details: [String: String] = ["fileName": file.fileName, "kind": file.kind, "bytes": String(file.bytes), "composerBefore": composerBefore]
        var checkpoint = SubmitCheckpoint(target: active, text: "file:\(file.fileName)", strategy: Self.pasteStrategy)

        func outcome(_ state: CommandState, reason: String?, evidence: String? = nil, latency: Int? = nil) -> SubmitOutcome {
            SubmitOutcome(state: state, strategy: Self.pasteStrategy, target: active, checkpointID: checkpoint.id, reason: reason,
                          evidence: evidence, latencyMs: latency, composerAfter: (try? composer.valueString())?.count ?? -1, details: details)
        }

        // The client only acts on keys while it is the active application (B9); focus the composer first,
        // remember who was in front, and hand focus back after the bubble check.
        let previous = frontmostPid()
        if (try? composer.isSettable(AXAttribute.focused)) == true { try? composer.setAttribute(AXAttribute.focused, to: .bool(true)) }
        let window = reader.layout.window
        let pid = try window.pid()
        let app = AXApp.byPID(pid, backend: window.backend)
        var restoreAfterConfirm: (() -> Void)?
        defer { restoreAfterConfirm?() }
        if let previous, previous != pid { restoreAfterConfirm = { self.restoreFrontmost(previous) } }

        // ---- paste (reversible) ----
        let clipboard = pasteboard.snapshot()
        // Guarded so a throw from any step below (withFront / postShortcut / waitUntil) restores the
        // person's clipboard when it still contains the file we staged. If they copied something meanwhile,
        // keep their newer clipboard and refuse to paste it as this command's attachment.
        var clipboardRestored = false
        func restoreClipboard() {
            guard !clipboardRestored else { return }
            clipboardRestored = true
            if pasteboard.matchesFileURL(file.url) { pasteboard.restore(clipboard) }
        }
        defer { restoreClipboard() }
        try visualComposerStagingGate?()
        pasteboard.setFileURL(file.url)
        let refront = try withFront(app: app, pid: pid) {
            try visualComposerStagingGate?()
            guard pasteboard.matchesFileURL(file.url) else {
                throw ActionError.localGuard("clipboard changed before attachment paste")
            }
            try postShortcut(.commandV, pid)
        }
        details["paste"] = "cmd+v -> pid \(pid)\(refront)"
        var staged: AttachmentStage?
        let landed = try waitUntil(timeout: pasteTimeout) {
            staged = try stagedAttachment()
            return staged != nil
        }
        restoreClipboard()
        details["composerAfterPaste"] = composerSignal(composer)
        guard landed else {
            details["pasteFailed"] = "true"
            return outcome(.failed, reason: "the attachment did not appear in the composer within \(Int(pasteTimeout)) s (nothing was sent)")
        }

        // verify_target again, immediately before the irreversible step.
        let fresh = try WeComReader(window: window)
        guard try fresh.activeConversationTitle() == active, fresh.layout.composer?.handle == composer.handle else {
            checkpoint.state = .failed; checkpoint.reason = "target drifted before submit"
            try checkpoints.write(checkpoint)
            return outcome(.failed, reason: checkpoint.reason)
        }
        guard let staged, (try? stagedAttachment()) == staged else {
            checkpoint.state = .failed; checkpoint.reason = "attachment staging changed before submit"
            try checkpoints.write(checkpoint)
            return outcome(.failed, reason: checkpoint.reason)
        }
        // The clipboard is already restored. A visual veto here leaves any
        // attachment chip untouched and never repeats paste or sends Return.
        try visualObserveComposer?(reader, composer, .afterStaging, {
            try stagedAttachment() == staged
        })
        if visualObserveComposer != nil {
            // Model inference may overlap a manual outbound attachment. Such
            // a row cannot be evidence for this command's later Return.
            let current = try WeComReader(window: window)
            guard try current.activeConversationTitle() == active,
                  current.layout.composer?.handle == composer.handle,
                  try stagedAttachment() == staged else {
                throw ActionError.localGuard("attachment staging changed before submit")
            }
            let rows = try current.chatMessages(conversationTitle: active)
            guard rows.allSatisfy({ $0.messageKey != nil }) else {
                throw ActionError.actionUnavailable("incomplete message baseline")
            }
            baselineRows = rows
            baselineKeys = Set(rows.compactMap(\.messageKey))
            try visualComposerCommitGate?()
        }
        try checkpoints.write(checkpoint)
        try hooks.beforeIrreversible()
        if let visualComposerCommitGate {
            do { try visualComposerCommitGate() }
            catch {
                checkpoint.state = .unknown
                checkpoint.reason = "visual command gate changed before attachment submit"
                try checkpoints.write(checkpoint)
                return outcome(.unknown, reason: checkpoint.reason)
            }
            guard (try? stagedAttachment()) == staged else {
                checkpoint.state = .unknown
                checkpoint.reason = "attachment staging changed after checkpoint before submit"
                try checkpoints.write(checkpoint)
                return outcome(.unknown, reason: checkpoint.reason)
            }
        }
        let started = Date()

        // ---- irreversible point ----
        do {
            _ = try withFront(app: app, pid: pid) {
                try visualComposerCommitGate?()
                guard try stagedAttachment() == staged else {
                    throw ActionError.localGuard("attachment staging changed before submit")
                }
                try postReturnKey(pid, false)
            }
        } catch {
            // The frontmost-window wait or key delivery may fail after the
            // checkpoint. Whether a Return reached WeCom is now uncertain.
            checkpoint.state = .unknown
            checkpoint.reason = "attachment submit could not be confirmed after checkpoint"
            try checkpoints.write(checkpoint)
            return outcome(.unknown, reason: checkpoint.reason)
        }
        try hooks.afterIrreversible()

        // ---- confirm: a new OUTBOUND media / file / video row (§6.43) ----
        // `FileFetcher` already named the outbox file `FileNames.sanitize(fileName)`, and that is the name the
        // client shows on the chip it just sent, so a `file` row only counts when it carries that same name —
        // otherwise somebody else's file arriving in the same second would be read as proof of our send.
        let pastedName = FileNames.sanitize(file.fileName, fallback: file.fileName)
        func isEvidence(_ row: MessageRow) -> Bool {
            guard row.messageKey.map({ !baselineKeys.contains($0) }) == true else { return false }
            guard row.direction == .outbound else { return false }
            guard row.kind == expectedKind else { return false }
            switch row.kind {
            case .media:
                // Pictures carry no file name in AX. An unplaced or incoming picture
                // is not proof that the pasted attachment was sent.
                return true
            case .file, .video:
                // A native video row carries no name in the AX tree (`MessageRowParser` reads only the play
                // icon and the duration off it), so the name is required exactly when the row shows one —
                // which in 5.0.11 means every `file` row.
                guard let name = row.fileName else { return row.kind == .video }
                return FileNames.sanitize(name, fallback: "") == pastedName
            default:
                return false
            }
        }
        let deadline = started.addingTimeInterval(timeout)
        var evidence: String?
        var targetDrifted = false
        while true {
            guard (try? reader.activeConversationTitle()) == active else { targetDrifted = true; break }
            // `try?`, not `try`: an AX read that fails here is AFTER the irreversible Return, and letting it
            // escape would surface as CLIENT_UNAVAILABLE → `failed`, which tells a consumer to send the same
            // file again. Skip this poll instead and let the composer-based decision below settle it as
            // `succeeded` / `unknown` (review 2026-09-23).
            let rows = try? reader.chatMessages(conversationTitle: active)
            guard (try? reader.activeConversationTitle()) == active else { targetDrifted = true; break }
            if let row = rows.flatMap({ SendEvidence.newRows(baseline: baselineRows, observed: $0) })?.last(where: isEvidence) {
                evidence = "row #\(row.index) kind=\(row.kind.rawValue) dir=\(row.direction.rawValue) time=\(row.timeLabel ?? "-")"
                break
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let composerAfter = composerSignal(composer)
        details["composerAfter"] = composerAfter

        if targetDrifted {
            checkpoint.state = .unknown; checkpoint.reason = "active conversation changed during attachment confirmation"
            try checkpoints.write(checkpoint)
            return outcome(.unknown, reason: checkpoint.reason, latency: latency)
        }
        if let evidence {
            checkpoint.state = .succeeded; checkpoint.evidence = evidence
            try checkpoints.write(checkpoint)
            return outcome(.succeeded, reason: nil, evidence: evidence, latency: latency)
        }
        // Return has already crossed the irreversible point. Without a new
        // outbound row, neither a remaining chip nor an empty composer proves
        // whether WeCom sent the file. Leave the composer untouched: clearing
        // it after a separate AX read can erase a human edit in that gap.
        checkpoint.state = .unknown
        checkpoint.reason = composerAfter == composerBefore
            ? "composer emptied but no new media / file / video row was observed"
            : "no new media / file / video row within \(Int(timeout)) s; composer changed after submit"
        try checkpoints.write(checkpoint)
        return outcome(.unknown, reason: checkpoint.reason, latency: latency)
    }
}

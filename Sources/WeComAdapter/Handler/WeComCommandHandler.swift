import AXKit
import CoreGraphics
import ControlCore
import Foundation

private struct ComposerVisualAnchor {
    let windowHandle: AXElementHandle
    let windowPID: pid_t
    let windowFrame: CGRect
    let composerHandle: AXElementHandle
    let composerFrame: CGRect
}

private final class ComposerVisualState {
    var anchor: ComposerVisualAnchor?
    var settings: CloudVisionSettings?
    var beforeVerified = false
    var afterVerified = false
}

private struct GroupNameVisualAnchor {
    let windowHandle: AXElementHandle
    let windowPID: pid_t
    let windowFrame: CGRect
    let fieldHandle: AXElementHandle
    let fieldFrame: CGRect
}

private final class GroupNameVisualState {
    var anchor: GroupNameVisualAnchor?
    var originalValue: String?
    var settings: CloudVisionSettings?
    var beforeVerified = false
    var afterVerified = false
    var reconcileStaleView = false
}

private struct GroupCreateVisualAnchor {
    let windowHandle: AXElementHandle
    let windowPID: pid_t
    let windowFrame: CGRect
}

private final class GroupCreateVisualState {
    var anchor: GroupCreateVisualAnchor?
    var settings: CloudVisionSettings?
    var beforeVerified = false
    var afterVerified = false
}

private struct NavigationVisualAnchor {
    let windowHandle: AXElementHandle
    let windowPID: pid_t
    let windowFrame: CGRect
    let beforeTitle: String
}

private final class NavigationVisualState {
    var anchor: NavigationVisualAnchor?
    var settings: CloudVisionSettings?
    var beforeVerified = false
    var afterVerified = false
}

private struct ContactAcceptVisualAnchor {
    let windowHandle: AXElementHandle
    let windowPID: pid_t
    let windowFrame: CGRect
    let card: NewCustomerCard
    let acceptFrame: CGRect
    var doneHandle: AXElementHandle?
    var doneFrame: CGRect?
}

private final class ContactAcceptVisualState {
    var anchor: ContactAcceptVisualAnchor?
    var settings: CloudVisionSettings?
    var acceptVerified = false
    var doneVerified = false
}

private struct BroadcastConfirmVisualAnchor {
    let mainWindowHandle: AXElementHandle
    let mainWindowFrame: CGRect
    let taskWindowHandle: AXElementHandle
    let taskWindowFrame: CGRect
    let pid: pid_t
    let panelHandle: AXElementHandle
    let buttonHandle: AXElementHandle
    let buttonFrame: CGRect
    let msgid: String
}

private final class BroadcastConfirmVisualState {
    var anchor: BroadcastConfirmVisualAnchor?
    var settings: CloudVisionSettings?
    var beforeVerified = false
    var afterVerified = false
}

/// Binds the protocol's methods to the WeCom adapter. Every call re-locates
/// the window (cheap enough at v0.1 call rates) so stale elements never leak
/// across commands. Targets arrive in wire form (title, `chatId:` or
/// `externalUserId:`), are resolved through the identity bridge and what the
/// conversation list shows, and are judged by the policy before anything
/// touches the client; the resolved target then travels with the actions so
/// their inner checks agree with the command-level one.
public final class WeComCommandHandler: CheckpointedDesktopCommandHandler, DesktopCommandOriginAware {
    public let rootProvider: () throws -> AXElement
    public var policy: ActionPolicy
    public let checkpoints: CheckpointStore
    public var strategy: SubmitStrategy
    public var submitTimeout: TimeInterval
    public let identities: IdentityLookup
    /// Background policy rounds never invoke cloud task planning.
    public var desktopCommandOrigin: DesktopCommandOrigin = .external {
        didSet {
            visualRounds = 0
            visualStartedAt = Date()
        }
    }
    public var desktopCommandMethod: RPCMethod?
    /// Set by the executor for message.broadcast's internal message.send
    /// children. Their existing target-selection path remains available, but
    /// B36 composer observation is only for a directly requested send.
    public var desktopCommandIsBroadcastChild = false
    /// B54: where a visual round ended the running command. The executor clears it before each command, and
    /// the rounds go with it: a new command never reports an earlier command's round.
    public var desktopCommandVisualEnd: CommandDiagnosis.Visual? {
        didSet {
            if desktopCommandVisualEnd == nil { lastVisualRound = nil; visualStep = nil; visualEndNoted = false }
        }
    }
    /// B54: one fixed-category line per model request; the daemon passes its log.
    public var visualRoundLog: ((String) -> Void)?
    /// B54: the last model round of the running command's current visual step.
    private var lastVisualRound: AIPlannerRoundRecord?
    /// B54: the visual step now running (only its goal's kind is kept).
    private var visualStep: (goal: String, phase: AIPlannerPhase)?
    /// B54: an end was noted after the last round — a stop the handler then rethrows as a vision error keeps
    /// the stop.
    private var visualEndNoted = false

    /// B54: the rounds of every runner and of the selector come here.
    public func noteVisualRound(_ record: AIPlannerRoundRecord) {
        lastVisualRound = record
        visualEndNoted = false
        visualRoundLog?(record.line)
    }

    /// B54: this runner reports its rounds to the handler.
    func recording(_ runner: AIPlannerReversibleRunner) -> AIPlannerReversibleRunner {
        var runner = runner
        runner.roundSink = { [weak self] in self?.noteVisualRound($0) }
        return runner
    }

    /// B54: a visual step of this command starts. Until its first model round, an end is reported at this
    /// step with round 0 — never at an earlier step's round.
    func beginVisualStep(_ goal: AIPlannerGoal, phase: AIPlannerPhase) {
        visualStep = (goal.logName, phase)
        lastVisualRound = nil
        visualEndNoted = false
    }

    /// B54: the visual part of this command ended with `outcome` at its current step: after the step's last
    /// round, at round 0 before its first, or `none` before any visual step. The first end after a round stands.
    func markVisualEnd(_ outcome: String) {
        guard !visualEndNoted else { return }
        desktopCommandVisualEnd = lastVisualRound?.ended(outcome)
            ?? visualStep.map { CommandDiagnosis.Visual(goal: $0.goal, phase: $0.phase.rawValue, round: 0, outcome: outcome) }
            ?? CommandDiagnosis.Visual(goal: "none", phase: "none", round: 0, outcome: outcome)
        visualEndNoted = true
    }

    /// B54: a visual round ended this command: note where, then fail exactly as before.
    func visualEnded(_ message: String, outcome: String) -> ActionError {
        markVisualEnd(outcome)
        return ActionError.actionUnavailable(message)
    }
    /// An explicit command may ask the configured model to choose one current
    /// AX candidate. This closure is never installed on automatic policy rounds.
    public var visualSelect: ((AXElement, AIPlannerGoal, Set<AIPlannerCandidateKind>, String?, [AXElement], () throws -> Void) throws -> AIPlannerCandidate?)?
    public var visualEnabled: () -> Bool = { false }
    /// The executor may recheck pause state before every reversible visual action.
    public var visualCommandGate: () throws -> Void = {}
    /// Test seam for the bounded command runner; production uses the configured cloud model.
    public var reversibleRunnerFactory: (() -> AIPlannerReversibleRunner)?
    /// Test seam for `contact.add` that keeps the handler's own capture choice: the factory
    /// receives that capture, so a test observes which window and number would be taken.
    public var contactAddRunnerFactory: ((@escaping AIPlannerObservation.Capture) -> AIPlannerReversibleRunner)?
    /// The one screen capture `contact.add` uses (pid, expected frame, child windows, owned number).
    public var windowCapture: (pid_t, CGRect, Bool, CGWindowID?) -> WeComWindowScreenshot? = {
        WeComScreenCapture.capture(windowPID: $0, expectedFrame: $1, includeChildWindows: $2, windowID: $3)
    }
    /// The local grant/provider snapshot rechecked just before an observed
    /// composer can cross the irreversible boundary. Tests inject a fake
    /// settings value; production rereads the private local settings file.
    public var visualSettingsForCommit: () throws -> CloudVisionSettings = {
        try CloudVisionSettings.loadOrDefault()
    }
    public var visualScreenRecordingGranted: () -> Bool = {
        WeComCommandHandler.screenRecordingGrantedNow()
    }
    public var maxVisualRounds = 6
    public var maxVisualDuration: TimeInterval = 40
    /// Read-only history and request-list navigation can spend more time in
    /// WeCom's AX tree than a write prefix. This is still one command-wide
    /// deadline, measured from command entry, and never changes the 8 s HTTP
    /// limit of an individual model request or any mutation command's budget.
    public var maxReadNavigationVisualDuration: TimeInterval = 60
    private var visualRounds = 0
    private var visualStartedAt = Date()

    private func visualDuration(for method: RPCMethod?) -> TimeInterval {
        switch method {
        case .messageHistory, .contactList, .contactRequestList:
            return min(maxReadNavigationVisualDuration, 60)
        default:
            return maxVisualDuration
        }
    }

    /// Charge every cloud inference round to the current external command.
    /// A reobserve response consumes a round just like an actionable choice.
    public func beginVisualRound() throws {
        guard desktopCommandOrigin == .external, desktopCommandMethod != nil,
              visualEnabled(), visualRounds < maxVisualRounds,
              Date().timeIntervalSince(visualStartedAt) < visualDuration(for: desktopCommandMethod) else {
            throw AIPlannerVisionError.timeout
        }
        visualRounds += 1
    }

    func assertVisualBudget(for method: RPCMethod) throws {
        guard desktopCommandOrigin == .external, desktopCommandMethod == method,
              visualEnabled(), Date().timeIntervalSince(visualStartedAt) < visualDuration(for: method) else {
            throw AIPlannerVisionError.timeout
        }
    }
    /// Live policy file (reloaded by the daemon); nil = compiled allowlist only.
    public var sendPolicyProvider: (() -> SendPolicy)?
    /// Lets the daemon attach a step trace and tests inject a recording key poster.
    public var configureActions: (inout WeComActions) -> Void = { _ in }
    /// Visual side evidence is optional and read-only. The default takes one
    /// in-memory WeCom window frame only for AX-unknown visible media rows.
    public var resolveVisualDirections: (WeComReader, inout [MessageRow], [Int]) -> Void = VisualDirectionResolver.resolve

    public init(rootProvider: @escaping () throws -> AXElement, policy: ActionPolicy, checkpoints: CheckpointStore,
                strategy: SubmitStrategy = .enterKey, submitTimeout: TimeInterval = 10, identities: IdentityLookup = NoIdentities()) {
        self.rootProvider = rootProvider
        self.policy = policy
        self.checkpoints = checkpoints
        self.strategy = strategy
        self.submitTimeout = submitTimeout
        self.identities = identities
    }

    /// The compiled policy with the current policy-file rules merged in.
    public var currentPolicy: ActionPolicy {
        var p = policy
        if let provider = sendPolicyProvider { p.sendPolicy = provider() }
        return p
    }

    // MARK: CommandHandler

    public func describe() throws -> [String: String] {
        let p = currentPolicy
        let vision = AIPlannerDiagnostics.snapshot()
        return [
            "platform": "wecom",
            "client": WeComClient.bundleID,
            "submitStrategy": strategy.rawValue,
            "allowlist": p.allowedTargets.sorted().joined(separator: ","),
            "policy": p.sendPolicy.summary,
            "targetSyntax": "title | chatId:<id> | externalUserId:<id>",
            "phase": p.phase == .phase1 ? "1" : "0",
            // Process-local counts contain no screenshot, AX label, model text,
            // target, or credential. A before/after delta can prove a live
            // model request; HTTP 200 alone is not a successful AX command.
            "visionCaptureCount": String(vision.captureCount),
            "visionRequestCount": String(vision.requestCount),
            "visionHTTP200Count": String(vision.successCount),
        ]
    }

    public func accountStatus() throws -> [String: String] {
        do {
            let r = try reader()
            let rows = try r.conversations()
            let header = try r.activeConversationHeader()
            var out: [String: String] = [
                "windowReachable": "true",
                "activeTitle": header?.title ?? "",
                "conversationCount": String(rows.count),
                "composerPresent": r.layout.composer == nil ? "false" : "true",
                "activeType": try r.activeConversationType().rawValue,
            ]
            if let n = header?.memberCount { out["activeMemberCount"] = String(n) }
            return out
        } catch WeComError.noWindow {
            return ["clientRunning": "true", "windowReachable": "false", "loginRequired": "unknown"]
        } catch let e as WeComError {
            return ["clientRunning": "true", "windowReachable": "true", "layoutError": e.description]
        } catch AXKitError.applicationNotRunning {
            return ["clientRunning": "false", "windowReachable": "false"]
        } catch let e as AXKitError {
            return ["clientRunning": "true", "windowReachable": "false", "axError": e.description]
        }
    }

    public func conversationList() throws -> [[String: String]] {
        try mapErrors {
            try reader().conversations().map { row in
                var d: [String: String] = [
                    "index": String(row.index), "selected": row.selected ? "true" : "false",
                    "conversationType": ConversationTypeInference.infer(row: row).rawValue,
                ]
                if let v = row.title { d["title"] = v }
                if let v = row.preview { d["preview"] = v }
                if let v = row.timeLabel { d["timeLabel"] = v }
                if let v = row.badge { d["badge"] = v }
                if !row.markers.isEmpty { d["markers"] = row.markers.joined(separator: ",") }
                return d
            }
        }
    }

    public func conversationRead(target rawTarget: String) throws -> [String: String] {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            var selected: ResolvedTarget?
            // A row selection can be dropped while WeCom rebuilds its sidebar. Re-observe the
            // current window and resolve the same identity afresh before one bounded retry.
            // This only repeats a reversible selection, never a send or another mutation.
            for round in 0..<2 {
                let observed = try reader()
                let (resolved, hasParsedRow) = try resolveWithRowStatus(ref, reader: observed)
                if try observed.activeConversationTitle() == resolved.title {
                    // An already-active conversation still goes through the read gate.
                    try policyCheck(.selectConversation, resolved: resolved)
                    selected = resolved
                    break
                }
                if try shouldUseVisualConversationRounds(reader: observed, title: resolved.title,
                                                         hasParsedRow: hasParsedRow, method: .conversationRead) {
                    try selectConversationWithVisualRounds(ref: ref, resolved: resolved,
                                                           method: .conversationRead, requiredAction: .selectConversation)
                    selected = resolved
                    break
                }
                do {
                    _ = try actions(for: resolved).selectConversation(resolved.title, reader: observed)
                } catch ActionError.targetMismatch where round == 0 {
                    // The action's own AX readback failed. A fresh observation on the next
                    // round determines whether the late selection landed or may be retried.
                    continue
                }
                let reobserved = try reader()
                let actual = try reobserved.activeConversationTitle()
                if actual == resolved.title {
                    selected = resolved
                    break
                }
                if round == 1 { throw ActionError.targetMismatch(expected: resolved.title, actual: actual) }
            }
            guard let resolved = selected else { throw ActionError.verifyFailed("conversation selection did not settle") }
            let fresh = try reader()
            let header = try fresh.activeConversationHeader()
            guard header?.title == resolved.title else {
                throw ActionError.targetMismatch(expected: resolved.title, actual: header?.title)
            }
            let messages = try fresh.chatMessages(conversationTitle: header?.title)
            let activeRow = try fresh.activeConversationRow()
            var out: [String: String] = [
                "active": header?.title ?? "",
                "messageCount": String(messages.count),
                "composerPresent": fresh.layout.composer == nil ? "false" : "true",
                "conversationType": ConversationTypeInference.infer(header: header, messages: messages, row: activeRow).rawValue,
            ]
            if let id = resolved.chatId { out["chatId"] = id }
            if let id = resolved.externalUserId { out["externalUserId"] = id }
            return out
        }
    }

    public func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] {
        try mapErrors {
            var r = try reader()
            if scrollback, limit > 0, try r.chatMessages().count < limit {
                let active = try resolveActive(reader: r)
                _ = try actions(for: active).loadOlderMessages(reader: r, minRows: limit)
                r = try reader()
            } else if !scrollback, limit > 0 {
                // Explicit history reads promise the newest rows. A client left
                // in old history may expose only that old AX page; suffix(limit)
                // alone would return it as though it were current. The watcher
                // never enters this method, so polling does not move the UI.
                // Avoid an extra full message parse for the usual ungated read.
                let active = currentPolicy.sendPolicy.gateReads ? try resolveActive(reader: r) : nil
                if try actions(for: active).showLatestMessages(reader: r) { r = try reader() }
            }
            let activeTitle = try r.activeConversationTitle()
            var messages = try r.chatMessages(conversationTitle: activeTitle)
            if messages.last?.kind == .media {
                // The selected row's preview is evidence only for the latest message.
                // Avoid another AX conversation-table read for ordinary text/file/video histories.
                let selected = try r.conversations().first { $0.selected }
                MessageMediaTypeInference.enrichLatest(&messages, selected: selected, activeTitle: activeTitle)
            }
            let requestedCount = min(max(limit, 0), messages.count)
            if requestedCount > 0 {
                resolveVisualDirections(r, &messages, Array((messages.count - requestedCount)..<messages.count))
            }
            return messages.suffix(max(limit, 0)).map { m in
                var d: [String: String] = ["index": String(m.index), "direction": m.direction.rawValue, "kind": m.kind.rawValue]
                if let v = m.text { d["text"] = v }
                if let v = m.timeLabel { d["timeLabel"] = v }
                if let v = m.senderLabel { d["sender"] = v }
                if let v = m.fileName { d["fileName"] = v }
                if let v = m.fileSize { d["fileSize"] = v }
                if let v = m.fileType { d["fileType"] = v }
                if let v = m.duration { d["duration"] = v }
                if let v = m.mediaType { d["mediaType"] = v.rawValue }
                if let v = m.readError { d["readError"] = v }
                if let v = m.messageKey {
                    d["messageKey"] = v
                    // B10: whether message.media has (or can probably find) the picture behind a media / file / video row
                    if [.media, .file, .video].contains(m.kind) { d["media"] = mediaIndex.assignment(for: v) != nil ? "assigned" : (mediaIndex.observation(for: v) != nil ? "observed" : "unmatched") }
                }
                return d
            }
        }
    }

    public func messageSend(target rawTarget: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let (resolved, hasParsedRow) = try resolveWithRowStatus(ref, reader: r)
            try policyCheck(.submit, resolved: resolved)
            try selectTargetForMutation(ref: ref, resolved: resolved, reader: r,
                                        hasParsedRow: hasParsedRow, method: .messageSend, action: .submit)
            let fresh = try reader()
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try actions(for: resolved).submit(text: text, strategy: strategy, reader: fresh, checkpoints: checkpoints,
                                                  timeout: submitTimeout, hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            let state: CommandStateV1
            switch outcome.state {
            case .succeeded: state = .succeeded
            case .failed: state = .failed
            case .unknown, .pending: state = .unknown
            }
            return SendResult(state: state, evidence: outcome.evidence, reason: outcome.reason, latencyMs: outcome.latencyMs)
        }
    }

    /// B13: policy (target, then source) → fetch → select → paste + Return. The outbox file is deleted whatever happens.
    public func messageSendFile(target rawTarget: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let (resolved, hasParsedRow) = try resolveWithRowStatus(ref, reader: r)
            try policyCheck(.sendFile, resolved: resolved)
            let fetched: FetchedFile
            switch source {
            case .url(let url):
                fetched = try fileFetcher.fetch(url: url, fileName: fileName, policy: currentPolicy.sendPolicy.sendFile)
            case .ossKey(let key):
                guard let store = objectStore else { throw ControlError.ossNotConfigured("message.sendFile{ossKey} needs oss.json on this Mac (imctl oss set, or the console's 设置 page)") }
                fetched = try fileFetcher.fetch(ossKey: key, fileName: fileName, store: store, maxBytes: currentPolicy.sendPolicy.sendFile.maxBytes)
            }
            defer { fileFetcher.discard(fetched) }
            try selectTargetForMutation(ref: ref, resolved: resolved, reader: r,
                                        hasParsedRow: hasParsedRow, method: .messageSendFile, action: .sendFile)
            let fresh = try reader()
            let timeout = Self.sendFileTimeout(kind: fetched.kind, bytes: fetched.bytes)
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try actions(for: resolved).sendFile(fetched, reader: fresh, checkpoints: checkpoints, timeout: timeout,
                                                    hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            if outcome.details["pasteFailed"] == "true" { throw ControlError.pasteFailed(outcome.reason ?? "paste failed") }
            let state: CommandStateV1
            switch outcome.state {
            case .succeeded: state = .succeeded
            case .failed: state = .failed
            case .unknown, .pending: state = .unknown
            }
            return SendFileResult(state: state, evidence: outcome.evidence, reason: outcome.reason, latencyMs: outcome.latencyMs,
                                  fileName: fetched.fileName, bytes: fetched.bytes, contentType: fetched.contentType, kind: fetched.kind)
        }
    }

    /// Spec §7: pictures 15 s, files 30 s, videos 30 s + 10 s per 10 MB, capped at 180 s (the client uploads
    /// before the bubble appears; live 2026-09-22, WeCom 5.0.11).
    static func sendFileTimeout(kind: String, bytes: Int64) -> TimeInterval {
        switch kind {
        case "image": return 15
        case "video": return min(180, 30 + Double(bytes / 10_485_760) * 10)
        default: return 30
        }
    }

    /// The desktop step of `broadcast.confirm`; wired into the API handler by the daemon.
    public func confirmBroadcast(msgid: String?) throws -> [String: String] {
        try confirmBroadcast(msgid: msgid, checkpoint: {}, afterSubmit: {})
    }

    public func confirmBroadcast(msgid: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try mapErrors {
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                var action = actions(for: nil)
                if desktopCommandOrigin == .external, desktopCommandMethod == .broadcastConfirm,
                   visualEnabled(), visualSelect != nil {
                    installBroadcastConfirmVisualObservation(on: &action)
                }
                return try action.confirmBroadcast(reader: try reader(), msgid: msgid,
                    hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            var out = outcome.details
            out["verified"] = outcome.verified ? "true" : "false"
            return out
        }
    }

    /// The model only reviews a task that the AX action already proved unique
    /// across WeCom windows by exact msgid. The original checkpoint and sole
    /// fixed AXPress remain in BroadcastConfirm.swift.
    private func installBroadcastConfirmVisualObservation(on actions: inout WeComActions) {
        let state = BroadcastConfirmVisualState()
        let policyAtEntry = actions.policy

        func freshTask(_ window: AXElement, _ panel: AXElement, _ button: AXElement,
                       _ msgid: String, _ axVerify: () throws -> Bool) throws -> AXElement {
            guard let anchor = state.anchor, msgid == anchor.msgid,
                  try axVerify(),
                  let main = try? self.reader().layout.window,
                  main.handle == anchor.mainWindowHandle,
                  try main.pid() == anchor.pid,
                  let mainFrame = try main.frame(),
                  Self.sameHistoryFrame(mainFrame, anchor.mainWindowFrame),
                  window.handle == anchor.taskWindowHandle,
                  try window.role() == AXRole.window,
                  try window.pid() == anchor.pid,
                  let frame = try window.frame(),
                  Self.sameHistoryFrame(frame, anchor.taskWindowFrame),
                  panel.handle == anchor.panelHandle,
                  try panel.pid() == anchor.pid,
                  button.handle == anchor.buttonHandle,
                  try button.role() == AXRole.button,
                  try button.pid() == anchor.pid,
                  try button.actions().contains(AXAction.press),
                  try button.isEnabled() == true,
                  let buttonFrame = try button.frame(),
                  Self.sameHistoryFrame(buttonFrame, anchor.buttonFrame) else {
                throw AIPlannerVisionError.staleView
            }
            if window.backend.name == "live" {
                let app = AXApp.byPID(anchor.pid, backend: window.backend)
                let windows = try app.elements(AXAttribute.windows)
                guard windows.contains(where: { $0.handle == window.handle }),
                      windows.contains(where: { $0.handle == main.handle }),
                      let focused = try app.element(AXAttribute.focusedWindow),
                      focused.handle == window.handle else {
                    throw AIPlannerVisionError.staleView
                }
            }
            return window
        }

        func gate(_ window: AXElement, _ panel: AXElement, _ button: AXElement,
                  _ msgid: String, _ axVerify: () throws -> Bool) throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .broadcastConfirm,
                  self.visualEnabled(), self.visualSelect != nil,
                  self.visualScreenRecordingGranted() else {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .broadcastConfirm)
            try self.visualCommandGate()
            let policy = self.currentPolicy
            guard policy.phase == policyAtEntry.phase,
                  policy.enabled == policyAtEntry.enabled,
                  policy.allowedTargets == policyAtEntry.allowedTargets,
                  policy.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            try policy.authorize(.confirmBroadcast, target: nil)
            _ = try freshTask(window, panel, button, msgid, axVerify)
            if let settings = state.settings,
               try self.visualSettingsForCommit() != settings {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .broadcastConfirm)
        }

        actions.visualObserveBroadcastConfirm = { reader, window, panel, button, msgid, stage, axVerify in
            self.beginVisualStep(.control(.broadcastSend), phase: stage == .beforePress ? .commit : .verify)
            if stage == .beforePress {
                guard state.anchor == nil, !state.beforeVerified,
                      !msgid.isEmpty, let mainFrame = try reader.layout.window.frame(),
                      let taskFrame = try window.frame(),
                      let buttonFrame = try button.frame(),
                      taskFrame.width > 0, taskFrame.height > 0,
                      buttonFrame.width > 0, buttonFrame.height > 0,
                      try reader.layout.window.pid() == window.pid() else {
                    throw AIPlannerVisionError.staleView
                }
                state.anchor = BroadcastConfirmVisualAnchor(
                    mainWindowHandle: reader.layout.window.handle, mainWindowFrame: mainFrame,
                    taskWindowHandle: window.handle, taskWindowFrame: taskFrame,
                    pid: try window.pid(), panelHandle: panel.handle,
                    buttonHandle: button.handle, buttonFrame: buttonFrame, msgid: msgid)
            } else {
                guard state.beforeVerified, !state.afterVerified else {
                    throw AIPlannerVisionError.invalidGoal
                }
            }
            let phase: AIPlannerPhase = stage == .beforePress ? .commit : .verify
            let evidence: AIPlannerEvidence = stage == .beforePress ? .pendingConfirmation : .submitted
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() })
            do {
                let result = try self.recording(runner).observeBroadcastConfirmControl(
                    phase: phase, expectedSettings: state.settings,
                    gate: { try gate(window, panel, button, msgid, axVerify) },
                    observe: {
                        let fresh = try freshTask(window, panel, button, msgid, axVerify)
                        return AIPlannerReversibleRound(window: fresh, goal: .control(.broadcastSend),
                            action: .press, eligible: [button], expectedTitle: nil,
                            phase: phase, evidence: evidence)
                    }, verify: { try axVerify() })
                guard result.outcome == .verified else {
                    self.markVisualEnd(result.outcome.logName)
                    throw AIPlannerVisionError.invalidChoice
                }
                state.settings = result.settings
                if stage == .beforePress { state.beforeVerified = true }
                else { state.afterVerified = true }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("broadcast confirm visual round: \(error)", outcome: error.logName)
            }
        }
        actions.visualBroadcastConfirmPressGate = { window, panel, button, msgid, axVerify in
            do {
                guard state.beforeVerified, let settings = state.settings else {
                    throw AIPlannerVisionError.invalidGoal
                }
                try gate(window, panel, button, msgid, axVerify)
                guard try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("broadcast confirm visual press: \(error)", outcome: error.logName)
            }
        }
    }

    public func clientNavigate(action: NavigateAction) throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider()
            return try actions(for: nil).navigate(action, app: app, reader: try reader()).details
        }
    }

    public func contactList(limit: Int, scope: String) throws -> [[String: String]] {
        try mapErrors {
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            let which: WeComActions.ContactScope = scope == "all" ? .all : .customers
            return try actions(for: nil).readContacts(app: app, window: window, limit: limit, scope: which).map { c in
                var d = ["name": c.name, "source": c.source, "section": c.section]
                if let t = c.tag { d["tag"] = t }
                return d
            }
        }
    }

    /// B10: the client's local media cache, scanned on its own thread through the daemon's own file grant.
    public var mediaCacheScanner = WeComMediaCacheScanner()
    /// B10: where the client keeps pictures, and what the daemon has tied to which message.
    public var mediaStore = WeComMediaStore()
    public var mediaIndex = MediaIndex(fileURL: nil)
    /// B13: downloads for message.sendFile land here (owner-only outbox, swept at daemon start).
    public var fileFetcher = FileFetcher(outbox: IMCTLPaths.outboxDirectory)
    /// Exact event/command lookup for a sent file whose client cache copy is gone.
    public var sentAttachmentSource: ((String) throws -> SentFileSource?)?
    /// B13: the object store behind message.media and ossKey sources; nil = OSS_NOT_CONFIGURED.
    public var objectStore: ObjectStore?

    public func mediaCache(limit: Int, refresh: Bool) throws -> MediaCacheReport {
        mediaCacheScanner.report(limit: limit, refresh: refresh)
    }

    public func mediaCacheList(root: String?, dir: String) throws -> MediaCacheReport {
        try mapErrors { try Self.withFileGrantTimeout("controller.mediaCache{dir}") { try self.mediaCacheScanner.list(root: root, dir: dir) } }
    }

    /// What the console's 诊断 page shows, read through the daemon's own grant.
    public func diagnose() throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider()
            var d: [String: String] = ["trusted": app.backend.isProcessTrusted(prompt: false) ? "true" : "false"]
            let window = try WeComWindowLocator.mainWindow(from: app)
            let r = try WeComReader(window: window)
            let l = r.layout
            func rect(_ f: CGRect) -> String { "(\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width))×\(Int(f.height)))" }
            d["windowFrame"] = rect(l.windowFrame)
            d["conversationTable"] = rect(l.conversationTableFrame)
            d["messageTable"] = l.messageTableFrame.map(rect) ?? ""
            d["composerPresent"] = l.composer != nil ? "true" : "false"
            d["activeTitle"] = try r.activeConversationTitle() ?? ""
            d["activeType"] = try r.activeConversationType().rawValue
            let rows = try r.conversations()
            d["conversationCount"] = String(rows.count)
            d["rowHeights"] = Array(Set(rows.map { Int($0.frame.height) })).sorted().map(String.init).joined(separator: ",")
            d["messageImages"] = String(l.messageImages.count)
            return d
        }
    }

    public func contactRequestList() throws -> [[String: String]] {
        try mapErrors {
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            return try actions(for: nil).contactRequestList(app: app, window: window).map { card in
                var d = ["name": card.name, "source": card.source, "status": card.status.rawValue]
                if let g = card.greeting { d["greeting"] = g }
                return d
            }
        }
    }

    public func contactRequestAccept(name: String) throws -> [String: String] {
        try contactRequestAccept(name: name, checkpoint: {}, afterSubmit: {})
    }

    public func contactRequestAccept(name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            var action = actions(for: nil)
            if desktopCommandOrigin == .external, desktopCommandMethod == .contactRequestAccept,
               visualEnabled(), visualSelect != nil {
                installContactAcceptVisualObservation(on: &action)
            }
            let out = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try action.contactRequestAccept(name: name, app: app, window: window,
                                                hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            return ["name": name, "accepted": "true", "status": out.details["status"] ?? "added"]
        }
    }

    /// With `name` the header title field is written once the group opened (B8); `renamed` says whether the client took it.
    public func groupCreate(members: [String], name: String?) throws -> [String: String] {
        try groupCreate(members: members, name: name, checkpoint: {}, afterSubmit: {})
    }

    public func groupCreate(members: [String], name: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            let out = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try actions(for: nil).createGroup(members: members, name: name, app: app, window: window,
                                                  hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            var d = ["title": out.details["title"] ?? "", "memberCount": out.details["memberCount"] ?? "", "renamed": out.details["renamed"] ?? "false",
                     "opened": out.details["opened"] ?? "false"]
            if let name { d["requestedName"] = name }
            return d
        }
    }

    /// B12: any phone number (user decision 2026-10-13); names of the matches come back, the number never does.
    public func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool) throws -> [String: String] {
        try contactAdd(phone: phone, source: source, greeting: greeting, dryRun: dryRun, checkpoint: {}, afterSubmit: {})
    }

    public func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try mapErrors {
            guard currentPolicy.sendPolicy.contactAdd.allows(phone) else {
                throw ControlError.invalidParams("contact.add needs a phone number")
            }
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            var action = actions(for: nil)
            if desktopCommandOrigin == .external, desktopCommandMethod == .contactAdd,
               visualEnabled(), visualSelect != nil, action.visualActionGate != nil {
                action.visualOpenAddCustomerRounds = { [weak self] observedApp, observedWindow in
                    guard let self else { throw AIPlannerVisionError.disabled }
                    return try self.openAddCustomerHeaderWithVisualRounds(
                        originalApp: observedApp, originalWindow: observedWindow, phone: phone)
                }
                try installContactAddVisualObservation(on: &action, originalApp: app,
                                                       originalWindow: window, phone: phone)
            }
            let out = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try action.addContact(phone: phone, source: source, greeting: greeting, dryRun: dryRun, app: app, window: window,
                                      hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            var d: [String: String] = ["status": out.status, "matches": String(out.matches.count), "dryRun": dryRun ? "true" : "false", "phone": ContactAddPolicy.mask(phone)]
            for (i, m) in out.matches.enumerated() { d["match\(i)"] = "\(m.source)/\(m.name)" + (m.subtitle.map { " (\($0))" } ?? "") }
            if let c = out.chosen { d["chosen"] = "\(c.source)/\(c.name)" }
            d.merge(out.details) { current, _ in current }
            return d
        }
    }

    /// The model can veto fixed search, source-match and invite stages only
    /// after the action proved that this command opened a fresh search window.
    /// The phone and greeting are never included in the text goal.
    private func installContactAddVisualObservation(on actions: inout WeComActions,
                                                    originalApp: AXElement,
                                                    originalWindow: AXElement,
                                                    phone: String) throws {
        let originalPID = try originalApp.pid()
        guard originalPID > 0, try originalWindow.pid() == originalPID,
              let originalFrame = try originalWindow.frame(),
              let actionGate = actions.visualActionGate else {
            throw AIPlannerVisionError.staleView
        }
        let policyAtEntry = currentPolicy
        var panelHandle: AXElementHandle?
        var panelFrame: CGRect?
        var searchHandle: AXElementHandle?
        var settings: CloudVisionSettings?
        var searchObserved = false
        var matchObserved = false
        var inviteObserved = false

        func freshWindows() throws -> (AXElement, AXElement, [AXElement]) {
            let app = try rootProvider()
            guard app.backend === originalApp.backend,
                  app.handle == originalApp.handle,
                  try app.role() == AXRole.application,
                  try app.pid() == originalPID else { throw AIPlannerVisionError.staleView }
            let windows = try app.elements(AXAttribute.windows)
            guard let main = windows.first(where: { $0.handle == originalWindow.handle }),
                  try main.role() == AXRole.window,
                  try main.pid() == originalPID,
                  let frame = try main.frame(), Self.sameHistoryFrame(frame, originalFrame),
                  WeComContactsView.isShowing(window: main) else {
                throw AIPlannerVisionError.staleView
            }
            return (app, main, windows)
        }

        /// `invite` is the one 发送验证申请 window the action saw appear after its own
        /// match press (B51); only that window, still in that shape, may stand
        /// beside the panel. Any other extra window is a changed view.
        func freshPanel(tolerating invite: AXElementHandle? = nil) throws -> (AXElement, AXElement, AddCustomerPanel) {
            let (app, main, allWindows) = try freshWindows()
            let windows = allWindows.filter { $0.handle != invite || !AddCustomerPanel.isVerificationWindow($0) }
            guard windows.count == 2,
                  let other = windows.first(where: { $0.handle != main.handle }),
                  panelHandle == nil || other.handle == panelHandle,
                  try other.role() == AXRole.window,
                  try other.pid() == originalPID,
                  let frame = try other.frame(),
                  panelFrame.map({ Self.sameHistoryFrame(frame, $0) }) ?? true,
                  let panel = try AddCustomerPanel.locate(app: app, mainWindow: main),
                  panel.window.handle == other.handle,
                  searchHandle == nil || panel.searchField.handle == searchHandle else {
                throw AIPlannerVisionError.staleView
            }
            let all = other.descendants(maxDepth: 12, maxNodes: 4000)
            guard all.filter({ (try? $0.role()) == AXRole.staticText
                               && (try? $0.valueString()) == "添加客户" }).count == 1,
                  all.filter({ (try? $0.role()) == AXRole.textField }).count == 1,
                  all.filter({ (try? $0.role()) == AXRole.button
                               && (try? $0.subrole()) == "AXCloseButton" }).count == 1,
                  try panel.searchField.isSettable(AXAttribute.value) else {
                throw AIPlannerVisionError.staleView
            }
            return (app, main, panel)
        }

        func gate(tolerating invite: AXElementHandle? = nil) throws {
            guard desktopCommandOrigin == .external,
                  desktopCommandMethod == .contactAdd,
                  visualEnabled(), visualSelect != nil,
                  visualScreenRecordingGranted() else {
                throw AIPlannerVisionError.disabled
            }
            try assertVisualBudget(for: .contactAdd)
            try visualCommandGate()
            let policy = currentPolicy
            guard policy.phase == policyAtEntry.phase,
                  policy.enabled == policyAtEntry.enabled,
                  policy.allowedTargets == policyAtEntry.allowedTargets,
                  policy.sendPolicy == policyAtEntry.sendPolicy,
                  policy.sendPolicy.contactAdd.allows(phone) else {
                throw AIPlannerVisionError.disabled
            }
            try policy.authorize(.openContacts, target: nil)
            try actionGate(.addContact, nil)
            _ = try freshPanel(tolerating: invite)
            try assertVisualBudget(for: .contactAdd)
        }

        actions.visualObserveContactAdd = { app, main, observedPanel, stage, candidate, axVerify in
            // B54: this step's goal and phase, named before anything here can end it.
            let (basePurpose, phase): (AIPlannerControlPurpose, AIPlannerPhase) = switch stage {
            case .searchInput: (.contactSearch, .prepare)
            case .sourceMatch: (.contactMatch, .verify)
            case .inviteConfirm: (.contactInvite, .commit)
            }
            self.beginVisualStep(.control(basePurpose), phase: phase)
            guard app.handle == originalApp.handle,
                  main.handle == originalWindow.handle,
                  observedPanel.window.handle != main.handle,
                  (!searchObserved || stage != .searchInput),
                  (stage != .sourceMatch || searchObserved && !matchObserved),
                  (stage != .inviteConfirm || matchObserved && !inviteObserved) else {
                throw AIPlannerVisionError.invalidGoal
            }
            let (_, _, panel) = try freshPanel(tolerating: observedPanel.inviteWindow)
            guard panel.window.handle == observedPanel.window.handle,
                  panel.searchField.handle == observedPanel.searchField.handle,
                  let freshFrame = try panel.window.frame() else {
                throw AIPlannerVisionError.staleView
            }
            if panelHandle == nil {
                panelHandle = panel.window.handle
                panelFrame = freshFrame
                searchHandle = panel.searchField.handle
            }
            try gate(tolerating: observedPanel.inviteWindow)
            let evidence: AIPlannerEvidence
            let action: AIPlannerStep
            switch stage {
            case .searchInput:
                evidence = .inputReady; action = .writeText
                guard candidate.handle == panel.searchField.handle,
                      try candidate.valueString() == "" else { throw AIPlannerVisionError.staleView }
            case .sourceMatch:
                evidence = .postconditionPresent; action = .press
            case .inviteConfirm:
                evidence = .pendingConfirmation; action = .press
            }
            let (_, freshMain, freshOwned) = try freshPanel(tolerating: observedPanel.inviteWindow)
            // The separate 发送验证申请 window the action saw appear after its match press.
            func freshInviteWindow() throws -> AXElement? {
                guard stage == .inviteConfirm, let invite = observedPanel.inviteWindow else { return nil }
                guard let window = try freshWindows().2.first(where: { $0.handle == invite }),
                      AddCustomerPanel.isVerificationWindow(window) else { throw AIPlannerVisionError.staleView }
                return window
            }
            let captureWindow: AXElement
            if freshOwned.window.descendants(maxDepth: 12, maxNodes: 4000).contains(where: { $0.handle == candidate.handle }) {
                captureWindow = freshOwned.window
            } else if let invite = try freshInviteWindow(),
                      invite.descendants(maxDepth: 12, maxNodes: 4000).contains(where: { $0.handle == candidate.handle }) {
                captureWindow = invite
            } else if stage == .inviteConfirm,
                      freshMain.descendants(maxDepth: 14, maxNodes: 6000).contains(where: { $0.handle == candidate.handle }) {
                captureWindow = freshMain
            } else {
                throw AIPlannerVisionError.staleView
            }
            // B54: an invite in this command's own 发送验证申请 window gets that window's goal and prompt.
            let purpose = stage == .inviteConfirm && captureWindow.handle == observedPanel.inviteWindow
                ? AIPlannerControlPurpose.contactSendVerification : basePurpose
            if purpose != basePurpose { self.beginVisualStep(.control(purpose), phase: phase) }
            let capture: AIPlannerObservation.Capture = { pid, frame in
                guard let (app, main, panel) = try? freshPanel(tolerating: observedPanel.inviteWindow) else { return nil }
                if captureWindow.handle == observedPanel.inviteWindow {
                    // Its own frame and its own number, proved new at the match press: nothing else
                    // is in the image, and without that number nothing is taken.
                    guard let windowID = observedPanel.inviteWindowID,
                          let invite = try? freshInviteWindow(), invite.handle == captureWindow.handle,
                          (try? WeComActions(policy: self.currentPolicy)
                            .inviteConfirm(app: app, mainWindow: main, panel: panel)?.handle) == candidate.handle else {
                        return nil
                    }
                    return CommandOwnedChildCapture.capture(window: invite, pid: pid, frame: frame,
                                                            windowID: windowID, captureFrame: self.windowCapture)
                }
                if captureWindow.handle == originalWindow.handle {
                    guard stage == .inviteConfirm,
                          (try? WeComActions(policy: self.currentPolicy)
                            .inviteConfirm(app: app, mainWindow: main, panel: panel)?.handle) == candidate.handle else {
                        return nil
                    }
                    let popovers = main.descendants(maxDepth: 14, maxNodes: 6000).filter {
                        (try? $0.role()) == AXRole.popover
                    }
                    guard popovers.count == 1 else { return nil }
                    return CommandOwnedChildCapture.capture(window: main, pid: pid, frame: frame,
                        ownedOverlay: (AXRole.popover, popovers[0].handle, candidate.handle),
                        windowID: observedPanel.captureWindowID(forPanelWindow: false), captureFrame: self.windowCapture)
                }
                guard panel.window.handle == captureWindow.handle else { return nil }
                // The panel shares the main window's frame (live 2026-09-28): only the
                // window number this command proved at its press can pick it.
                return CommandOwnedChildCapture.capture(window: panel.window, pid: pid, frame: frame,
                                                        windowID: observedPanel.captureWindowID(forPanelWindow: true),
                                                        captureFrame: self.windowCapture)
            }
            let runner = self.contactAddRunnerFactory?(capture) ?? self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() },
                capture: capture)
            let result: (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings)
            do {
                result = try self.recording(runner).observeContactAdd(stage: stage, expectedSettings: settings,
                    gate: { try gate(tolerating: observedPanel.inviteWindow) }, observe: {
                        let (_, _, current) = try freshPanel(tolerating: observedPanel.inviteWindow)
                        let window: AXElement
                        if captureWindow.handle == originalWindow.handle {
                            window = try freshWindows().1
                        } else if captureWindow.handle == observedPanel.inviteWindow {
                            guard let invite = try freshInviteWindow() else { throw AIPlannerVisionError.staleView }
                            window = invite
                        } else {
                            window = current.window
                        }
                        return AIPlannerReversibleRound(window: window, goal: .control(purpose),
                                                        action: action, eligible: [candidate],
                                                        expectedTitle: nil, phase: phase,
                                                        evidence: evidence,
                                                        contactSource: stage == .sourceMatch
                                                            ? observedPanel.chosenSource.flatMap(AIPlannerContactSource.init(rawValue:))
                                                            : nil)
                    }, verify: { try axVerify() })
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("contact add visual round: \(error)", outcome: error.logName)
            }
            guard result.outcome == .verified else {
                throw self.visualEnded("contact add visual round stopped", outcome: result.outcome.logName)
            }
            settings = result.settings
            switch stage {
            case .searchInput: searchObserved = true
            case .sourceMatch: matchObserved = true
            case .inviteConfirm: inviteObserved = true
            }
        }
        actions.visualContactAddStepGate = { current in
            do {
                guard searchObserved, let settings else { throw AIPlannerVisionError.invalidGoal }
                try gate(tolerating: current.inviteWindow)
                guard try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("contact add visual gate: \(error)", outcome: error.logName)
            }
        }
    }

    /// Switches to the (allowlisted) group when needed, then writes its header title.
    public func groupRename(target rawTarget: String, name: String) throws -> [String: String] {
        try groupRename(target: rawTarget, name: name, checkpoint: {}, afterSubmit: {})
    }

    public func groupRename(target rawTarget: String, name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let (resolved, hasParsedRow) = try resolveWithRowStatus(ref, reader: r)
            try policyCheck(.renameGroup, resolved: resolved)
            try selectTargetForMutation(ref: ref, resolved: resolved, reader: r,
                                        hasParsedRow: hasParsedRow, method: .groupRename, action: .renameGroup)
            var action = actions(for: resolved)
            if desktopCommandOrigin == .external, desktopCommandMethod == .groupRename,
               visualEnabled(), visualSelect != nil {
                installGroupNameVisualObservation(on: &action, target: resolved, requestedName: name)
            }
            let out = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try withVisibleGroupNameWindow(target: resolved, actions: action) { window in
                    try action.renameGroup(to: name, window: window,
                                           hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
                }
            }
            return ["title": out.details["title"] ?? "", "renamed": out.details["renamed"] ?? "false", "requestedName": name]
        }
    }

    /// B14: adds `members` to an already-created, policy-allowed group. Checks `.addGroupMembers`
    /// immediately after resolving — before any conversation switch — so a target this policy
    /// refuses never causes the client to select it first; `messageSend` / `messageSendFile` gate
    /// their action kind the same way, before `selectConversation`, and this used to gate it after
    /// (fixed 2026-09-23, Task 6: the old order let a disallowed target's switch go through before
    /// the mutation itself was refused). Unlike `groupRename`, there is no separate
    /// `policyCheck(.selectConversation, resolved:)` on the already-active branch: `.addGroupMembers`
    /// is not `isReadOnly`, so the check just above already ran `allows(target)` unconditionally
    /// (`gateReads` only ever waives that for read-only kinds) — a second, independently-enabled
    /// `.selectConversation` check would only make an already-authorized call fail on a policy that
    /// enables `.addGroupMembers` without also enabling `.selectConversation`, for a target already
    /// proven allowed. This is belt and suspenders with the action's own internal
    /// `policy.authorize`, the same defense-in-depth `messageSendFile` uses for `.sendFile`.
    /// `latencyMs` is measured around the whole action call, since `AddMembersOutcome` only carries
    /// one internally (in `details`) on the evidence-gathering path.
    public func groupAddMembers(target rawTarget: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let (resolved, hasParsedRow) = try resolveWithRowStatus(ref, reader: r)
            try policyCheck(.addGroupMembers, resolved: resolved)
            try selectTargetForMutation(ref: ref, resolved: resolved, reader: r,
                                        hasParsedRow: hasParsedRow, method: .groupAddMembers, action: .addGroupMembers)
            let app = try rootProvider()
            let window = try WeComWindowLocator.mainWindow(from: app)
            let fresh = try WeComReader(window: window)
            let started = Date()
            var action = actions(for: resolved)
            let policyAtEntry = action.policy
            action.addMembersCommitGate = { [weak self] in
                guard let self,
                      self.desktopCommandMethod == nil || self.desktopCommandMethod == .groupAddMembers else {
                    throw AIPlannerVisionError.staleView
                }
                try self.visualCommandGate()
                let live = self.currentPolicy
                guard live.phase == policyAtEntry.phase,
                      live.enabled == policyAtEntry.enabled,
                      live.allowedTargets == policyAtEntry.allowedTargets,
                      live.sendPolicy == policyAtEntry.sendPolicy else {
                    throw AIPlannerVisionError.disabled
                }
                let current = try self.resolve(.title(resolved.title), reader: self.reader())
                guard current.title == resolved.title,
                      current.chatId == resolved.chatId,
                      current.externalUserId == resolved.externalUserId,
                      (current.type == resolved.type || current.type == .unknown || resolved.type == .unknown) else {
                    throw AIPlannerVisionError.staleView
                }
                try self.policyCheck(.addGroupMembers, resolved: current)
            }
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try action.addGroupMembers(members, target: resolved, dryRun: dryRun, app: app, window: window,
                                           reader: fresh, checkpoints: checkpoints,
                                           hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            let state: CommandStateV1
            switch outcome.state {
            case .succeeded: state = .succeeded
            case .failed: state = .failed
            case .unknown, .pending: state = .unknown
            }
            // `failed` is the one verdict with something to explain (today: `sheet-still-open`), and
            // the outcome's own evidence string is that explanation. `unknown` deliberately leaves it
            // nil: "the sheet closed and nothing confirmed it" is an absence of proof, not a failure,
            // and a `reason` on the record would read like one.
            return GroupAddMembersResult(state: state, target: resolved.title, before: outcome.before, after: outcome.after,
                                         added: outcome.added, skipped: outcome.skipped.map { SkippedMember(name: $0.name, reason: $0.reason) },
                                         dryRun: dryRun, evidence: outcome.evidence, latencyMs: latencyMs,
                                         reason: state == .failed ? outcome.evidence : nil)
        }
    }

    // MARK: Helpers

    func reader() throws -> WeComReader {
        let window = try WeComWindowLocator.mainWindow(from: try rootProvider())
        return try WeComReader(window: window)
    }

    /// Bridge + what the list row shows; header / message evidence only when
    /// the target is the active conversation.
    private func resolve(_ ref: TargetRef, reader r: WeComReader) throws -> ResolvedTarget {
        try resolveWithRowStatus(ref, reader: r).0
    }

    private func resolveWithRowStatus(_ ref: TargetRef, reader r: WeComReader) throws -> (ResolvedTarget, Bool) {
        let resolver = TargetResolver(identities: identities)
        let title = try resolver.title(for: ref)
        let row = try r.conversations().first { $0.title == title }
        let isActive = try r.activeConversationTitle() == title
        let resolved = try resolver.resolve(ref, row: row, header: isActive ? try r.activeConversationHeader() : nil,
                                            messages: isActive ? try r.messages() : [])
        return (resolved, row != nil)
    }

    private func resolveActive(reader r: WeComReader) throws -> ResolvedTarget? {
        guard let active = try r.activeConversationTitle() else { return nil }
        return try resolve(.title(active), reader: r)
    }

    /// The four target-based mutations share only their reversible conversation
    /// switch. Their policy check, file fetch and irreversible action stay in
    /// their own method. When full-window planning is enabled, the switch is
    /// visually planned even if AX already parsed the target row.
    private func selectTargetForMutation(ref: TargetRef, resolved: ResolvedTarget,
                                         reader r: WeComReader, hasParsedRow: Bool, method: RPCMethod,
                                         action: ActionKind) throws {
        guard try r.activeConversationTitle() != resolved.title else { return }
        if try shouldUseVisualConversationRounds(reader: r, title: resolved.title,
                                                 hasParsedRow: hasParsedRow, method: method) {
            try selectConversationWithVisualRounds(ref: ref, resolved: resolved,
                                                   method: method, requiredAction: action)
            let fresh = try reader()
            guard fresh.layout.activeTitle != nil,
                  try fresh.activeConversationHeader()?.title == resolved.title else {
                throw ActionError.targetMismatch(expected: resolved.title,
                                                 actual: try fresh.activeConversationTitle())
            }
            return
        }
        _ = try actions(for: resolved).selectConversation(resolved.title, reader: r)
    }

    /// Full-window permission opts explicit target switches into a visual
    /// selection and a fresh visual postcondition round. If the parser missed
    /// the title, only a read may offer all visible AX rows to the model; a
    /// mutation still needs the exact title in the row's own AX text band.
    private func shouldUseVisualConversationRounds(reader r: WeComReader, title: String,
                                                   hasParsedRow: Bool, method: RPCMethod) throws -> Bool {
        guard desktopCommandOrigin == .external, desktopCommandMethod == method,
              visualEnabled(), visualSelect != nil else { return false }
        guard [.conversationRead, .messageSend, .messageSendFile, .groupRename,
               .groupAddMembers].contains(method) else { return false }
        let scope = try Self.conversationRowScope(in: r, title: title)
        // A parsed but offscreen row is actionable through the existing AX
        // path, but has no corresponding pixels for a model choice.
        if hasParsedRow && scope.parsedVisible == nil { return false }
        if scope.exactVisible != nil { return true }
        return method == .conversationRead && !scope.visible.isEmpty && scope.visible.count <= 64
    }

    /// WeCom may expose a zero-height header row and rows outside the current
    /// viewport. A visual choice may include only AX rows represented by pixels
    /// in the verified window (5.0.10 fixture, 2026-09-26).
    private static func visibleConversationRows(in reader: WeComReader) throws -> [AXElement] {
        let viewport = reader.layout.windowFrame.intersection(reader.layout.conversationTableFrame)
        guard !viewport.isNull, viewport.width > 0, viewport.height > 0 else { return [] }
        return try reader.layout.conversationTable.children().filter { row in
            guard try row.role() == AXRole.row,
                  let frame = try row.frame(), frame.width > 0, frame.height > 0 else { return false }
            let visible = viewport.intersection(frame)
            return !visible.isNull && visible.width * visible.height >= frame.width * frame.height * 0.8
        }
    }

    /// Preserve the direct AX selector's ambiguity rules across the whole
    /// conversation table, including rows outside the currently visible pixels.
    private static func conversationRowScope(in reader: WeComReader, title: String) throws ->
        (visible: [AXElement], parsedVisible: AXElement?, exactVisible: AXElement?) {
        let parsed = try reader.conversations().filter { $0.title == title }
        if parsed.count > 1 { throw ActionError.targetAmbiguous(title, count: parsed.count) }
        let raw = try reader.layout.conversationTable.children().filter { try $0.role() == AXRole.row }
        let exact = raw.filter { WeComActions.rowTopBandContainsExactTitle($0, title: title) }
        if exact.count > 1 { throw ActionError.targetAmbiguous(title, count: exact.count) }
        if let parsedRow = parsed.first, let exactRow = exact.first,
           parsedRow.handle != exactRow.handle {
            throw ActionError.targetAmbiguous(title, count: 2)
        }
        let visible = try visibleConversationRows(in: reader)
        let parsedVisible = parsed.first.flatMap { match in visible.first { $0.handle == match.handle } }
        let exactVisible = exact.first.flatMap { match in visible.first { $0.handle == match.handle } }
        return (visible, parsedVisible, exactVisible)
    }

    private func selectConversationWithVisualRounds(ref: TargetRef, resolved: ResolvedTarget,
                                                    method: RPCMethod, requiredAction: ActionKind) throws {
        beginVisualStep(.conversationRow(title: resolved.title), phase: .locate)
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 6), maxActions: 2,
            maxDuration: min(maxVisualDuration, 40),
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            }
        )
        let target = resolved.title
        let initialPolicy = currentPolicy
        let initialReader = try reader()
        let originalWindow = (handle: initialReader.layout.window.handle,
                              pid: try initialReader.layout.window.pid(),
                              frame: initialReader.layout.windowFrame)
        guard originalWindow.pid > 0, originalWindow.frame.width > 0,
              originalWindow.frame.height > 0 else { throw AIPlannerVisionError.staleView }
        func stableReader() throws -> WeComReader {
            let fresh = try reader()
            guard fresh.layout.window.handle == originalWindow.handle,
                  try fresh.layout.window.pid() == originalWindow.pid,
                  Self.sameHistoryFrame(fresh.layout.windowFrame, originalWindow.frame) else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).run(method: method, requireVisualPostcondition: true, gate: {
                guard self.desktopCommandOrigin == .external, self.desktopCommandMethod == method,
                      self.visualEnabled(), self.visualSelect != nil else {
                    throw AIPlannerVisionError.disabled
                }
                try self.visualCommandGate()
                let livePolicy = self.currentPolicy
                guard livePolicy.phase == initialPolicy.phase,
                      livePolicy.enabled == initialPolicy.enabled,
                      livePolicy.allowedTargets == initialPolicy.allowedTargets,
                      livePolicy.sendPolicy == initialPolicy.sendPolicy else {
                    throw AIPlannerVisionError.disabled
                }
                let fresh = try self.resolve(ref, reader: stableReader())
                guard fresh.title == target, fresh.chatId == resolved.chatId,
                      fresh.externalUserId == resolved.externalUserId,
                      (fresh.type == resolved.type || fresh.type == .unknown || resolved.type == .unknown) else {
                    throw AIPlannerVisionError.staleView
                }
                try self.policyCheck(.selectConversation, resolved: fresh)
                if requiredAction != .selectConversation {
                    try self.policyCheck(requiredAction, resolved: fresh)
                }
            }, observe: {
                let fresh = try stableReader()
                let scope = try Self.conversationRowScope(in: fresh, title: target)
                let atTarget = try fresh.activeConversationTitle() == target
                let eligible: [AXElement]
                if let row = scope.exactVisible { eligible = [row] }
                else if method == .conversationRead, let row = scope.parsedVisible { eligible = [row] }
                else if method == .conversationRead,
                        !scope.visible.isEmpty, scope.visible.count <= 64 { eligible = scope.visible }
                else if atTarget, !scope.visible.isEmpty, scope.visible.count <= 64 {
                    // Verification cannot perform another AX action. The row
                    // may have moved when WeCom promoted the opened chat.
                    eligible = scope.visible
                }
                else { throw ActionError.targetNotFound(target) }
                return AIPlannerReversibleRound(window: fresh.layout.window,
                                                goal: .conversationRow(title: target),
                                                action: .selectRow, eligible: eligible,
                                                expectedTitle: atTarget ? target : nil,
                                                phase: atTarget ? .verify : .locate,
                                                evidence: atTarget ? .postconditionPresent
                                                    : (scope.exactVisible != nil ? .exactTargetRowVisible : .targetVisible))
            }, apply: { step, row in
                guard step == .selectRow else { throw AIPlannerVisionError.invalidChoice }
                let fresh = try stableReader()
                let table = fresh.layout.conversationTable
                let scope = try Self.conversationRowScope(in: fresh, title: target)
                if let exactRow = scope.exactVisible {
                    guard exactRow.handle == row.handle else { throw AIPlannerVisionError.staleView }
                } else if method == .conversationRead, let parsedRow = scope.parsedVisible {
                    guard parsedRow.handle == row.handle else { throw AIPlannerVisionError.staleView }
                } else {
                    guard method == .conversationRead, !scope.visible.isEmpty,
                          scope.visible.count <= 64,
                          scope.visible.contains(where: { $0.handle == row.handle }) else {
                        throw AIPlannerVisionError.staleView
                    }
                }
                let freshResolved = try self.resolve(ref, reader: fresh)
                guard freshResolved.title == target, freshResolved.chatId == resolved.chatId,
                      freshResolved.externalUserId == resolved.externalUserId,
                      (freshResolved.type == resolved.type || freshResolved.type == .unknown || resolved.type == .unknown),
                      self.visualEnabled() else { throw AIPlannerVisionError.staleView }
                try self.visualCommandGate()
                try self.policyCheck(.selectConversation, resolved: freshResolved)
                if requiredAction != .selectConversation {
                    try self.policyCheck(requiredAction, resolved: freshResolved)
                }
                guard try table.isSettable(AXAttribute.selectedRows) else {
                    throw ActionError.notSettable(AXAttribute.selectedRows)
                }
                guard Date().timeIntervalSince(self.visualStartedAt) < self.maxVisualDuration else {
                    throw AIPlannerVisionError.timeout
                }
                try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
            }, verify: {
                let fresh = try stableReader()
                if method != .conversationRead, fresh.layout.activeTitle == nil { return false }
                return try fresh.activeConversationHeader()?.title == target
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("conversation visual round: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified: return
        case .stopped: throw self.visualEnded("conversation visual round stopped", outcome: "stop")
        case .unverified:
            self.markVisualEnd("unverified")
            throw ActionError.targetMismatch(expected: target, actual: try reader().activeConversationTitle())
        }
    }

    private struct HistoryVisualBarSelection {
        let bar: AXElement
        let recheck: () throws -> Void
    }

    private func scrollHistoryBarWithVisualRounds(active: ResolvedTarget, reader original: WeComReader,
                                                  value: Double) throws -> HistoryVisualBarSelection {
        beginVisualStep(.historyScrollBar(destination: value == 1 ? .latest : .earliest), phase: .locate)
        guard value == 0 || value == 1,
              desktopCommandOrigin == .external, desktopCommandMethod == .messageHistory,
              visualEnabled(), visualSelect != nil else { throw AIPlannerVisionError.disabled }
        let target = active.title
        let originalWindow = original.layout.window
        let originalPID = try originalWindow.pid()
        let originalFrame = try originalWindow.frame()
        let started = Date()
        let duration = visualDuration(for: .messageHistory)
        let initialPolicy = currentPolicy
        // WeCom can prepend cached older rows after a topward AX write and
        // immediately renormalize the bar away from zero. Record only the
        // current table's AX row handles once; verification must not parse the
        // entire message table on every visual gate.
        let initialRows = value == 0 ? try original.layout.messageTable?.children() : nil
        let initialRowCount = initialRows?.count ?? 0
        let initialFirstRow = initialRows?.first?.handle
        // Pin the active header and selected row once. A history visual round
        // calls its gate repeatedly; resolving the target there reparses every
        // loaded message row on each AX read and can exhaust the 60 s budget
        // before the second (read-only) model verification finishes.
        let pinnedTitle = original.layout.activeTitle
        let selectedRow = try original.conversations().first(where: \.selected)
        let pinnedSelection: AXElement?
        if let selectedRow {
            let row = AXElement(handle: selectedRow.handle, backend: originalWindow.backend)
            if try row.isSelected() == true {
                pinnedSelection = row
            } else {
                // WeCom sometimes puts AXSelected on the row's cell instead
                // of on AXRow. Recheck the element that actually supplied the
                // parser's selected bit, rather than requiring AXRow to have it.
                pinnedSelection = try row.children().first {
                    try $0.role() == AXRole.cell && $0.isSelected() == true
                }
            }
        } else {
            pinnedSelection = nil
        }
        guard originalPID > 0, let originalFrame,
              let actionGate = actions(for: active).visualActionGate else {
            throw AIPlannerVisionError.staleView
        }
        func freshReader() throws -> WeComReader {
            let fresh = try self.reader()
            let window = fresh.layout.window
            guard window.backend === originalWindow.backend,
                  window.handle == originalWindow.handle,
                  try window.pid() == originalPID,
                  let frame = try window.frame(), Self.sameHistoryFrame(frame, originalFrame),
                  try fresh.activeConversationTitle() == target else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }
        func eligibleBars(_ fresh: WeComReader) throws -> [AXElement] {
            guard let area = fresh.layout.messageScrollArea else { throw AIPlannerVisionError.staleView }
            let settable = try area.children().filter { bar in
                try bar.role() == AXRole.scrollBar && bar.isSettable(AXAttribute.value)
            }
            return try WeComActions.messageAreaVerticalBars(in: area, settableBars: settable)
        }
        let gate: () throws -> Void = {
            guard self.desktopCommandOrigin == .external, self.desktopCommandMethod == .messageHistory,
                  self.visualEnabled(), self.visualSelect != nil else {
                throw AIPlannerVisionError.disabled
            }
            guard Date().timeIntervalSince(started) < duration else { throw AIPlannerVisionError.timeout }
            // Read-gated layouts and layouts without both a pinned header and
            // selected-row evidence retain the full resolver. The usual
            // ungated history read can use its frozen target only while both
            // pieces of AX evidence remain available between observations.
            if initialPolicy.sendPolicy.gateReads || pinnedTitle == nil || pinnedSelection == nil {
                try actionGate(.scrollHistory, target)
            } else {
                try self.visualCommandGate()
                let livePolicy = self.currentPolicy
                guard livePolicy.phase == initialPolicy.phase,
                      livePolicy.enabled == initialPolicy.enabled,
                      livePolicy.allowedTargets == initialPolicy.allowedTargets,
                      livePolicy.sendPolicy == initialPolicy.sendPolicy else {
                    throw AIPlannerVisionError.disabled
                }
                try livePolicy.authorize(.scrollHistory, resolved: active)
            }
            guard try originalWindow.pid() == originalPID,
                  let frame = try originalWindow.frame(), Self.sameHistoryFrame(frame, originalFrame) else {
                throw AIPlannerVisionError.staleView
            }
            if let pinnedTitle {
                guard let raw = try pinnedTitle.valueString() ?? pinnedTitle.title(),
                      ConversationHeader.parse(raw).title == target else {
                    throw AIPlannerVisionError.staleView
                }
                if let pinnedSelection, try pinnedSelection.isSelected() != true {
                    throw AIPlannerVisionError.staleView
                }
            } else {
                let fresh = try freshReader()
                let resolved = try self.resolve(.title(target), reader: fresh)
                guard resolved.title == active.title, resolved.chatId == active.chatId,
                      resolved.externalUserId == active.externalUserId else {
                    throw AIPlannerVisionError.staleView
                }
            }
        }
        var selected: AXElement?
        var selectedFrame: CGRect?
        var valueBeforeWrite: Double?
        var wroteTop = false
        let recheck: () throws -> Void = {
            try gate()
            guard let selected, let selectedFrame else { throw AIPlannerVisionError.staleView }
            let fresh = try freshReader()
            let matching = try eligibleBars(fresh).filter { $0.handle == selected.handle }
            guard matching.count == 1, try matching[0].pid() == originalPID,
                  let frame = try matching[0].frame(), Self.sameHistoryFrame(frame, selectedFrame) else {
                throw AIPlannerVisionError.staleView
            }
        }
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 4), maxActions: 2,
            maxDuration: duration,
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            }
        )
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).run(method: .messageHistory,
                                     requireVisualPostcondition: true,
                                     gate: gate, observe: {
                let fresh = try freshReader()
                let bars = try eligibleBars(fresh)
                guard !bars.isEmpty else { throw AIPlannerVisionError.staleView }
                return AIPlannerReversibleRound(window: fresh.layout.window,
                                                goal: .historyScrollBar(destination: value == 1 ? .latest : .earliest),
                                                action: .scroll, eligible: bars,
                                                expectedTitle: target, phase: .locate,
                                                evidence: bars.count == 1 ? .uniqueHistoryBarVisible : .targetVisible)
            }, apply: { step, bar in
                guard step == .scroll else { throw AIPlannerVisionError.invalidChoice }
                try gate()
                let fresh = try freshReader()
                let matches = try eligibleBars(fresh).filter { $0.handle == bar.handle }
                guard matches.count == 1, try matches[0].pid() == originalPID,
                      let expected = try bar.frame(), let frame = try matches[0].frame(),
                      Self.sameHistoryFrame(frame, expected) else {
                    throw AIPlannerVisionError.staleView
                }
                // Gate again at the last AX write boundary after the candidate read.
                try gate()
                guard let finalFrame = try matches[0].frame(), Self.sameHistoryFrame(finalFrame, expected),
                      try matches[0].isSettable(AXAttribute.value) else {
                    throw AIPlannerVisionError.staleView
                }
                selected = bar
                selectedFrame = expected
                valueBeforeWrite = try matches[0].value()?.doubleValue
                try matches[0].setAttribute(AXAttribute.value, to: .double(value))
                if value == 0 { wroteTop = true }
            }, verify: {
                guard selected != nil else { return false }
                try recheck()
                guard let selected, let current = try selected.value()?.doubleValue else { return false }
                if value == 1 { return current >= 0.99 }
                if current <= 0.01 { return true }
                // A changed bar value alone is insufficient: an incoming new
                // message can grow the table without loading older history.
                // Require the written bar to move toward the top, the table to
                // grow, and its first AX row to change in this same chat.
                guard wroteTop, let previous = valueBeforeWrite,
                      current < previous - 0.01,
                      let initialFirstRow else { return false }
                let fresh = try freshReader()
                guard let rows = try fresh.layout.messageTable?.children(),
                      rows.count > initialRowCount,
                      rows.first?.handle != initialFirstRow else { return false }
                return true
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("message history visual round: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified:
            guard let selected else { throw ActionError.verifyFailed("message scroll bar missing after visual round") }
            return HistoryVisualBarSelection(bar: selected, recheck: recheck)
        case .stopped:
            throw self.visualEnded("message history visual round stopped", outcome: "stop")
        case .unverified:
            self.markVisualEnd("unverified")
            throw ActionError.verifyFailed("message scroll bar did not reach the requested position")
        }
    }

    private static func sameHistoryFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private struct PickerVisualBarSelection {
        let bar: AXElement
        let recheck: () throws -> Void
    }

    /// Only the first needed contact-list scroll gets model selection and a
    /// fresh visual postcondition. Later fixed positions reuse this exact AX
    /// bar under the returned ownership/policy gate, without more uploads.
    private func scrollContactListBarWithVisualRounds(window originalWindow: AXElement,
                                                       sheet originalSheet: GroupPickerSheet,
                                                       bar originalBar: AXElement,
                                                       value: Double) throws -> PickerVisualBarSelection {
        beginVisualStep(.pickerContactsScrollBar, phase: .locate)
        guard [0.0, 0.25, 0.5, 0.75, 1.0].contains(value),
              desktopCommandOrigin == .external, desktopCommandMethod == .contactList,
              visualEnabled(), visualSelect != nil else { throw AIPlannerVisionError.disabled }
        let originalPID = try originalWindow.pid()
        let originalFrame = try originalWindow.frame()
        let originalBarFrame = try originalBar.frame()
        let duration = visualDuration(for: .contactList)
        guard originalPID > 0, let originalFrame, let originalBarFrame,
              let actionGate = actions(for: nil).visualActionGate else {
            throw AIPlannerVisionError.staleView
        }
        func freshWindow() throws -> AXElement {
            let fresh = try WeComWindowLocator.mainWindow(from: rootProvider())
            guard fresh.backend === originalWindow.backend,
                  fresh.handle == originalWindow.handle,
                  try fresh.pid() == originalPID,
                  let frame = try fresh.frame(), Self.sameHistoryFrame(frame, originalFrame) else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }
        func freshBar() throws -> AXElement {
            let window = try freshWindow()
            let sheets = try window.children().filter { try $0.role() == AXRole.sheet }
            guard sheets.count == 1, sheets[0].handle == originalSheet.sheet.handle,
                  let sheet = try GroupPickerSheet.locate(window: window),
                  sheet.titleText == "发起群聊", !sheet.isAddMembers,
                  sheet.outline.handle == originalSheet.outline.handle,
                  sheet.searchField?.handle == originalSheet.searchField?.handle,
                  sheet.selectedTable?.handle == originalSheet.selectedTable?.handle,
                  try sheet.selectedCount() == 0 else {
                throw AIPlannerVisionError.staleView
            }
            let bars = try sheet.visibleWritableContactBars()
            guard bars.count == 1, bars[0].handle == originalBar.handle,
                  try bars[0].pid() == originalPID,
                  let frame = try bars[0].frame(), Self.sameHistoryFrame(frame, originalBarFrame) else {
                throw AIPlannerVisionError.staleView
            }
            return bars[0]
        }
        let gate: () throws -> Void = {
            try self.assertVisualBudget(for: .contactList)
            try actionGate(.openGroupPicker, nil)
            _ = try freshBar()
        }
        var selected: AXElement?
        let recheck: () throws -> Void = {
            try gate()
            guard selected != nil else { throw AIPlannerVisionError.staleView }
        }
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 4), maxActions: 2,
            maxDuration: duration,
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            },
            capture: { pid, frame in
                // This command owns exactly one AX sheet and its contact bar.
                // Include that sheet in the parent-window image so the model
                // sees the same picker that supplied its AX candidate.
                WeComScreenCapture.capture(windowPID: pid, expectedFrame: frame,
                                           includeChildWindows: true)
            }
        )
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).run(method: .contactList,
                                     requireVisualPostcondition: true,
                                     gate: gate, observe: {
                let window = try freshWindow()
                let bar = try freshBar()
                return AIPlannerReversibleRound(window: window,
                                                goal: .pickerContactsScrollBar,
                                                action: .scroll, eligible: [bar],
                                                expectedTitle: nil, phase: .locate,
                                                evidence: .uniquePickerContactsBarVisible)
            }, apply: { step, bar in
                guard step == .scroll else { throw AIPlannerVisionError.invalidChoice }
                try gate()
                let fresh = try freshBar()
                guard fresh.handle == bar.handle else { throw AIPlannerVisionError.staleView }
                try gate()
                selected = fresh
                try fresh.setAttribute(AXAttribute.value, to: .double(value))
            }, verify: {
                guard selected != nil else { return false }
                try recheck()
                guard let actual = try freshBar().value()?.doubleValue else { return false }
                return abs(actual - value) <= 0.01
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("contact.list visual round: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified:
            try recheck()
            guard let selected else { throw ActionError.verifyFailed("contact.list scroll bar missing after visual round") }
            return PickerVisualBarSelection(bar: selected, recheck: recheck)
        case .stopped:
            throw self.visualEnded("contact.list visual round stopped", outcome: "stop")
        case .unverified:
            self.markVisualEnd("unverified")
            throw ActionError.verifyFailed("contact.list scroll bar did not reach the requested position")
        }
    }

    /// The only visual step in the contact-request commands is reversible
    /// AXSelectedRows on the unique, exactly labelled New Customers outline row.
    /// Card names, accept buttons and the eventual checkpoint stay outside the model.
    private func selectNewCustomersWithVisualRounds(window originalWindow: AXElement,
                                                    method: RPCMethod) throws {
        beginVisualStep(.control(.newCustomers), phase: .locate)
        guard desktopCommandOrigin == .external,
              desktopCommandMethod == method,
              [.contactRequestList, .contactRequestAccept].contains(method),
              visualEnabled(), visualSelect != nil,
              let originalFrame = try originalWindow.frame() else {
            throw AIPlannerVisionError.disabled
        }
        let originalPID = try originalWindow.pid()
        guard originalPID > 0, try originalWindow.role() == AXRole.window else {
            throw AIPlannerVisionError.staleView
        }
        let initialPolicy = currentPolicy
        let started = Date()
        let duration = method == .contactRequestList
            ? visualDuration(for: method) : min(maxVisualDuration, 24)
        func freshWindow() throws -> AXElement {
            let window = try WeComWindowLocator.mainWindow(from: rootProvider())
            guard window.backend === originalWindow.backend,
                  window.handle == originalWindow.handle,
                  try window.pid() == originalPID,
                  let frame = try window.frame(), Self.sameHistoryFrame(frame, originalFrame),
                  WeComContactsView.isShowing(window: window) else {
                throw AIPlannerVisionError.staleView
            }
            return window
        }
        func uniqueRow(in window: AXElement) throws -> (row: AXElement, outline: AXElement) {
            let matches = try WeComContactsView.exactNewCustomersOutlineRows(window: window)
            if matches.count > 1 {
                throw ActionError.targetAmbiguous(WeComContactsView.newCustomersTitle, count: matches.count)
            }
            guard let match = matches.first else {
                throw ActionError.targetNotFound(WeComContactsView.newCustomersTitle)
            }
            guard let rowFrame = try match.row.frame(), let windowFrame = try window.frame(),
                  rowFrame.width > 0, rowFrame.height > 0,
                  rowFrame.intersection(windowFrame).width >= rowFrame.width * 0.8,
                  rowFrame.intersection(windowFrame).height >= rowFrame.height * 0.8 else {
                throw AIPlannerVisionError.staleView
            }
            return match
        }
        let gate: () throws -> Void = {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == method,
                  self.visualEnabled(), self.visualSelect != nil else {
                throw AIPlannerVisionError.disabled
            }
            guard Date().timeIntervalSince(started) < duration else { throw AIPlannerVisionError.timeout }
            try self.visualCommandGate()
            let current = self.currentPolicy
            guard current.phase == initialPolicy.phase,
                  current.enabled == initialPolicy.enabled,
                  current.allowedTargets == initialPolicy.allowedTargets,
                  current.sendPolicy == initialPolicy.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            try current.authorize(.openContacts, target: nil)
            if method == .contactRequestAccept { try current.authorize(.acceptRequest, target: nil) }
            _ = try freshWindow()
        }
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 4), maxActions: 2,
            maxDuration: duration,
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            }
        )
        var observedRow: (handle: AXElementHandle, frame: CGRect)?
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).run(method: method, requireVisualPostcondition: true,
                                     gate: gate, observe: {
                let window = try freshWindow()
                let match = try uniqueRow(in: window)
                guard let frame = try match.row.frame() else { throw AIPlannerVisionError.staleView }
                observedRow = (match.row.handle, frame)
                return AIPlannerReversibleRound(window: window,
                                                goal: .control(.newCustomers),
                                                action: .selectRow, eligible: [match.row],
                                                expectedTitle: nil, phase: .locate,
                                                evidence: .exactNewCustomersRowVisible)
            }, apply: { step, chosen in
                guard step == .selectRow else { throw AIPlannerVisionError.invalidChoice }
                try gate()
                let window = try freshWindow()
                let match = try uniqueRow(in: window)
                guard let observedRow,
                      chosen.handle == observedRow.handle,
                      match.row.handle == observedRow.handle,
                      try match.row.role() == AXRole.row,
                      let frame = try match.row.frame(), Self.sameHistoryFrame(frame, observedRow.frame),
                      try match.outline.isSettable(AXAttribute.selectedRows) else {
                    throw AIPlannerVisionError.staleView
                }
                try gate() // Last pause, policy and grant check before the AX write.
                try match.outline.setAttribute(AXAttribute.selectedRows, to: .elements([match.row.handle]))
            }, verify: {
                let window = try freshWindow()
                return try WeComContactsView.newCustomersSelectionVerified(window: window)
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("new customers visual round: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified: return
        case .stopped: throw self.visualEnded("new customers visual round stopped", outcome: "stop")
        case .unverified:
            self.markVisualEnd("unverified")
            throw ActionError.verifyFailed("contacts.newCustomers selection did not settle")
        }
    }

    /// B26: only the explicit add-by-phone command may ask the model which
    /// New Customers header button opens its search window. The phone is kept
    /// out of the model context; search and invitation stay in AddContact.
    private func openAddCustomerHeaderWithVisualRounds(originalApp: AXElement,
                                                       originalWindow: AXElement,
                                                       phone: String) throws -> AddCustomerPanel {
        beginVisualStep(.control(.addContact), phase: .locate)
        guard desktopCommandOrigin == .external, desktopCommandMethod == .contactAdd,
              visualEnabled(), visualSelect != nil,
              try originalApp.role() == AXRole.application,
              try originalWindow.role() == AXRole.window,
              originalApp.backend === originalWindow.backend,
              let originalFrame = try originalWindow.frame(),
              let actionGate = actions(for: nil).visualActionGate else {
            throw AIPlannerVisionError.disabled
        }
        let originalPID = try originalApp.pid()
        guard originalPID > 0, try originalWindow.pid() == originalPID else {
            throw AIPlannerVisionError.staleView
        }
        let started = Date()
        let initialPolicy = currentPolicy
        func freshState() throws -> (app: AXElement, window: AXElement, windows: [AXElement]) {
            let app = try rootProvider()
            guard app.backend === originalApp.backend,
                  app.handle == originalApp.handle,
                  try app.role() == AXRole.application,
                  try app.pid() == originalPID else { throw AIPlannerVisionError.staleView }
            let windows = try app.elements(AXAttribute.windows)
            guard let window = windows.first(where: { $0.handle == originalWindow.handle }),
                  try window.role() == AXRole.window,
                  try window.pid() == originalPID,
                  let frame = try window.frame(), Self.sameHistoryFrame(frame, originalFrame),
                  WeComContactsView.isShowing(window: window) else {
                throw AIPlannerVisionError.staleView
            }
            return (app, window, windows)
        }
        func pristinePanel(_ state: (app: AXElement, window: AXElement, windows: [AXElement])) throws -> AddCustomerPanel? {
            guard state.windows.count == 2,
                  let other = state.windows.first(where: { $0.handle != originalWindow.handle }),
                  try other.role() == AXRole.window,
                  try other.pid() == originalPID else { return nil }
            let descendants = other.descendants(maxDepth: 12, maxNodes: 4000)
            let titles = descendants.filter {
                (try? $0.role()) == AXRole.staticText && (try? $0.valueString()) == "添加客户"
            }
            let fields = descendants.filter { (try? $0.role()) == AXRole.textField }
            let closes = descendants.filter {
                (try? $0.role()) == AXRole.button && (try? $0.subrole()) == "AXCloseButton"
            }
            guard titles.count == 1, fields.count == 1, closes.count == 1,
                  (try fields[0].valueString() ?? "").isEmpty,
                  !descendants.contains(where: { element in
                      (try? element.role()) == AXRole.button
                          && AddCustomerPanel.isInviteConfirm((try? element.title()) ?? "")
                  }) else { return nil }
            return AddCustomerPanel(window: other, searchField: fields[0], closeButton: closes[0])
        }
        let gate: () throws -> Void = {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .contactAdd,
                  self.visualEnabled(), self.visualSelect != nil,
                  Date().timeIntervalSince(started) < min(self.maxVisualDuration, 24) else {
                throw AIPlannerVisionError.disabled
            }
            try actionGate(.addContact, nil)
            let current = self.currentPolicy
            guard current.phase == initialPolicy.phase,
                  current.enabled == initialPolicy.enabled,
                  current.allowedTargets == initialPolicy.allowedTargets,
                  current.sendPolicy == initialPolicy.sendPolicy,
                  current.sendPolicy.contactAdd.allows(phone) else {
                throw AIPlannerVisionError.disabled
            }
            try current.authorize(.openContacts, target: nil)
            try current.authorize(.addContact, target: nil)
            _ = try freshState()
        }
        // A command cannot safely attribute a pre-existing second window or
        // sheet to this header press. Refuse before any screenshot or AX write.
        let initial = try freshState()
        guard initial.windows.count == 1,
              try initial.window.children().allSatisfy({ try $0.role() != AXRole.sheet }) else {
            throw AIPlannerVisionError.staleView
        }
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 4), maxActions: 2,
            maxDuration: min(maxVisualDuration, 24),
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            }
        )
        var presses = 0
        var observedFrames: [AXElementHandle: CGRect] = [:]
        // The client's window numbers just before the latest press: the panel is
        // the one same-frame window that appears after it (B49).
        var windowsBeforePress: [WeComWindowIdentity] = []
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).runAddCustomerHeader(gate: gate, observe: {
                let state = try freshState()
                guard state.windows.count == 1,
                      try state.window.children().allSatisfy({ try $0.role() != AXRole.sheet }) else {
                    throw AIPlannerVisionError.staleView
                }
                let candidates = try WeComActions.addCustomerHeaderCandidates(window: state.window)
                guard candidates.count > 1 else { throw AIPlannerVisionError.invalidCandidates }
                observedFrames = try Dictionary(uniqueKeysWithValues: candidates.map { button in
                    guard let frame = try button.frame() else { throw AIPlannerVisionError.staleView }
                    return (button.handle, frame)
                })
                return AIPlannerReversibleRound(window: state.window, goal: .control(.addContact),
                                                action: .press, eligible: candidates,
                                                expectedTitle: nil, phase: .locate,
                                                evidence: .targetVisible)
            }, apply: { step, button in
                guard step == .press else { throw AIPlannerVisionError.invalidChoice }
                try gate()
                let state = try freshState()
                guard state.windows.count == 1,
                      try state.window.children().allSatisfy({ try $0.role() != AXRole.sheet }),
                      let prior = observedFrames[button.handle] else {
                    throw AIPlannerVisionError.staleView
                }
                let matches = try WeComActions.addCustomerHeaderCandidates(window: state.window)
                    .filter { $0.handle == button.handle }
                guard matches.count == 1, try matches[0].pid() == originalPID,
                      let frame = try matches[0].frame(), Self.sameHistoryFrame(frame, prior),
                      try matches[0].role() == AXRole.button,
                      try matches[0].actions().contains(AXAction.press),
                      try matches[0].isEnabled() != false else {
                    throw AIPlannerVisionError.staleView
                }
                try gate()
                guard let final = try matches[0].frame(), Self.sameHistoryFrame(final, prior),
                      try matches[0].role() == AXRole.button else {
                    throw AIPlannerVisionError.staleView
                }
                windowsBeforePress = actions(for: nil).windowIdentities(originalPID)
                try matches[0].perform(AXAction.press)
                presses += 1
                // Wait for a genuine blank Add Customer window, a different
                // newly opened window, or a sheet before deciding the next round.
                let waiter = actions(for: nil)
                _ = try waiter.waitUntil(timeout: min(waiter.verifyTimeout, 2)) {
                    let next = try freshState()
                    if next.windows.count != 1 { return true }
                    return try next.window.children().contains { try $0.role() == AXRole.sheet }
                }
                let next = try freshState()
                if try pristinePanel(next) != nil { return }
                // Another top-level window cannot be causally tied to our
                // press: the user could have opened it concurrently. Never
                // close an unidentified WeCom window on the model's behalf.
                guard next.windows.count == 1 else { throw AIPlannerVisionError.staleView }
                let sheets = try next.window.children().filter { try $0.role() == AXRole.sheet }
                guard sheets.count <= 1 else { throw AIPlannerVisionError.staleView }
                if let sheet = sheets.first {
                    let descendants = sheet.descendants(maxDepth: 8, maxNodes: 1000)
                    let titles = descendants.filter {
                        (try? $0.role()) == AXRole.staticText && (try? $0.valueString()) == "添加客户"
                    }
                    guard titles.count == 1,
                          !descendants.contains(where: { element in
                              guard let role = try? element.role() else { return false }
                              return role == AXRole.textField || role == AXRole.textArea
                          }) else { throw AIPlannerVisionError.staleView }
                    let cancels = descendants.filter {
                        (try? $0.role()) == AXRole.button && (try? $0.title()) == "取消"
                    }
                    guard cancels.count == 1,
                          try cancels[0].actions().contains(AXAction.press),
                          try cancels[0].isEnabled() != false else {
                        throw AIPlannerVisionError.staleView
                    }
                    try cancels[0].perform(AXAction.press)
                    guard try waiter.waitUntil(timeout: min(waiter.verifyTimeout, 2), {
                        let state = try freshState()
                        guard state.windows.count == 1 else { return false }
                        return try state.window.children().allSatisfy { try $0.role() != AXRole.sheet }
                    }) else { throw AIPlannerVisionError.staleView }
                }
            }, verify: {
                guard presses > 0 else { return false }
                return try pristinePanel(freshState()) != nil
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("添加客户视觉轮次: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified:
            try gate()
            guard let panel = try pristinePanel(freshState()) else {
                throw ActionError.actionUnavailable("添加客户")
            }
            return actions(for: nil).identifyWindows(of: panel, openedFrom: originalWindow, pid: originalPID,
                                                     before: windowsBeforePress)
        case .stopped, .unverified:
            throw self.visualEnded("添加客户", outcome: outcome.logName)
        }
    }

    /// B24: only this already-authorized group method may use reversible
    /// presses to find its add-members sheet. Every round observes fresh AX
    /// buttons in the group's own right title band. Search and 确定 remain in
    /// the original action flow and never enter this runner.
    private func openAddMembersHeaderWithVisualRounds(original: WeComReader,
                                                      target: ResolvedTarget,
                                                      memberCount: Int) throws -> GroupPickerSheet {
        beginVisualStep(.control(.addGroupMembers), phase: .locate)
        guard desktopCommandOrigin == .external, desktopCommandMethod == .groupAddMembers,
              visualEnabled(), visualSelect != nil else { throw AIPlannerVisionError.disabled }
        let originalWindow = original.layout.window
        let originalPID = try originalWindow.pid()
        guard originalPID > 0, let originalFrame = try originalWindow.frame(),
              let actionGate = actions(for: target).visualActionGate else {
            throw AIPlannerVisionError.staleView
        }
        let started = Date()
        func freshReader() throws -> WeComReader {
            let fresh = try self.reader()
            let window = fresh.layout.window
            guard window.backend === originalWindow.backend,
                  window.handle == originalWindow.handle,
                  try window.pid() == originalPID,
                  let frame = try window.frame(), Self.sameHistoryFrame(frame, originalFrame),
                  try fresh.activeConversationTitle() == target.title else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }
        func rawSheetCount(_ window: AXElement) throws -> Int {
            try window.children().filter { try $0.role() == AXRole.sheet }.count
        }
        func pristineSheet(_ window: AXElement) throws -> GroupPickerSheet? {
            guard try rawSheetCount(window) == 1,
                  let sheet = try GroupPickerSheet.locate(window: window), sheet.isAddMembers,
                  sheet.selectedTable != nil, try sheet.selectedCount() == 0 else { return nil }
            return sheet
        }
        func headerCandidates(_ fresh: WeComReader) throws -> [AXElement] {
            let eligible = try WeComActions.addMembersHeaderCandidates(layout: fresh.layout)
            // An exact AX name narrows the model's choice to that one fixed
            // control; an ambiguous or changed exact name cannot authorize a
            // different header press. Unlabelled headers remain model-selected.
            let named = eligible.filter { button in
                let help = (try? button.string(AXAttribute.help)) ?? ""
                let value = (try? button.valueString()) ?? ""
                return [help, value].contains { $0 == "添加群成员" || $0 == "Add Group Members" }
            }
            guard named.count <= 1 else { throw AIPlannerVisionError.invalidCandidates }
            if let exact = named.first { return [exact] }
            guard (1...2).contains(eligible.count) else { throw AIPlannerVisionError.invalidCandidates }
            return eligible
        }
        var openedSheetHandle: AXElementHandle?
        var handedOffPristineSheet = false
        defer {
            // A model stop or failed second observation must not strand the
            // empty modal this command opened. Never cancel a replaced sheet,
            // a changed conversation, or one with any selected member.
            if !handedOffPristineSheet, let openedSheetHandle,
               let fresh = try? freshReader(),
               let sheet = try? pristineSheet(fresh.layout.window),
               sheet.sheet.handle == openedSheetHandle {
                try? actions(for: target).closeGroupPicker(sheet, window: fresh.layout.window)
            }
        }
        let gate: () throws -> Void = {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .groupAddMembers,
                  self.visualEnabled(), self.visualSelect != nil,
                  Date().timeIntervalSince(started) < min(self.maxVisualDuration, 24) else {
                throw AIPlannerVisionError.disabled
            }
            try actionGate(.addGroupMembers, target.title)
            let fresh = try freshReader()
            let current = try self.resolve(.title(target.title), reader: fresh)
            let count = WeComActions.memberCount(reader: fresh)
            // The group side panel can be occluded once the intended sheet is
            // open. An unreadable count then is acceptable only with the
            // pristine sheet itself; a changed readable count always stops.
            let countMatches = count == memberCount
                || (count == nil && (try? pristineSheet(fresh.layout.window)) != nil)
            guard current.title == target.title, current.chatId == target.chatId,
                  current.externalUserId == target.externalUserId,
                  (current.type == target.type || current.type == .unknown || target.type == .unknown),
                  countMatches else {
                throw AIPlannerVisionError.staleView
            }
            try self.policyCheck(.addGroupMembers, resolved: current)
        }
        let runner = reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
            maxRounds: min(maxVisualRounds, 4), maxActions: 2,
            maxDuration: min(maxVisualDuration, 24),
            beforeRound: { [weak self] in
                guard let self else { throw AIPlannerVisionError.disabled }
                try self.beginVisualRound()
            },
            capture: { pid, frame in
                guard let fresh = try? freshReader() else { return nil }
                if let openedSheetHandle {
                    guard let sheet = try? pristineSheet(fresh.layout.window),
                          sheet.sheet.handle == openedSheetHandle,
                          let cancel = sheet.cancelButton else { return nil }
                    return CommandOwnedChildCapture.capture(window: fresh.layout.window,
                        pid: pid, frame: frame,
                        ownedOverlay: (AXRole.sheet, openedSheetHandle, cancel.handle))
                }
                guard (try? rawSheetCount(fresh.layout.window)) == 0 else { return nil }
                return CommandOwnedChildCapture.capture(window: fresh.layout.window,
                                                       pid: pid, frame: frame)
            }
        )
        var presses = 0
        let outcome: AIPlannerReversibleOutcome
        do {
            outcome = try self.recording(runner).runAddMembersHeader(gate: gate, observe: {
                let fresh = try freshReader()
                if let openedSheetHandle {
                    guard let sheet = try pristineSheet(fresh.layout.window),
                          sheet.sheet.handle == openedSheetHandle,
                          let cancel = sheet.cancelButton,
                          try cancel.title() == "取消",
                          try cancel.actions().contains(AXAction.press),
                          (try cancel.isEnabled()) != false else {
                        throw AIPlannerVisionError.staleView
                    }
                    // This is only a visual marker for the newly opened sheet.
                    // The runner permits verify/reobserve/stop, never a second
                    // press, after AX has proved the postcondition.
                    return AIPlannerReversibleRound(window: fresh.layout.window,
                                                    goal: .control(.addGroupMembers), action: .press,
                                                    eligible: [cancel], expectedTitle: target.title,
                                                    phase: .verify, evidence: .postconditionPresent)
                }
                guard try rawSheetCount(fresh.layout.window) == 0 else {
                    throw AIPlannerVisionError.staleView
                }
                let candidates = try headerCandidates(fresh)
                return AIPlannerReversibleRound(window: fresh.layout.window,
                                                goal: .control(.addGroupMembers), action: .press,
                                                eligible: candidates, expectedTitle: target.title,
                                                phase: .locate, evidence: .targetVisible)
            }, apply: { step, button in
                guard step == .press else { throw AIPlannerVisionError.invalidChoice }
                try gate()
                let fresh = try freshReader()
                guard try rawSheetCount(fresh.layout.window) == 0 else {
                    throw AIPlannerVisionError.staleView
                }
                let matching = try headerCandidates(fresh)
                    .filter { $0.handle == button.handle }
                guard matching.count == 1, try matching[0].pid() == originalPID,
                      try matching[0].role() == AXRole.button,
                      let prior = try button.frame(), let frame = try matching[0].frame(),
                      Self.sameHistoryFrame(frame, prior),
                      try matching[0].actions().contains(AXAction.press),
                      (try matching[0].isEnabled()) != false else {
                    throw AIPlannerVisionError.staleView
                }
                // The final gate and handle/frame/role read are adjacent to AXPress.
                try gate()
                guard try rawSheetCount(fresh.layout.window) == 0,
                      let final = try matching[0].frame(), Self.sameHistoryFrame(final, prior),
                      try matching[0].role() == AXRole.button else {
                    throw AIPlannerVisionError.staleView
                }
                try matching[0].perform(AXAction.press)
                presses += 1
                let cleanup = actions(for: target)
                let ready = try cleanup.waitUntil(timeout: cleanup.addMembersTimeout) {
                    guard (try? freshReader()) != nil else { return false }
                    return (try? pristineSheet(fresh.layout.window)) != nil
                }
                if ready {
                    guard let opened = try pristineSheet(fresh.layout.window) else {
                        throw AIPlannerVisionError.staleView
                    }
                    openedSheetHandle = opened.sheet.handle
                } else {
                    // No panel: another round may choose the other permitted header button.
                    // A different, populated, or concurrently opened panel has no reliable
                    // command ownership proof. Never cancel it or press a second button.
                    _ = try freshReader()
                    if try rawSheetCount(fresh.layout.window) != 0 {
                        throw AIPlannerVisionError.staleView
                    }
                }
            }, verify: {
                guard presses > 0, let openedSheetHandle else { return false }
                let fresh = try freshReader()
                return try pristineSheet(fresh.layout.window)?.sheet.handle == openedSheetHandle
            })
        } catch let error as AIPlannerVisionError {
            throw self.visualEnded("添加群成员视觉轮次: \(error)", outcome: error.logName)
        }
        switch outcome {
        case .verified:
            try gate()
            guard let sheet = try pristineSheet(freshReader().layout.window),
                  sheet.sheet.handle == openedSheetHandle else {
                throw ActionError.actionUnavailable("添加群成员")
            }
            handedOffPristineSheet = true
            return sheet
        case .stopped, .unverified:
            throw self.visualEnded("添加群成员", outcome: outcome.logName)
        }
    }

    func actions(for resolved: ResolvedTarget?) -> WeComActions {
        var a = WeComActions(policy: currentPolicy)
        a.resolvedTarget = resolved
        configureActions(&a)
        if desktopCommandOrigin == .external, visualEnabled(), let select = visualSelect {
            let owningMethod = desktopCommandMethod
            let initialPolicy = a.policy
            a.visualActionGate = { [weak self] kind, title in
                guard let self, let owningMethod,
                      self.desktopCommandOrigin == .external,
                      self.desktopCommandMethod == owningMethod,
                      self.visualEnabled() else { throw AIPlannerVisionError.disabled }
                try self.visualCommandGate()
                let livePolicy = self.currentPolicy
                // Any policy edit during inference invalidates the earlier
                // authorization, including the contact.add caps and member rules
                // that are checked by the command before entering its visual step.
                guard livePolicy.phase == initialPolicy.phase,
                      livePolicy.enabled == initialPolicy.enabled,
                      livePolicy.allowedTargets == initialPolicy.allowedTargets,
                      livePolicy.sendPolicy == initialPolicy.sendPolicy else {
                    throw AIPlannerVisionError.disabled
                }
                if let title {
                    let fresh = try self.resolve(.title(title), reader: self.reader())
                    if let resolved {
                        guard fresh.title == resolved.title,
                              fresh.chatId == resolved.chatId,
                              fresh.externalUserId == resolved.externalUserId,
                              (fresh.type == resolved.type || fresh.type == .unknown || resolved.type == .unknown) else {
                            throw AIPlannerVisionError.staleView
                        }
                    }
                    try livePolicy.authorize(kind, resolved: fresh)
                } else {
                    try livePolicy.authorize(kind, target: nil)
                }
            }
            a.visualSelect = { [weak self] window, goal, kinds, expectedTitle, eligible, gate in
                guard let self, self.desktopCommandMethod == owningMethod else { throw AIPlannerVisionError.disabled }
                // B54: the action turns a stop or a vision error here into its own error; note where it ended.
                self.beginVisualStep(goal, phase: .choose)
                do {
                    let chosen = try select(window, goal, kinds, expectedTitle, eligible, gate)
                    if chosen == nil { self.markVisualEnd("stop") }
                    return chosen
                } catch let error as AIPlannerVisionError {
                    self.markVisualEnd(error.logName)
                    throw error
                }
            }
            if owningMethod == .messageHistory {
                a.visualScrollRounds = { [weak self] observed, value in
                    guard let self, let active = try self.resolveActive(reader: observed) else {
                        throw AIPlannerVisionError.staleView
                    }
                    let selection = try self.scrollHistoryBarWithVisualRounds(active: active, reader: observed, value: value)
                    return (bar: selection.bar, recheck: selection.recheck)
                }
            }
            if owningMethod == .contactList {
                a.visualContactListScrollRounds = { [weak self] window, sheet, bar, value in
                    guard let self else { throw AIPlannerVisionError.disabled }
                    let choice = try self.scrollContactListBarWithVisualRounds(
                        window: window, sheet: sheet, bar: bar, value: value)
                    return (bar: choice.bar, recheck: choice.recheck)
                }
            }
            if owningMethod == .contactRequestList || owningMethod == .contactRequestAccept {
                a.visualNewCustomersRounds = { [weak self] window in
                    guard let self, let method = self.desktopCommandMethod, method == owningMethod else {
                        throw AIPlannerVisionError.disabled
                    }
                    try self.selectNewCustomersWithVisualRounds(window: window, method: method)
                }
            }
            if owningMethod == .groupAddMembers, let resolved {
                a.visualOpenAddMembersRounds = { [weak self] observed, title, count in
                    guard let self, title == resolved.title else { throw AIPlannerVisionError.staleView }
                    return try self.openAddMembersHeaderWithVisualRounds(original: observed,
                                                                          target: resolved,
                                                                          memberCount: count)
                }
            }
            if let owningMethod, let resolved,
               [.messageSend, .messageSendFile].contains(owningMethod),
               !desktopCommandIsBroadcastChild {
                installComposerVisualObservation(on: &a, method: owningMethod, target: resolved)
            }
            if owningMethod == .clientNavigate {
                installNavigationVisualObservation(on: &a)
            }
            if owningMethod == .groupCreate {
                installGroupCreateVisualObservation(on: &a)
            }
        }
        return a
    }

    /// The picker and its fixed requested members remain AX-owned. The model
    /// only gets one read-only veto before Done and one after independent AX
    /// proof of a newly selected group; it cannot supply a new member or act.
    private func installGroupCreateVisualObservation(on actions: inout WeComActions) {
        let state = GroupCreateVisualState()
        let policyAtEntry = actions.policy

        func stableReader() throws -> WeComReader {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let fresh = try self.reader()
            let window = fresh.layout.window
            guard window.handle == anchor.windowHandle,
                  try window.pid() == anchor.windowPID,
                  fresh.layout.windowFrame == anchor.windowFrame else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }

        func gate() throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .groupCreate,
                  self.visualEnabled() else { throw AIPlannerVisionError.disabled }
            try self.visualCommandGate()
            let live = self.currentPolicy
            guard live.phase == policyAtEntry.phase,
                  live.enabled == policyAtEntry.enabled,
                  live.allowedTargets == policyAtEntry.allowedTargets,
                  live.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            try live.authorize(.createGroup, target: nil)
            _ = try stableReader()
            try self.assertVisualBudget(for: .groupCreate)
        }

        actions.visualObserveGroupCreate = { observed, element, stage, axVerify in
            // Only the goal's kind is recorded, so the verify step's row needs no title here.
            self.beginVisualStep(stage == .beforeCompletion ? .control(.confirm) : .conversationRow(title: ""),
                                 phase: stage == .beforeCompletion ? .prepare : .verify)
            if stage == .beforeCompletion {
                guard state.anchor == nil, !state.beforeVerified,
                      try element.role() == AXRole.button,
                      try element.title() == "完成",
                      try element.actions().contains(AXAction.press),
                      try element.pid() == observed.layout.window.pid() else {
                    throw ActionError.actionUnavailable("group.create visual picker")
                }
                state.anchor = GroupCreateVisualAnchor(
                    windowHandle: observed.layout.window.handle,
                    windowPID: try observed.layout.window.pid(),
                    windowFrame: observed.layout.windowFrame)
            } else {
                guard state.beforeVerified, !state.afterVerified,
                      try element.role() == AXRole.row,
                      try element.pid() == observed.layout.window.pid() else {
                    throw ActionError.actionUnavailable("group.create visual group")
                }
            }
            let phase: AIPlannerPhase = stage == .beforeCompletion ? .prepare : .verify
            let evidence: AIPlannerEvidence = stage == .beforeCompletion ? .pendingConfirmation : .postconditionPresent
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() },
                capture: { pid, frame in
                    if stage == .beforeCompletion {
                        guard let fresh = try? stableReader(),
                              let sheet = try? GroupPickerSheet.locate(window: fresh.layout.window),
                              sheet.titleText == "发起群聊", !sheet.isAddMembers else { return nil }
                        return CommandOwnedChildCapture.capture(window: fresh.layout.window,
                            pid: pid, frame: frame,
                            ownedOverlay: (AXRole.sheet, sheet.sheet.handle, element.handle))
                    }
                    guard let fresh = try? stableReader() else { return nil }
                    return CommandOwnedChildCapture.capture(window: fresh.layout.window,
                                                           pid: pid, frame: frame)
                })
            let result: (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings)
            do {
                result = try self.recording(runner).observeGroupCreation(
                    phase: phase, expectedSettings: state.settings,
                    gate: gate,
                    observe: {
                        let fresh = try stableReader()
                        let candidate = AXElement(handle: element.handle, backend: fresh.layout.window.backend)
                        let goal: AIPlannerGoal = stage == .beforeCompletion
                            ? .control(.confirm)
                            : .conversationRow(title: try fresh.activeConversationHeader()?.title ?? "")
                        return AIPlannerReversibleRound(
                            window: fresh.layout.window, goal: goal,
                            action: stage == .beforeCompletion ? .press : .selectRow,
                            eligible: [candidate], expectedTitle: nil,
                            phase: phase, evidence: evidence)
                    }, verify: { try axVerify() })
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("group.create visual round: \(error)", outcome: error.logName)
            }
            guard result.outcome == .verified else {
                throw self.visualEnded("group.create visual round stopped", outcome: result.outcome.logName)
            }
            state.settings = result.settings
            if stage == .beforeCompletion { state.beforeVerified = true }
            else { state.afterVerified = true }
        }
        actions.visualGroupCreateCommitGate = {
            do {
                guard state.beforeVerified, !state.afterVerified,
                      let settings = state.settings else {
                    throw AIPlannerVisionError.invalidGoal
                }
                try gate()
                guard try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("group.create visual commit: \(error)", outcome: error.logName)
            }
        }
    }

    /// The verified WeCom main window can be observed around a fixed AX
    /// Window-menu action. The menu lives outside that window and is never a
    /// model candidate. An AX-selected conversation row only anchors each
    /// passive image; the action and its changed-title proof stay deterministic.
    private func installNavigationVisualObservation(on actions: inout WeComActions) {
        let state = NavigationVisualState()
        let policyAtEntry = actions.policy

        func stableReader(title: String) throws -> (WeComReader, AXElement) {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let fresh = try self.reader()
            let window = fresh.layout.window
            guard window.handle == anchor.windowHandle,
                  try window.pid() == anchor.windowPID,
                  Self.sameHistoryFrame(fresh.layout.windowFrame, anchor.windowFrame),
                  try fresh.activeConversationTitle() == title else {
                throw AIPlannerVisionError.staleView
            }
            let selected = try fresh.conversations().filter(\.selected)
            guard selected.count == 1, selected[0].title == title else {
                throw AIPlannerVisionError.staleView
            }
            let row = AXElement(handle: selected[0].handle, backend: window.backend)
            guard try row.role() == AXRole.row,
                  try row.parent()?.handle == fresh.layout.conversationTable.handle else {
                throw AIPlannerVisionError.staleView
            }
            return (fresh, row)
        }

        func gate(title: String) throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .clientNavigate,
                  self.visualSelect != nil, self.visualScreenRecordingGranted() else {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .clientNavigate)
            try self.visualCommandGate()
            let livePolicy = self.currentPolicy
            guard livePolicy.phase == policyAtEntry.phase,
                  livePolicy.enabled == policyAtEntry.enabled,
                  livePolicy.allowedTargets == policyAtEntry.allowedTargets,
                  livePolicy.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            try livePolicy.authorize(.navigate, target: nil)
            let (fresh, _) = try stableReader(title: title)
            let window = fresh.layout.window
            guard try window.children().allSatisfy({ child in
                let role = try child.role()
                return role != AXRole.sheet && role != AXRole.popover && role != "AXDialog"
            }) else { throw AIPlannerVisionError.staleView }
            if window.backend.name == "live" {
                let app = AXApp.byPID(try window.pid(), backend: window.backend)
                try Self.verifyNavigationWindowSet(app: app, window: window,
                                                   pid: try window.pid(),
                                                   frame: fresh.layout.windowFrame)
            }
            if let settings = state.settings,
               try self.visualSettingsForCommit() != settings {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .clientNavigate)
        }

        actions.visualObserveNavigation = { stage, title in
            self.beginVisualStep(.conversationRow(title: title), phase: stage == .beforeMenu ? .prepare : .verify)
            if stage == .beforeMenu {
                guard state.anchor == nil, !state.beforeVerified,
                      !title.isEmpty else { throw AIPlannerVisionError.invalidGoal }
                let observed = try self.reader()
                let window = observed.layout.window
                let pid = try window.pid()
                guard pid > 0, observed.layout.windowFrame.width > 0,
                      observed.layout.windowFrame.height > 0,
                      try observed.activeConversationTitle() == title else {
                    throw AIPlannerVisionError.staleView
                }
                state.anchor = NavigationVisualAnchor(windowHandle: window.handle,
                    windowPID: pid, windowFrame: observed.layout.windowFrame, beforeTitle: title)
            } else {
                guard state.beforeVerified, !state.afterVerified,
                      title != state.anchor?.beforeTitle else {
                    throw AIPlannerVisionError.invalidGoal
                }
            }
            let phase: AIPlannerPhase = stage == .beforeMenu ? .prepare : .verify
            let evidence: AIPlannerEvidence = stage == .beforeMenu ? .targetVisible : .postconditionPresent
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() })
            let result: (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings)
            do {
                result = try self.recording(runner).observeNavigation(phase: phase,
                    expectedSettings: state.settings,
                    gate: { try gate(title: title) },
                    observe: {
                        let (fresh, selected) = try stableReader(title: title)
                        return AIPlannerReversibleRound(window: fresh.layout.window,
                            goal: .conversationRow(title: title), action: .selectRow,
                            eligible: [selected], expectedTitle: title,
                            phase: phase, evidence: evidence)
                    }, verify: {
                        _ = try stableReader(title: title)
                        return true
                    })
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("navigation visual round: \(error)", outcome: error.logName)
            }
            guard result.outcome == .verified else {
                throw self.visualEnded("navigation visual round stopped", outcome: result.outcome.logName)
            }
            state.settings = result.settings
            if stage == .beforeMenu { state.beforeVerified = true }
            else { state.afterVerified = true }
        }
        actions.visualNavigationPressGate = {
            guard state.beforeVerified, !state.afterVerified,
                  let anchor = state.anchor, let settings = state.settings else {
                throw ActionError.actionUnavailable("navigation visual round incomplete")
            }
            do {
                try gate(title: anchor.beforeTitle)
                guard try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("navigation visual press: \(error)", outcome: error.logName)
            }
        }
    }

    /// A tiny menu-bar AXWindow may coexist with WeCom's main chat window.
    /// It is safe only when the main window is unique by handle and every
    /// auxiliary window is disjoint. The capture layer separately enforces a
    /// unique PID/frame match before any image leaves this Mac.
    static func verifyNavigationWindowSet(app: AXElement, window: AXElement,
                                          pid: pid_t, frame: CGRect) throws {
        let windows = try app.elements(AXAttribute.windows)
        guard windows.filter({ $0.handle == window.handle }).count == 1,
              try app.element(AXAttribute.mainWindow)?.handle == window.handle else {
            throw AIPlannerVisionError.staleView
        }
        for other in windows where other.handle != window.handle {
            guard try other.role() == AXRole.window,
                  try other.pid() == pid,
                  let otherFrame = try other.frame(),
                  otherFrame.width > 0, otherFrame.height > 0,
                  !otherFrame.intersects(frame) else {
                throw AIPlannerVisionError.staleView
            }
        }
        if let focused = try app.element(AXAttribute.focusedWindow),
           focused.handle != window.handle { throw AIPlannerVisionError.staleView }
    }

    /// The model observes the already unique composer before and after the
    /// action stages fixed request data. It has no AX action in either round.
    /// All three closures share one frozen identity and the command-wide 40 s
    /// budget, including any B34 conversation-selection prefix.
    private func installComposerVisualObservation(on actions: inout WeComActions,
                                                  method: RPCMethod, target: ResolvedTarget) {
        let state = ComposerVisualState()
        let policyAtEntry = actions.policy
        let requiredAction: ActionKind = method == .messageSend ? .submit : .sendFile

        func stableReader() throws -> WeComReader {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let fresh = try self.reader()
            guard fresh.layout.window.handle == anchor.windowHandle,
                  try fresh.layout.window.pid() == anchor.windowPID,
                  Self.sameHistoryFrame(fresh.layout.windowFrame, anchor.windowFrame),
                  fresh.layout.messageTable != nil,
                  let composer = fresh.layout.composer,
                  composer.handle == anchor.composerHandle,
                  try composer.role() == AXRole.textArea,
                  try composer.isSettable(AXAttribute.value),
                  (try? composer.isEnabled()) != false,
                  let frame = try composer.frame(),
                  Self.sameHistoryFrame(frame, anchor.composerFrame),
                  try fresh.activeConversationHeader()?.title == target.title else {
                throw AIPlannerVisionError.staleView
            }
            return fresh
        }

        func gate() throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == method,
                  !self.desktopCommandIsBroadcastChild,
                  self.visualSelect != nil,
                  self.visualScreenRecordingGranted() else { throw AIPlannerVisionError.disabled }
            try self.assertVisualBudget(for: method)
            try self.visualCommandGate()
            let currentPolicy = self.currentPolicy
            guard currentPolicy.phase == policyAtEntry.phase,
                  currentPolicy.enabled == policyAtEntry.enabled,
                  currentPolicy.allowedTargets == policyAtEntry.allowedTargets,
                  currentPolicy.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            let fresh = try stableReader()
            let resolved = try self.resolve(.title(target.title), reader: fresh)
            guard resolved.title == target.title, resolved.chatId == target.chatId,
                  resolved.externalUserId == target.externalUserId,
                  (resolved.type == target.type || resolved.type == .unknown || target.type == .unknown) else {
                throw AIPlannerVisionError.staleView
            }
            try self.policyCheck(requiredAction, resolved: resolved)
            let window = fresh.layout.window
            // A sheet, dialog or second WeCom window can intercept a later
            // Return while leaving the old chat header and editor in AX.
            guard try window.children().allSatisfy({ child in
                let role = try child.role()
                return role != AXRole.sheet && role != AXRole.popover && role != "AXDialog"
            }) else { throw AIPlannerVisionError.staleView }
            if window.backend.name == "live" {
                let app = AXApp.byPID(try window.pid(), backend: window.backend)
                let windows = try app.elements(AXAttribute.windows)
                guard windows.count == 1, windows[0].handle == window.handle else {
                    throw AIPlannerVisionError.staleView
                }
                if let focused = try app.element(AXAttribute.focusedWindow),
                   focused.handle != window.handle { throw AIPlannerVisionError.staleView }
            }
            try self.assertVisualBudget(for: method)
        }

        actions.visualObserveComposer = { observed, composer, stage, axVerify in
            self.beginVisualStep(.control(.messageComposer), phase: stage == .beforeStaging ? .prepare : .verify)
            if stage == .beforeStaging {
                guard state.anchor == nil, !state.beforeVerified else { throw AIPlannerVisionError.invalidGoal }
                guard observed.layout.composer?.handle == composer.handle,
                      try composer.role() == AXRole.textArea,
                      try composer.isSettable(AXAttribute.value),
                      let frame = try composer.frame(),
                      frame.width > 0, frame.height > 0 else { throw AIPlannerVisionError.staleView }
                let window = observed.layout.window
                let pid = try window.pid()
                guard pid > 0 else { throw AIPlannerVisionError.staleView }
                state.anchor = ComposerVisualAnchor(windowHandle: window.handle, windowPID: pid,
                                                    windowFrame: observed.layout.windowFrame,
                                                    composerHandle: composer.handle, composerFrame: frame)
            } else {
                guard state.beforeVerified, !state.afterVerified else { throw AIPlannerVisionError.invalidGoal }
            }
            let phase: AIPlannerPhase = stage == .beforeStaging ? .prepare : .verify
            let evidence: AIPlannerEvidence = stage == .beforeStaging ? .inputReady : .postconditionPresent
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() })
            let result: (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings)
            do {
                result = try self.recording(runner).observeComposer(method: method, phase: phase,
                                                    expectedSettings: state.settings,
                                                    gate: gate,
                                                    observe: {
                    let fresh = try stableReader()
                    guard let current = fresh.layout.composer else { throw AIPlannerVisionError.staleView }
                    return AIPlannerReversibleRound(window: fresh.layout.window,
                                                    goal: .control(.messageComposer),
                                                    action: .writeText, eligible: [current],
                                                    expectedTitle: target.title,
                                                    phase: phase, evidence: evidence)
                }, verify: {
                    try axVerify()
                })
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("composer visual round: \(error)", outcome: error.logName)
            }
            guard result.outcome == .verified else {
                throw self.visualEnded("composer visual round stopped", outcome: result.outcome.logName)
            }
            state.settings = result.settings
            if stage == .beforeStaging { state.beforeVerified = true }
            else { state.afterVerified = true }
        }
        actions.visualComposerStagingGate = {
            do {
                guard state.beforeVerified, !state.afterVerified else { throw AIPlannerVisionError.invalidGoal }
                try gate()
                guard let settings = state.settings,
                      try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
                let composer = try stableReader().layout.composer
                let count = try composer?.attributeIfSupported(AXAttribute.numberOfCharacters)
                let characters = count?.intValue ?? count?.stringValue.flatMap(Int.init) ?? 0
                guard try composer?.valueString() == "",
                      try composer?.children().isEmpty == true,
                      characters == 0 else { throw AIPlannerVisionError.staleView }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("composer visual staging: \(error)", outcome: error.logName)
            }
        }
        actions.visualComposerCommitGate = {
            do {
                guard state.afterVerified, let settings = state.settings else {
                    throw AIPlannerVisionError.invalidGoal
                }
                try gate()
                guard try self.visualSettingsForCommit() == settings else {
                    throw AIPlannerVisionError.disabled
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("composer visual commit: \(error)", outcome: error.logName)
            }
        }
        actions.visualComposerStillCurrent = { _, composer in
            guard state.anchor?.composerHandle == composer.handle else { return false }
            return (try? stableReader()) != nil
        }
    }

    /// B37: two passive observations bracket the fixed AX group-title write.
    /// The selected old group row, editor, window and model settings remain
    /// frozen until the original checkpoint and single AXConfirm path begins.
    private func installGroupNameVisualObservation(on actions: inout WeComActions,
                                                   target: ResolvedTarget,
                                                   requestedName: String) {
        let state = GroupNameVisualState()
        let policyAtEntry = actions.policy

        // The title field is in the conversation header, above the live message
        // viewport. Do not descend into message or conversation tables on every
        // model gate: those can hold thousands of rows and make a 40 s write
        // budget unusable.
        func headerFields(window: AXElement, windowFrame: CGRect,
                          tableFrame: CGRect, viewport: CGRect) throws -> [AXElement] {
            var queue = [window]
            var head = 0
            var fields: [AXElement] = []
            while head < queue.count {
                guard head < 128 else { throw AIPlannerVisionError.staleView }
                let node = queue[head]
                head += 1
                for child in try node.children() {
                    let role = try child.role()
                    if role == AXRole.table || role == AXRole.scrollArea { continue }
                    guard let frame = try child.frame() else {
                        if role == AXRole.textField { throw AIPlannerVisionError.staleView }
                        continue
                    }
                    guard frame.maxX > tableFrame.maxX,
                          frame.minY < viewport.minY,
                          frame.maxY >= windowFrame.minY else { continue }
                    if role == AXRole.textField {
                        if try child.isSettable(AXAttribute.value) { fields.append(child) }
                    } else {
                        queue.append(child)
                    }
                }
            }
            return fields
        }

        func stableReader(allowAppliedTitle: Bool = false) throws -> (WeComReader, AXElement) {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let fresh = try self.reader()
            let window = fresh.layout.window
            guard window.handle == anchor.windowHandle,
                  try window.pid() == anchor.windowPID,
                  Self.sameHistoryFrame(fresh.layout.windowFrame, anchor.windowFrame),
                  let windowFrame = try window.frame(),
                  let tableFrame = try fresh.layout.conversationTable.frame(),
                  let viewport = fresh.layout.messageViewportFrame(),
                  let selected = try? fresh.conversations().filter(\.selected),
                  selected.count == 1,
                  (selected[0].title == target.title || (allowAppliedTitle && selected[0].title == requestedName)),
                  let header = try fresh.activeConversationHeader()?.title,
                  header == target.title || header == requestedName else {
                throw AIPlannerVisionError.staleView
            }
            let candidates = try headerFields(window: window, windowFrame: windowFrame,
                                              tableFrame: tableFrame, viewport: viewport)
            guard candidates.count == 1, candidates[0].handle == anchor.fieldHandle,
                  (try? candidates[0].isEnabled()) != false,
                  try candidates[0].pid() == anchor.windowPID,
                  let fieldFrame = try candidates[0].frame(),
                  WeComActions.isInConversationHeader(fieldFrame, windowFrame: windowFrame, viewport: viewport,
                                                      conversationList: tableFrame),
                  Self.sameHistoryFrame(fieldFrame, anchor.fieldFrame),
                  (fresh.layout.activeTitle?.handle == anchor.fieldHandle || fresh.layout.activeTitle == nil),
                  try window.children().allSatisfy({ child in
                      let role = try child.role()
                      return role != AXRole.sheet && role != AXRole.popover && role != "AXDialog"
                  }) else { throw AIPlannerVisionError.staleView }
            let app: AXElement?
            if window.backend.name == "live" {
                app = AXApp.byPID(anchor.windowPID, backend: window.backend)
            } else {
                // App-rooted fakes exercise the same window-set guard. Legacy
                // window-only fixtures have no application window collection.
                let root = try self.rootProvider()
                app = try root.role() == AXRole.application ? root : nil
            }
            if let app {
                try Self.verifyGroupNameWindowSet(app: app, window: window,
                                                  pid: anchor.windowPID, frame: windowFrame,
                                                  fieldFrame: fieldFrame,
                                                  conversationTableFrame: tableFrame,
                                                  viewportFrame: viewport)
            }
            return (fresh, candidates[0])
        }

        func checkCommand(allowAppliedTitle: Bool) throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .groupRename,
                  self.visualEnabled(), self.visualSelect != nil,
                  self.visualScreenRecordingGranted() else {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .groupRename)
            try self.visualCommandGate()
            let policy = self.currentPolicy
            guard policy.phase == policyAtEntry.phase,
                  policy.enabled == policyAtEntry.enabled,
                  policy.allowedTargets == policyAtEntry.allowedTargets,
                  policy.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            _ = try stableReader(allowAppliedTitle: allowAppliedTitle)
            try self.policyCheck(.renameGroup, resolved: target)
            try self.assertVisualBudget(for: .groupRename)
        }

        func gate() throws { try checkCommand(allowAppliedTitle: false) }

        actions.visualGroupNameAppliedGate = { preparationError in
            if let preparationError {
                if let vision = preparationError as? AIPlannerVisionError {
                    guard vision == .staleView else { return false }
                } else {
                    guard state.reconcileStaleView else { return false }
                }
            }
            guard state.beforeVerified, let settings = state.settings else {
                throw AIPlannerVisionError.invalidGoal
            }
            try checkCommand(allowAppliedTitle: true)
            guard try self.visualSettingsForCommit() == settings else {
                throw AIPlannerVisionError.disabled
            }
            return true
        }

        actions.visualObserveGroupName = { observed, field, stage, axVerify in
            state.reconcileStaleView = false
            self.beginVisualStep(.control(.groupNameField), phase: stage == .beforeStaging ? .prepare : .verify)
            if stage == .beforeStaging {
                let observedWindow = observed.layout.window
                let observedPID = try observedWindow.pid()
                let rawHeader = try observed.activeConversationHeader()?.raw
                guard state.anchor == nil, !state.beforeVerified,
                      let original = try field.valueString(),
                      original == target.title || original == rawHeader,
                      observedPID > 0, try field.pid() == observedPID,
                      try field.role() == AXRole.textField,
                      try field.isSettable(AXAttribute.value),
                      let frame = try field.frame(),
                      frame.width > 0, frame.height > 0 else {
                    throw AIPlannerVisionError.staleView
                }
                state.anchor = GroupNameVisualAnchor(windowHandle: observedWindow.handle, windowPID: observedPID,
                                                      windowFrame: observed.layout.windowFrame,
                                                      fieldHandle: field.handle, fieldFrame: frame)
                state.originalValue = original
            } else {
                guard state.beforeVerified, !state.afterVerified else {
                    throw AIPlannerVisionError.invalidGoal
                }
            }
            let phase: AIPlannerPhase = stage == .beforeStaging ? .prepare : .verify
            let evidence: AIPlannerEvidence = stage == .beforeStaging ? .inputReady : .postconditionPresent
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { try self.beginVisualRound() })
            let result: (outcome: AIPlannerReversibleOutcome, settings: CloudVisionSettings)
            do {
                result = try self.recording(runner).observeGroupNameField(
                    phase: phase, expectedSettings: state.settings, gate: gate,
                    observe: {
                        let (fresh, current) = try stableReader()
                        return AIPlannerReversibleRound(window: fresh.layout.window,
                                                        goal: .control(.groupNameField),
                                                        action: .writeText, eligible: [current],
                                                        expectedTitle: phase == .prepare ? target.title : nil,
                                                        phase: phase, evidence: evidence)
                    }, verify: { try axVerify() })
            } catch let error as AIPlannerVisionError {
                let ended = self.visualEnded("group title visual round: \(error)", outcome: error.logName)
                let last = self.lastVisualRound
                let allowedDecision = last == nil || (last?.method == .groupRename
                    && last?.goal == "groupNameField" && last?.phase == .verify
                    && ["verify", "reobserve"].contains(last?.outcome ?? ""))
                state.reconcileStaleView = stage == .afterStaging && error == .staleView && allowedDecision
                throw ended
            }
            guard result.outcome == .verified else {
                throw self.visualEnded("group title visual round stopped", outcome: result.outcome.logName)
            }
            state.settings = result.settings
            if stage == .beforeStaging { state.beforeVerified = true }
            else { state.afterVerified = true }
        }
        actions.visualGroupNameStagingGate = {
            do {
                guard state.beforeVerified, !state.afterVerified,
                      let original = state.originalValue else { throw AIPlannerVisionError.invalidGoal }
                try gate()
                guard let settings = state.settings,
                      try self.visualSettingsForCommit() == settings,
                      let (_, field) = try? stableReader(),
                      try field.valueString() == original else {
                    throw AIPlannerVisionError.staleView
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("group title visual staging: \(error)", outcome: error.logName)
            }
        }
        actions.visualGroupNameCommitGate = {
            do {
                guard state.afterVerified, let settings = state.settings else {
                    throw AIPlannerVisionError.invalidGoal
                }
                try gate()
                guard try self.visualSettingsForCommit() == settings,
                      let (_, field) = try? stableReader(),
                      try field.valueString() == requestedName else {
                    throw AIPlannerVisionError.staleView
                }
            } catch let error as AIPlannerVisionError {
                let ended = self.visualEnded("group title visual commit: \(error)", outcome: error.logName)
                state.reconcileStaleView = state.afterVerified && error == .staleView
                throw ended
            }
        }
    }

    /// B41: the visual model can veto the unique pending-card and newly opened
    /// remark-button presses, but cannot select either button or decide success.
    /// A failure after the first checkpoint stays unknown in CommandExecutor.
    private func installContactAcceptVisualObservation(on actions: inout WeComActions) {
        let state = ContactAcceptVisualState()
        let policyAtEntry = actions.policy
        let remarkLabels: Set<String> = ["设置备注名", "备注企业名称", "设置标签"]

        func freshWindow() throws -> AXElement {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let window = try WeComWindowLocator.mainWindow(from: rootProvider())
            guard window.handle == anchor.windowHandle,
                  try window.role() == AXRole.window,
                  try window.pid() == anchor.windowPID,
                  let frame = try window.frame(), Self.sameHistoryFrame(frame, anchor.windowFrame),
                  try WeComContactsView.newCustomersSelectionVerified(window: window) else {
                throw AIPlannerVisionError.staleView
            }
            if window.backend.name == "live" {
                let app = AXApp.byPID(anchor.windowPID, backend: window.backend)
                let windows = try app.elements(AXAttribute.windows)
                guard windows.count == 1, windows[0].handle == window.handle else {
                    throw AIPlannerVisionError.staleView
                }
                if let focused = try app.element(AXAttribute.focusedWindow),
                   focused.handle != window.handle { throw AIPlannerVisionError.staleView }
            }
            return window
        }

        func currentButton(_ stage: ContactAcceptVisualStage) throws -> (AXElement, AXElement) {
            guard let anchor = state.anchor else { throw AIPlannerVisionError.staleView }
            let window = try freshWindow()
            guard let table = try WeComContactsView.newCustomersTable(window: window) else {
                throw AIPlannerVisionError.staleView
            }
            let rows = try table.children().filter { try $0.role() == AXRole.row }
            let cards = try NewCustomersPage.parse(table: table)
            let matches = cards.filter { $0.name == anchor.card.name }
            guard cards.count == rows.count, matches.count == 1,
                  matches[0] == anchor.card, matches[0].status == .pending,
                  matches[0].button.handle == anchor.card.button.handle else {
                throw AIPlannerVisionError.staleView
            }
            let button: AXElement
            let expectedFrame: CGRect
            let expectedTitle: String
            switch stage {
            case .beforeAccept:
                button = matches[0].button
                expectedFrame = anchor.acceptFrame
                expectedTitle = NewCustomersPage.acceptTitle
                let oldDone = window.descendants(maxDepth: 14, maxNodes: 6000).contains {
                    (try? $0.role()) == AXRole.button && (try? $0.title()) == WeComAcceptPopover.doneTitle
                }
                guard !oldDone else { throw AIPlannerVisionError.staleView }
            case .beforeDone:
                guard let doneHandle = anchor.doneHandle, let doneFrame = anchor.doneFrame else {
                    throw AIPlannerVisionError.staleView
                }
                let popovers = window.descendants(maxDepth: 14, maxNodes: 6000).filter {
                    (try? $0.role()) == AXRole.popover
                }
                let remarkPopovers = popovers.filter { popover in
                    popover.descendants(maxDepth: 8, maxNodes: 1000).contains {
                        (try? $0.role()) == AXRole.staticText &&
                        remarkLabels.contains((try? $0.valueString()) ?? "")
                    }
                }
                let allDone = popovers.flatMap { popover in
                    popover.descendants(maxDepth: 8, maxNodes: 1000).filter {
                        (try? $0.role()) == AXRole.button &&
                        (try? $0.title()) == WeComAcceptPopover.doneTitle
                    }
                }
                guard remarkPopovers.count == 1, allDone.count == 1,
                      allDone[0].handle == doneHandle,
                      remarkPopovers[0].descendants(maxDepth: 8, maxNodes: 1000).contains(where: {
                          $0.handle == doneHandle
                      }) else { throw AIPlannerVisionError.staleView }
                button = allDone[0]
                expectedFrame = doneFrame
                expectedTitle = WeComAcceptPopover.doneTitle
            }
            guard try button.role() == AXRole.button,
                  try button.pid() == anchor.windowPID,
                  try button.title() == expectedTitle,
                  try button.actions().contains(AXAction.press),
                  (try button.isEnabled()) != false,
                  let frame = try button.frame(),
                  frame.width > 0, frame.height > 0,
                  Self.sameHistoryFrame(frame, expectedFrame),
                  frame.intersection(anchor.windowFrame).width >= frame.width * 0.8,
                  frame.intersection(anchor.windowFrame).height >= frame.height * 0.8 else {
                throw AIPlannerVisionError.staleView
            }
            return (window, button)
        }

        func gate(_ stage: ContactAcceptVisualStage) throws {
            guard self.desktopCommandOrigin == .external,
                  self.desktopCommandMethod == .contactRequestAccept,
                  self.visualEnabled(), self.visualSelect != nil,
                  self.visualScreenRecordingGranted() else {
                throw AIPlannerVisionError.disabled
            }
            try self.assertVisualBudget(for: .contactRequestAccept)
            try self.visualCommandGate()
            let policy = self.currentPolicy
            guard policy.phase == policyAtEntry.phase,
                  policy.enabled == policyAtEntry.enabled,
                  policy.allowedTargets == policyAtEntry.allowedTargets,
                  policy.sendPolicy == policyAtEntry.sendPolicy else {
                throw AIPlannerVisionError.disabled
            }
            try policy.authorize(.openContacts, target: nil)
            try policy.authorize(.acceptRequest, target: nil)
            _ = try currentButton(stage)
            try self.assertVisualBudget(for: .contactRequestAccept)
        }

        actions.visualObserveContactAccept = { app, window, card, offered, stage, axVerify in
            self.beginVisualStep(.control(stage == .beforeAccept ? .requestAcceptButton : .requestRemarkDone),
                                 phase: stage == .beforeAccept ? .prepare : .commit)
            let observedPID = try window.pid()
            if stage == .beforeAccept {
                guard state.anchor == nil, !state.acceptVerified, !state.doneVerified,
                      observedPID > 0, try app.pid() == observedPID,
                      try window.role() == AXRole.window,
                      card.status == .pending,
                      card.button.handle == offered.handle,
                      let frame = try window.frame(),
                      let buttonFrame = try offered.frame(),
                      buttonFrame.width > 0, buttonFrame.height > 0 else {
                    throw AIPlannerVisionError.staleView
                }
                state.anchor = ContactAcceptVisualAnchor(windowHandle: window.handle,
                    windowPID: observedPID, windowFrame: frame,
                    card: card, acceptFrame: buttonFrame)
            } else {
                guard state.acceptVerified, !state.doneVerified,
                      var anchor = state.anchor,
                      card == anchor.card,
                      card.button.handle == anchor.card.button.handle,
                      observedPID == anchor.windowPID,
                      let doneFrame = try offered.frame(),
                      doneFrame.width > 0, doneFrame.height > 0 else {
                    throw AIPlannerVisionError.staleView
                }
                anchor.doneHandle = offered.handle
                anchor.doneFrame = doneFrame
                state.anchor = anchor
            }
            let phase: AIPlannerPhase = stage == .beforeAccept ? .prepare : .commit
            let evidence: AIPlannerEvidence = stage == .beforeAccept ? .targetVisible : .pendingConfirmation
            let purpose: AIPlannerControlPurpose = stage == .beforeAccept ? .requestAcceptButton : .requestRemarkDone
            let runner = self.reversibleRunnerFactory?() ?? AIPlannerReversibleRunner(
                maxRounds: min(self.maxVisualRounds, 6), maxActions: 2,
                maxDuration: min(self.maxVisualDuration, 40),
                beforeRound: { [weak self] in
                    guard let self else { throw AIPlannerVisionError.disabled }
                    try self.beginVisualRound()
                },
                capture: { pid, frame in
                    if stage == .beforeDone {
                        guard let (fresh, button) = try? currentButton(stage) else { return nil }
                        let popovers = fresh.descendants(maxDepth: 14, maxNodes: 6000).filter {
                            (try? $0.role()) == AXRole.popover
                        }
                        guard popovers.count == 1 else { return nil }
                        return CommandOwnedChildCapture.capture(window: fresh, pid: pid, frame: frame,
                            ownedOverlay: (AXRole.popover, popovers[0].handle, button.handle))
                    }
                    guard let (fresh, _) = try? currentButton(stage) else { return nil }
                    return CommandOwnedChildCapture.capture(window: fresh, pid: pid, frame: frame)
                })
            do {
                let result = try self.recording(runner).observeContactAcceptControl(
                    phase: phase, expectedSettings: state.settings,
                    gate: { try gate(stage) }, observe: {
                        let (fresh, button) = try currentButton(stage)
                        return AIPlannerReversibleRound(window: fresh, goal: .control(purpose),
                                                        action: .press, eligible: [button],
                                                        expectedTitle: nil, phase: phase,
                                                        evidence: evidence)
                    }, verify: {
                        guard (try? currentButton(stage).1.handle) == offered.handle else { return false }
                        return try axVerify()
                    })
                guard result.outcome == .verified else {
                    self.markVisualEnd(result.outcome.logName)
                    throw AIPlannerVisionError.invalidChoice
                }
                state.settings = result.settings
                if stage == .beforeAccept { state.acceptVerified = true }
                else { state.doneVerified = true }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("contact accept visual round: \(error)", outcome: error.logName)
            }
        }
        actions.visualContactAcceptPressGate = { stage, offered in
            do {
                guard (stage == .beforeAccept ? state.acceptVerified : state.doneVerified),
                      let settings = state.settings else { throw AIPlannerVisionError.invalidGoal }
                try gate(stage)
                guard try self.visualSettingsForCommit() == settings,
                      try currentButton(stage).1.handle == offered.handle else {
                    throw AIPlannerVisionError.staleView
                }
            } catch let error as AIPlannerVisionError {
                throw self.visualEnded("contact accept visual press: \(error)", outcome: error.logName)
            }
        }
    }

    private func policyCheck(_ kind: ActionKind, resolved: ResolvedTarget) throws {
        do { try currentPolicy.authorize(kind, resolved: resolved) } catch let e as PolicyError { throw Self.map(e) }
    }

    /// Non-escaping closures cannot be stored in `SubmitHooks`; bridge them for the duration of the call.
    private func withoutEscaping<T>(_ a: () throws -> Void, _ b: () throws -> Void,
                                    _ body: (@escaping () throws -> Void, @escaping () throws -> Void) throws -> T) throws -> T {
        try withoutActuallyEscaping(a) { ea in
            try withoutActuallyEscaping(b) { eb in
                try body(ea, eb)
            }
        }
    }

    func mapErrors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as PolicyError { throw Self.map(e) }
        catch let e as ActionError { throw Self.map(e) }
        catch let e as WeComError { throw ControlError.clientUnavailable(e.description) }
        catch let e as AXKitError { throw ControlError.clientUnavailable(e.description) }
        catch let e as CrashInjected { throw e }
        catch let e as ControlError { throw e }
        // B54: a vision error that reaches here ended the command visually; it maps as before.
        catch let e as AIPlannerVisionError {
            markVisualEnd(e.logName)
            throw ControlError.internalError(String(describing: e))
        }
        catch { throw ControlError.internalError(String(describing: error)) }
    }

    static func map(_ e: PolicyError) -> ControlError {
        switch e {
        case .targetNotAllowed(let t): return .targetNotAllowed(t)
        case .notEnabled(let k): return .internalError("action \(k.rawValue) not enabled by policy")
        case .phaseForbids(let k): return .internalError("action \(k.rawValue) forbidden in this phase")
        case .targetRequired(let k): return .invalidParams("action \(k.rawValue) needs a target")
        }
    }

    static func map(_ e: ActionError) -> ControlError {
        switch e {
        case .targetNotFound(let t): return .targetNotFound(t)
        case .targetAmbiguous(let t, _): return .targetAmbiguous(t)
        case .targetMismatch(let expected, let actual): return .targetMismatch(expected: expected, actual: actual)
        case .localGuard(let why): return .localGuard(why)
        case .verifyFailed(let what): return .internalError(what)
        case .notSettable(let attr): return .clientUnavailable("attribute \(attr) not settable")
        case .actionUnavailable(let name): return .unsupported("action \(name) unavailable")
        case .notAGroup(let t): return .notAGroup(t)
        }
    }
}

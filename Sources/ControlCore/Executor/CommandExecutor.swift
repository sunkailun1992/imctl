import CryptoKit
import Foundation

/// Single serial executor: accept → idempotency → expiry → pause → run → persist.
/// Never retries. A crash between checkpoint and evidence leaves `running` +
/// checkpoint in the store; `recoverAfterRestart` turns those into `unknown`.
public final class CommandExecutor {
    public let store: ControlStore
    public let handler: CommandHandler
    public let now: () -> Int64
    public let crashAfterSubmit: Bool
    /// Hard cap on send attempts (per target and global); nil disables it (tests only).
    public let rateLimiter: RateLimiter?
    /// Serves the WeCom official-API methods; nil = this controller has no proxy configured (UNSUPPORTED).
    public var apiHandler: APICommandHandler?
    /// Hourly cap on accepted contact requests (policy.json.contactRequests.maxAcceptsPerHour); the daemon injects it.
    public var acceptsPerHour: () -> Int = { 20 }
    /// B12: hourly cap on successful `contact.add` (policy.json contactAdd.maxAddsPerHour).
    public var contactAddsPerHour: () -> Int = { 20 }
    /// B54 (user decision 2026-10-13): hourly cap on `contact.add` searches (`dryRun`; contactAdd.maxSearchesPerHour).
    public var contactSearchesPerHour: () -> Int = { 60 }
    /// B54: irreversible points crossed per running command.
    private let irreversible = IrreversibleCounts()
    /// B13: whether an object store (oss.json) is configured; the daemon injects it for controller.describe.
    public var ossEnabled: () -> Bool = { false }
    /// Production: `exit(70)`. Tests replace it with a throwing closure.
    public var exitHook: () throws -> Void = { exit(70) }
    /// Daemon log hook (queue waits, refused remote edits); nil = silent.
    public var log: ((String) -> Void)?
    /// The policy file on this Mac, for `policy.get` / `policy.set`; nil = UNSUPPORTED.
    public var policyEditor: PolicyEditing?
    /// The daemon's own log tail, for `controller.logs`; nil = UNSUPPORTED.
    public var logReader: ((Int) throws -> [String])?
    private let queue = DispatchQueue(label: "com.sunkailun.imctl.executor")

    public init(store: ControlStore, handler: CommandHandler, now: @escaping () -> Int64 = Clock.nowMs, crashAfterSubmit: Bool = false,
                rateLimiter: RateLimiter? = RateLimiter()) {
        self.store = store
        self.handler = handler
        self.now = now
        self.crashAfterSubmit = crashAfterSubmit
        self.rateLimiter = rateLimiter
    }

    // MARK: Public API

    /// Accepts and runs one command synchronously on the serial queue. Commands run one at a time, so a
    /// slow one (a 10 s send timeout, a 通讯录 walk) delays the next; the wait is reported as `queuedMs` on
    /// the `accepted` state event and logged when it exceeds a second (live 2026-09-15: a 7 s "stall" was
    /// exactly this, behind a failing console send).
    public func submit(method: RPCMethod, paramsJSON: String, idempotencyKey: String?,
                       origin: DesktopCommandOrigin = .external) throws -> CommandRecord {
        try submit(method: method, paramsJSON: paramsJSON, idempotencyKey: idempotencyKey,
                   origin: origin, isBroadcastChild: false)
    }

    private func submit(method: RPCMethod, paramsJSON: String, idempotencyKey: String?,
                        origin: DesktopCommandOrigin, isBroadcastChild: Bool) throws -> CommandRecord {
        // Older broadcast.confirm callers only send msgid. Derive a stable local key so MQTT
        // QoS 1 redelivery cannot press the same desktop task twice without changing their wire shape.
        let key = method == .broadcastConfirm && idempotencyKey == nil
            ? try Self.broadcastConfirmKey(paramsJSON: paramsJSON)
            : idempotencyKey
        if method == .messageBroadcast { return try broadcast(paramsJSON: paramsJSON, idempotencyKey: key, origin: origin) }
        let enqueued = now()
        return try queue.sync {
            let queued = now() - enqueued
            if queued >= 1_000 { log?("executor: \(method.rawValue) waited \(queued) ms behind the previous command") }
            return try run(method: method, paramsJSON: paramsJSON, idempotencyKey: key, queuedMs: queued,
                           origin: origin, isBroadcastChild: isBroadcastChild)
        }
    }

    /// How long a broadcast waits for the rate limiter to admit the next target before giving up on it.
    public var broadcastMaxWaitMs: Int64 = 70_000
    /// Sleeps between paced sends; replaced in tests.
    public var sleep: (Int64) -> Void = { ms in Thread.sleep(forTimeInterval: Double(ms) / 1000) }

    /// `message.broadcast`: one record for the whole run, one paced `message.send` per target (child keys
    /// `<key>#<index>`), submitted through the serial queue one at a time so other clients' commands can
    /// interleave — a 30-target broadcast must not hold the queue for two minutes. Replaying the key returns
    /// the run's record; a restart mid-run leaves it `unknown` (checkpoint), the children stay individually replayable.
    private func broadcast(paramsJSON: String, idempotencyKey: String?, origin: DesktopCommandOrigin) throws -> CommandRecord {
        guard let key = idempotencyKey else { throw ControlError.invalidParams("message.broadcast requires idempotencyKey") }
        let p = try decode(BroadcastParams.self, from: paramsJSON)
        let targets = p.targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !targets.isEmpty, targets.count <= 50 else { throw ControlError.invalidParams("message.broadcast needs 1…50 targets") }
        guard Set(targets).count == targets.count else { throw ControlError.invalidParams("message.broadcast targets must be distinct") }
        let (parent, isNew): (CommandRecord, Bool) = try queue.sync {
            if let existing = try store.command(idempotencyKey: key) { return (existing, false) }
            let record = CommandRecord(method: .messageBroadcast, paramsJSON: paramsJSON, idempotencyKey: key, nowMs: now())
            if try store.insertCommand(record) == false, let existing = try store.command(idempotencyKey: key) { return (existing, false) }
            try emitState(record)
            try store.updateCommand(id: record.id, state: .running, nowMs: now(), checkpointMs: now())
            return (try transition(record.id, to: .running), true)
        }
        guard isNew else { return parent }
        let interval = Int64(max(p.intervalMs ?? 3500, 0))
        var items: [BroadcastItem] = []
        for (i, target) in targets.enumerated() {
            if i > 0, interval > 0 { sleep(interval) }
            // wait for the limiter instead of burning attempts (attempts count against the caps)
            var waited: Int64 = 0
            while let limiter = rateLimiter, limiter.check(target: store.conversationTitle(for: target), nowMs: now()) != nil, waited < broadcastMaxWaitMs {
                sleep(1000); waited += 1000
            }
            let childParams = try encode(SendParams(target: target, text: p.text, idempotencyKey: "\(key)#\(i)"))
            let child = try submit(method: .messageSend, paramsJSON: childParams, idempotencyKey: "\(key)#\(i)",
                                   origin: origin, isBroadcastChild: true)
            let evidence = child.resultJSON.flatMap { try? JSONDecoder().decode(SendResult.self, from: Data($0.utf8)) }?.evidence
            items.append(BroadcastItem(target: target, commandId: child.id, state: child.state.rawValue, errorCode: child.errorCode, errorMessage: child.errorMessage, evidence: evidence))
            if child.state != .succeeded, p.stopOnFailure == true { break }
        }
        let succeeded = items.filter { $0.state == CommandStateV1.succeeded.rawValue }.count
        let result = BroadcastResult(total: targets.count, succeeded: succeeded, failed: items.count - succeeded, items: items)
        let uncertain = items.contains { $0.state == CommandStateV1.unknown.rawValue || $0.state == CommandStateV1.running.rawValue }
        let firstFailure = items.first { $0.state != CommandStateV1.succeeded.rawValue }
        return try queue.sync {
            if uncertain {
                return try transition(parent.id, to: .unknown, resultJSON: try encode(result), errorCode: "UNKNOWN_CHILD",
                                      errorMessage: "one or more child sends lack completion evidence; reconcile using child command ids")
            }
            if let firstFailure {
                return try transition(parent.id, to: .failed, resultJSON: try encode(result), errorCode: firstFailure.errorCode ?? "INTERNAL",
                                      errorMessage: "\(result.failed) of \(result.total) target(s) failed; first: \(firstFailure.target): \(firstFailure.errorMessage ?? firstFailure.state)")
            }
            return try transition(parent.id, to: .succeeded, resultJSON: try encode(result))
        }
    }

    /// Runs `body` on the same serial queue as the commands, so queries that read the client (message.media's
    /// history bracket) never interleave with an action in progress; no command record is made.
    public func serialized<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    /// `running` + checkpoint after a restart = we may have sent it: `unknown`, never re-run.
    @discardableResult
    public func recoverAfterRestart() throws -> [CommandRecord] {
        let stuck = try store.runningWithCheckpoint()
        for record in stuck {
            try transition(record.id, to: .unknown, errorCode: "UNKNOWN_AFTER_RESTART",
                           errorMessage: "checkpoint present but no evidence when the controller restarted")
        }
        return stuck
    }

    // MARK: Pipeline

    private func run(method: RPCMethod, paramsJSON: String, idempotencyKey: String?, queuedMs: Int64 = 0,
                     origin: DesktopCommandOrigin, isBroadcastChild: Bool) throws -> CommandRecord {
        if method.requiresIdempotencyKey, idempotencyKey == nil {
            throw ControlError.invalidParams("\(method.rawValue) requires idempotencyKey")
        }
        if let key = idempotencyKey, let existing = try store.command(idempotencyKey: key) {
            return existing
        }
        var record = CommandRecord(method: method, paramsJSON: paramsJSON, idempotencyKey: idempotencyKey, nowMs: now())
        if try store.insertCommand(record) == false, let key = idempotencyKey, let existing = try store.command(idempotencyKey: key) {
            return existing
        }
        try emitState(record, extra: queuedMs > 0 ? ["queuedMs": String(queuedMs)] : [:])

        if let params = try? decode(SendParams.self, from: paramsJSON), method == .messageSend,
           let ttl = params.ttlMs, let issued = params.issuedAtMs, issued + Int64(ttl) < now() {
            return try transition(record.id, to: .expired, errorCode: ControlError.expired.code, errorMessage: ControlError.expired.message)
        }
        if let params = try? decode(SendFileParams.self, from: paramsJSON), method == .messageSendFile,
           let ttl = params.ttlMs, let issued = params.issuedAtMs, issued + Int64(ttl) < now() {
            return try transition(record.id, to: .expired, errorCode: ControlError.expired.code, errorMessage: ControlError.expired.message)
        }
        if let params = try? decode(GroupAddMembersParams.self, from: paramsJSON), method == .groupAddMembers,
           let ttl = params.ttlMs, let issued = params.issuedAtMs, issued + Int64(ttl) < now() {
            return try transition(record.id, to: .expired, errorCode: ControlError.expired.code, errorMessage: ControlError.expired.message)
        }
        if [.messageSend, .conversationRead, .clientNavigate, .contactList, .contactRequestList, .contactRequestAccept,
            .groupCreate, .groupRename, .contactAdd, .messageSendFile, .groupAddMembers, .broadcastConfirm].contains(method) {
            let reasons = try store.pauseReasons()
            if !reasons.isEmpty {
                let err = ControlError.paused(reasons)
                return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
            }
        }

        // Below any consumer policy: attempts count, so a retry loop cannot hammer
        // the client. Keyed by conversation, not by spelling: `chatId:` and the
        // title of the same chat share one interval.
        if method == .messageSend, let limiter = rateLimiter,
           let params = try? decode(SendParams.self, from: paramsJSON),
           let why = limiter.admit(target: store.conversationTitle(for: params.target), nowMs: now()) {
            let err = ControlError.rateLimited(why)
            return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
        }
        if method == .messageSendFile, let limiter = rateLimiter,
           let params = try? decode(SendFileParams.self, from: paramsJSON),
           let why = limiter.admit(target: store.conversationTitle(for: params.target), nowMs: now()) {
            let err = ControlError.rateLimited(why)
            return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
        }
        if method == .groupAddMembers, let limiter = rateLimiter,
           let params = try? decode(GroupAddMembersParams.self, from: paramsJSON),
           let why = limiter.admit(target: store.conversationTitle(for: params.target), nowMs: now()) {
            let err = ControlError.rateLimited(why)
            return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
        }

        if method == .contactAdd {
            // Real adds and searches (dry runs) each count against their own cap; the params are decoded, so how
            // a caller spelled `dryRun` does not matter. A refused search (RATE_LIMITED) never reached the client.
            let dryRun = (try? decode(ContactAddParams.self, from: paramsJSON))?.dryRun == true
            let recent = try store.commands(method: .contactAdd, updatedSinceMs: now() - 3_600_000).filter { $0.id != record.id }
                .map { (record: $0, dryRun: (try? decode(ContactAddParams.self, from: $0.paramsJSON))?.dryRun == true) }
            if dryRun {
                let limit = contactSearchesPerHour()
                let searched = recent.filter {
                    $0.dryRun && [.succeeded, .failed, .unknown].contains($0.record.state) && $0.record.errorCode != "RATE_LIMITED"
                }.count
                if searched >= limit {
                    let err = ControlError.rateLimited("\(limit) phone searches in the last hour; limit \(limit)")
                    return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
                }
            } else {
                let limit = contactAddsPerHour()
                let attempted = recent.filter { !$0.dryRun && [.succeeded, .unknown].contains($0.record.state) }.count
                if attempted >= limit {
                    let err = ControlError.rateLimited("\(limit) contacts added in the last hour; limit \(limit)")
                    return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
                }
            }
        }
        if method == .contactRequestAccept {
            let limit = acceptsPerHour()
            let since = now() - 3_600_000
            let attempted = try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: since)
                + store.countCommands(method: .contactRequestAccept, state: .unknown, sinceMs: since)
            if attempted >= limit {
                let err = ControlError.rateLimited("\(limit) contact requests accepted in the last hour; limit \(limit)")
                return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
            }
        }

        record = try transition(record.id, to: .running)
        defer { irreversible.remove(record.id) }
        // B54: where a visual round ended this command — read inside the defer below, before the context is
        // restored (the catch blocks run after it).
        var visualEnd: CommandDiagnosis.Visual?
        do {
            let aware = handler as? any DesktopCommandOriginAware
            let previousOrigin = aware?.desktopCommandOrigin
            let previousMethod = aware?.desktopCommandMethod
            let previousBroadcastChild = aware?.desktopCommandIsBroadcastChild
            let previousVisualEnd = aware?.desktopCommandVisualEnd
            aware?.desktopCommandOrigin = origin
            aware?.desktopCommandMethod = method
            aware?.desktopCommandIsBroadcastChild = isBroadcastChild
            aware?.desktopCommandVisualEnd = nil
            defer {
                visualEnd = aware?.desktopCommandVisualEnd
                if let previousOrigin { aware?.desktopCommandOrigin = previousOrigin }
                aware?.desktopCommandMethod = previousMethod
                if let previousBroadcastChild { aware?.desktopCommandIsBroadcastChild = previousBroadcastChild }
                aware?.desktopCommandVisualEnd = previousVisualEnd
            }
            let (state, resultJSON) = try execute(method: method, record: record, paramsJSON: paramsJSON)
            // A handler-reported failure (a send without its bubble) carries its reason in the result; surface it on the record too.
            return try transition(record.id, to: state, resultJSON: resultJSON,
                                  errorMessage: state == .failed ? Self.failureReason(in: resultJSON) : nil,
                                  diagnosisJSON: state == .failed || state == .unknown
                                    ? diagnosisJSON(record.id, aware?.desktopCommandVisualEnd) : nil)
        } catch let error as ControlError {
            let diagnosis = diagnosisJSON(record.id, visualEnd)
            if try store.command(id: record.id)?.checkpointMs != nil {
                return try transition(record.id, to: .unknown, errorCode: "UNKNOWN_AFTER_CHECKPOINT",
                                      errorMessage: "desktop action may have completed but could not be verified",
                                      diagnosisJSON: diagnosis)
            }
            return try transition(record.id, to: .failed, errorCode: error.code, errorMessage: error.message,
                                  diagnosisJSON: diagnosis)
        } catch let error as CrashInjected {
            throw error
        } catch {
            let diagnosis = diagnosisJSON(record.id, visualEnd)
            if try store.command(id: record.id)?.checkpointMs != nil {
                return try transition(record.id, to: .unknown, errorCode: "UNKNOWN_AFTER_CHECKPOINT",
                                      errorMessage: "desktop action may have completed but could not be verified",
                                      diagnosisJSON: diagnosis)
            }
            return try transition(record.id, to: .failed, errorCode: "INTERNAL", errorMessage: String(describing: error),
                                  diagnosisJSON: diagnosis)
        }
    }

    private func execute(method: RPCMethod, record: CommandRecord, paramsJSON: String) throws -> (CommandStateV1, String) {
        if method.isWeComAPI {
            guard let api = apiHandler else {
                throw ControlError.unsupported("WeCom API route not configured on this controller (imctl wecom enroll)")
            }
            if method == .broadcastConfirm {
                var crossed = false
                let checkpoint: () throws -> Void = {
                    try self.crossCheckpoint(record.id)
                    crossed = true
                }
                let afterSubmit: () throws -> Void = {
                    if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() }
                }
                let result: String
                do {
                    if let checked = api as? any CheckpointedBroadcastConfirmHandler {
                        result = try checked.broadcastConfirm(paramsJSON: paramsJSON, checkpoint: checkpoint, afterSubmit: afterSubmit)
                    } else {
                        try checkpoint()
                        result = try api.handleAPI(method: method, paramsJSON: paramsJSON)
                        try afterSubmit()
                    }
                } catch let crash as CrashInjected {
                    throw crash
                } catch {
                    if crossed { return (.unknown, try encode(Self.uncertainDesktopResult)) }
                    throw error
                }
                let body = try? JSONDecoder().decode([String: String].self, from: Data(result.utf8))
                let verified = body?["verified"] == "true"
                return (verified && crossed ? .succeeded : (verified || crossed ? .unknown : .failed), result)
            }
            let result = try api.handleAPI(method: method, paramsJSON: paramsJSON)
            return (.succeeded, result)
        }
        switch method {
        case .controllerDescribe:
            var info = try handler.describe()
            info["version"] = IMCTLVersion.string
            info["protocol"] = "im-control/0.1"
            info["wecomApi"] = apiHandler == nil ? "disabled" : "enabled"
            info["oss"] = ossEnabled() ? "enabled" : "disabled"
            return (.succeeded, try encode(info))
        case .accountStatus:
            return (.succeeded, try encode(try handler.accountStatus()))
        case .conversationList:
            return (.succeeded, try encode(try handler.conversationList()))
        case .conversationRead:
            let p = try decode(ReadParams.self, from: paramsJSON)
            return (.succeeded, try encode(try handler.conversationRead(target: p.target)))
        case .clientNavigate:
            let p = try decode(NavigateParams.self, from: paramsJSON)
            return (.succeeded, try encode(try handler.clientNavigate(action: p.action)))
        case .contactList:
            let p = (try? decode(ContactListParams.self, from: paramsJSON)) ?? ContactListParams()
            return (.succeeded, try encode(try handler.contactList(limit: p.limit ?? 200, scope: p.scope ?? "customers")))
        case .contactRequestList:
            return (.succeeded, try encode(try handler.contactRequestList()))
        case .contactRequestAccept:
            let p = try decode(ContactRequestAcceptParams.self, from: paramsJSON)
            let call = try desktopMutation(record: record,
                precise: { try $0.contactRequestAccept(name: p.name, checkpoint: $1, afterSubmit: $2) },
                legacy: { try self.handler.contactRequestAccept(name: p.name) })
            guard let result = call.result else { return (.unknown, try encode(Self.uncertainDesktopResult)) }
            let accepted = result["accepted"] == "true" && result["status"] == "added"
            if accepted && call.crossed {
                var event = result
                event["by"] = p.idempotencyKey.hasPrefix("auto-") ? "policy" : "remote"
                event["commandId"] = record.id
                try store.appendEvent(kind: .contactRequestAccepted, payloadJSON: try encode(event), nowMs: now())
            }
            return (accepted && call.crossed ? .succeeded : (accepted || call.crossed ? .unknown : .failed), try encode(result))
        case .groupCreate:
            let p = try decode(GroupCreateParams.self, from: paramsJSON)
            let call = try desktopMutation(record: record,
                precise: { try $0.groupCreate(members: p.members, name: p.name, checkpoint: $1, afterSubmit: $2) },
                legacy: { try self.handler.groupCreate(members: p.members, name: p.name) })
            guard let result = call.result else { return (.unknown, try encode(Self.uncertainDesktopResult)) }
            let opened = result["opened"] == "true"
            let named = p.name == nil || (result["renamed"] == "true" && result["title"] == p.name)
            if opened && named && call.crossed {
                var event = result
                event["members"] = p.members.joined(separator: ",")
                event["commandId"] = record.id
                if let name = p.name { event["requestedName"] = name }
                try store.appendEvent(kind: .groupCreated, payloadJSON: try encode(event), nowMs: now())
            }
            let verified = opened && named
            return (verified && call.crossed ? .succeeded : (verified || call.crossed ? .unknown : .failed), try encode(result))
        case .groupRename:
            let p = try decode(GroupRenameParams.self, from: paramsJSON)
            let call = try desktopMutation(record: record,
                precise: { try $0.groupRename(target: p.target, name: p.name, checkpoint: $1, afterSubmit: $2) },
                legacy: { try self.handler.groupRename(target: p.target, name: p.name) })
            guard let result = call.result else { return (.unknown, try encode(Self.uncertainDesktopResult)) }
            let renamed = result["renamed"] == "true" && result["title"] == p.name
            return (renamed && call.crossed ? .succeeded : (renamed || call.crossed ? .unknown : .failed), try encode(result))
        case .groupAddMembers:
            let p = try decode(GroupAddMembersParams.self, from: paramsJSON)
            let members = p.members.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !members.isEmpty, members.count <= 20 else { throw ControlError.invalidParams("group.addMembers needs 1…20 members") }
            let result = try handler.groupAddMembers(
                target: p.target, members: members, dryRun: p.dryRun,
                checkpoint: { try self.crossCheckpoint(record.id) },
                afterSubmit: { if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() } }
            )
            // Only a proven successful add may announce members gained.
            // `unknown` keeps its command.state terminal event for reconciliation,
            // without a group.membersAdded event that implies confirmed membership.
            if !result.dryRun, result.state == .succeeded, !result.added.isEmpty {
                var event: [String: String] = ["commandId": record.id, "target": result.target, "added": result.added.joined(separator: ",")]
                if let before = result.before { event["before"] = String(before) }
                if let after = result.after { event["after"] = String(after) }
                try store.appendEvent(kind: .groupMembersAdded, payloadJSON: try encode(event), nowMs: now())
            }
            return (result.state, try encode(result))
        case .messageHistory:
            let p = (try? decode(HistoryParams.self, from: paramsJSON)) ?? HistoryParams()
            return (.succeeded, try encode(try handler.messageHistory(limit: p.limit ?? 50, scrollback: p.scrollback ?? false)))
        case .messageSend:
            let p = try decode(SendParams.self, from: paramsJSON)
            let result = try handler.messageSend(
                target: p.target, text: p.text,
                checkpoint: { try self.crossCheckpoint(record.id) },
                afterSubmit: { if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() } }
            )
            return (result.state, try encode(result))
        case .messageSendFile:
            let p = try decode(SendFileParams.self, from: paramsJSON)
            let source: SendFileSource
            switch (p.url, p.ossKey) {
            case (let u?, nil):
                guard let url = URL(string: u), url.host != nil else { throw ControlError.invalidParams("message.sendFile url is not an absolute URL") }
                source = .url(url)
            case (nil, let k?):
                let key = k.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.hasPrefix("/"), !key.contains("..") else { throw ControlError.invalidParams("message.sendFile ossKey must be a relative object key") }
                source = .ossKey(key)
            default:
                throw ControlError.invalidParams("message.sendFile needs exactly one of url / ossKey")
            }
            let result = try handler.messageSendFile(
                target: p.target, source: source, fileName: p.fileName,
                checkpoint: { try self.crossCheckpoint(record.id) },
                afterSubmit: { if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() } }
            )
            return (result.state, try encode(result))
        case .commandGet:
            let p = try decode(CommandRefParams.self, from: paramsJSON)
            guard let found = try lookup(p) else { throw ControlError.invalidParams("no such command") }
            return (.succeeded, try encode(found))
        case .commandCancel:
            let p = try decode(CommandRefParams.self, from: paramsJSON)
            guard let found = try lookup(p) else { throw ControlError.invalidParams("no such command") }
            // Synchronous executor: a command is either already terminal or currently this one; nothing to cancel.
            return (.succeeded, try encode(["commandId": found.id, "state": found.state.rawValue, "cancelled": "false"]))
        case .policyGet:
            guard let editor = policyEditor else { throw ControlError.unsupported("policy.get needs the daemon's policy file") }
            return (.succeeded, try encode(try editor.current()))
        case .policySet:
            guard let editor = policyEditor else { throw ControlError.unsupported("policy.set needs the daemon's policy file") }
            let p = try decode(PolicySetParams.self, from: paramsJSON)
            do {
                return (.succeeded, try encode(try editor.apply(allow: p.allow ?? [], deny: p.deny ?? [], contactRequests: p.contactRequests, gateReads: p.gateReads,
                                                                 allowHosts: p.allowHosts ?? [], denyHosts: p.denyHosts ?? [])))
            } catch let error as ControlError {
                log?("executor: policy.set refused: \(error.message)")
                throw error
            }
        case .controllerDiagnose:
            return (.succeeded, try encode(try handler.diagnose()))
        case .contactAdd:
            let p = try decode(ContactAddParams.self, from: paramsJSON)
            let source = p.source ?? "wechat"
            guard ["wechat", "wecom", "any"].contains(source) else { throw ControlError.invalidParams("contact.add source must be wechat, wecom or any") }
            guard ContactAddPolicy.isPhoneNumber(p.phone) else {
                throw ControlError.invalidParams("contact.add needs a phone number (digits with optional + - ( ) and spaces, 5–20 digits)")
            }
            let dryRun = p.dryRun ?? false
            let call = try desktopMutation(record: record,
                precise: { try $0.contactAdd(phone: p.phone, source: source, greeting: p.greeting,
                                             dryRun: dryRun, checkpoint: $1, afterSubmit: $2) },
                legacy: { try self.handler.contactAdd(phone: p.phone, source: source, greeting: p.greeting, dryRun: dryRun) },
                checkpointLegacy: !dryRun)
            guard let result = call.result else { return (.unknown, try encode(Self.uncertainDesktopResult)) }
            let status = result["status"] ?? ""
            let complete = dryRun ? ["matched", "no-match"].contains(status) : ["requested", "no-match"].contains(status)
            let canCompleteWithoutSubmit = dryRun || status == "no-match"
            return (complete && (call.crossed || canCompleteWithoutSubmit) ? .succeeded
                    : (complete || call.crossed ? .unknown : .failed), try encode(result))
        case .controllerPermissions:
            let p = (try? decode(PermissionsParams.self, from: paramsJSON)) ?? PermissionsParams()
            return (.succeeded, try encode(try handler.permissions(prompt: p.prompt ?? false, probe: p.probe ?? false)))
        case .messageBroadcast:
            throw ControlError.internalError("message.broadcast is expanded before the queue")
        case .controllerMediaCache:
            let p = (try? decode(MediaCacheParams.self, from: paramsJSON)) ?? MediaCacheParams()
            if let dir = p.dir { return (.succeeded, try encode(try handler.mediaCacheList(root: p.root, dir: dir))) }
            return (.succeeded, try encode(try handler.mediaCache(limit: min(max(p.limit ?? 50, 1), 500), refresh: p.refresh ?? false)))
        case .controllerLogs:
            guard let reader = logReader else { throw ControlError.unsupported("controller.logs needs the daemon's log file") }
            let p = (try? decode(LogsParams.self, from: paramsJSON)) ?? LogsParams()
            let lines = try reader(min(max(p.lines ?? 100, 1), 500))
            return (.succeeded, try encode(["lines": lines.joined(separator: "\n"), "count": String(lines.count)]))
        case .controllerPause:
            try store.setPause(.api, on: true, nowMs: now())
            let reasons = try store.pauseReasons()
            try store.appendEvent(kind: .controllerState, payloadJSON: try encode(["paused": reasons.map(\.rawValue)]), nowMs: now())
            return (.succeeded, try encode(["paused": reasons.map(\.rawValue)]))
        case .controllerResume:
            try store.setPause(.api, on: false, nowMs: now())
            let reasons = try store.pauseReasons()
            try store.appendEvent(kind: .controllerState, payloadJSON: try encode(["paused": reasons.map(\.rawValue)]), nowMs: now())
            return (.succeeded, try encode(["paused": reasons.map(\.rawValue)]))
        default:
            throw ControlError.internalError("method \(method.rawValue) has no executor branch")
        }
    }

    private struct DesktopMutationCall {
        let result: [String: String]?
        let crossed: Bool
    }

    private static let uncertainDesktopResult = ["reason": "desktop action may have completed but could not be verified"]

    private static func broadcastConfirmKey(paramsJSON: String) throws -> String {
        guard let data = paramsJSON.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgid = body["msgid"] as? String,
              !msgid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError.invalidParams("broadcast.confirm requires msgid")
        }
        let digest = SHA256.hash(data: Data(msgid.utf8))
        return "broadcast.confirm:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The precise handler calls `checkpoint` immediately before each irreversible AX step. Older
    /// handlers get a conservative checkpoint before the whole call. Once a checkpoint exists, a
    /// transport/AX/verification error cannot prove the action did not happen: report `unknown`.
    private func desktopMutation(
        record: CommandRecord,
        precise: (any CheckpointedDesktopCommandHandler, () throws -> Void, () throws -> Void) throws -> [String: String],
        legacy: () throws -> [String: String],
        checkpointLegacy: Bool = true
    ) throws -> DesktopMutationCall {
        var crossed = false
        let checkpoint: () throws -> Void = {
            try self.crossCheckpoint(record.id)
            crossed = true
        }
        let afterSubmit: () throws -> Void = {
            if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() }
        }
        do {
            let result: [String: String]
            if let checked = handler as? any CheckpointedDesktopCommandHandler {
                result = try precise(checked, checkpoint, afterSubmit)
            } else {
                if checkpointLegacy { try checkpoint() }
                result = try legacy()
                if crossed { try afterSubmit() }
            }
            return DesktopMutationCall(result: result, crossed: crossed)
        } catch let crash as CrashInjected {
            throw crash
        } catch let control as ControlError {
            // A prior irreversible step may already have happened even if a later step reports a
            // familiar precondition error. Once crossed, its outcome is uncertain without proof.
            if crossed { return DesktopMutationCall(result: nil, crossed: true) }
            throw control
        } catch {
            if crossed { return DesktopMutationCall(result: nil, crossed: true) }
            throw error
        }
    }

    private func lookup(_ ref: CommandRefParams) throws -> CommandRecord? {
        if let id = ref.commandId { return try store.command(id: id) }
        if let key = ref.idempotencyKey { return try store.command(idempotencyKey: key) }
        return nil
    }

    /// One more irreversible point of this command: its checkpoint goes to disk first, then it is counted.
    private func crossCheckpoint(_ id: String) throws {
        try store.updateCommand(id: id, state: .running, nowMs: now(), checkpointMs: now())
        irreversible.add(id)
    }

    /// B54: the record's diagnosis when a visual round ended the command; nil otherwise.
    private func diagnosisJSON(_ id: String, _ visual: CommandDiagnosis.Visual?) -> String? {
        guard let visual else { return nil }
        return try? encode(CommandDiagnosis(visual: visual, irreversibleSteps: irreversible.count(id)))
    }

    @discardableResult
    private func transition(_ id: String, to state: CommandStateV1, resultJSON: String? = nil, errorCode: String? = nil,
                            errorMessage: String? = nil, diagnosisJSON: String? = nil) throws -> CommandRecord {
        try store.updateCommand(id: id, state: state, nowMs: now(), resultJSON: resultJSON, errorCode: errorCode,
                                errorMessage: errorMessage, diagnosisJSON: diagnosisJSON)
        guard let record = try store.command(id: id) else { throw ControlError.internalError("command vanished") }
        try emitState(record)
        return record
    }

    private func emitState(_ record: CommandRecord, extra: [String: String] = [:]) throws {
        var payload: [String: String] = ["commandId": record.id, "state": record.state.rawValue, "method": record.method]
        payload.merge(extra) { current, _ in current }
        if let k = record.idempotencyKey { payload["idempotencyKey"] = k }
        if let c = record.errorCode { payload["errorCode"] = c }
        if let d = record.diagnosisJSON,
           let diagnosis = try? JSONDecoder().decode(CommandDiagnosis.self, from: Data(d.utf8)) {
            payload.merge(diagnosis.eventFields) { current, _ in current }
        }
        try store.appendEvent(kind: .commandState, payloadJSON: try encode(payload), nowMs: now())
    }

    /// `reason` of a handler result JSON, if any.
    static func failureReason(in json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["reason"] as? String
    }

    // MARK: JSON helpers

    func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) } catch {
            throw ControlError.invalidParams("cannot decode \(type): \(error)")
        }
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Thrown by the test-mode exit hook so a "crash" unwinds without touching the store.
public struct CrashInjected: Error {
    public init() {}
}

/// B54: irreversible points each running command crossed; a broadcast's children are counted apart.
final class IrreversibleCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ id: String) { lock.lock(); counts[id, default: 0] += 1; lock.unlock() }
    func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id] ?? 0 }
    func remove(_ id: String) { lock.lock(); counts[id] = nil; lock.unlock() }
}

import Foundation

/// IM Control Protocol v0.1 methods (JSON-RPC 2.0 envelope, platform-neutral).
public enum RPCMethod: String, Codable, CaseIterable {
    case controllerDescribe = "controller.describe"
    case accountStatus = "account.status"
    case conversationList = "conversation.list"
    case conversationRead = "conversation.read"
    case messageSend = "message.send"
    /// B13: fetch an https / OSS source into the outbox, paste it into the composer (⌘V, user-approved 2026-09-22) and send it with Return.
    case messageSendFile = "message.sendFile"
    case messageHistory = "message.history"
    case commandGet = "command.get"
    case commandCancel = "command.cancel"
    case controllerPause = "controller.pause"
    case controllerResume = "controller.resume"
    /// Deterministic client navigation through the client's own 窗口 menu (B6).
    case clientNavigate = "client.navigate"
    // Contacts route (通讯录 / the group picker sheet), B7: all UI, no platform API.
    case contactList = "contact.list"
    case contactRequestList = "contact.request.list"
    case contactRequestAccept = "contact.request.accept"
    case groupCreate = "group.create"
    case groupRename = "group.rename"
    /// B14: add members (1…20) to an already-created group through the same picker sheet as
    /// group.create; a member already in the group is skipped, not reselected.
    case groupAddMembers = "group.addMembers"
    // Daemon-level (B9): the console's policy / diagnostics / log pages over the wire.
    case policyGet = "policy.get"
    case policySet = "policy.set"
    case controllerDiagnose = "controller.diagnose"
    case controllerLogs = "controller.logs"
    /// B10: read-only inventory of the client's local media cache (pictures live outside the AX tree).
    case controllerMediaCache = "controller.mediaCache"
    /// B11: the same text to several conversations, one paced message.send per target (each its own record).
    case messageBroadcast = "message.broadcast"
    /// B11: what the daemon is allowed to do on this Mac (Accessibility, the client's container, Full Disk Access); can prompt.
    case controllerPermissions = "controller.permissions"
    /// B12: add a customer by phone number through 通讯录 › 新的客户 › 添加客户 (policy-gated allowlist of numbers).
    case contactAdd = "contact.add"
    // WeCom official-API route (through the token-injecting proxy), B5.
    case groupList = "group.list"
    case groupGet = "group.get"
    case groupJoinwayCreate = "group.joinway.create"
    case groupJoinwayGet = "group.joinway.get"
    case groupJoinwayUpdate = "group.joinway.update"
    case groupJoinwayDelete = "group.joinway.delete"
    case contactWayCreate = "contact.way.create"
    case contactWayList = "contact.way.list"
    case contactWayGet = "contact.way.get"
    case contactWayUpdate = "contact.way.update"
    case contactWayDelete = "contact.way.delete"
    case contactWelcomeSend = "contact.welcome.send"
    case contactRemarkSet = "contact.remark.set"
    case broadcastCreate = "broadcast.create"
    case broadcastConfirm = "broadcast.confirm"
    case broadcastGet = "broadcast.get"

    /// Methods that change client or platform state and therefore need an idempotency key.
    public var requiresIdempotencyKey: Bool {
        switch self {
        case .messageSend, .messageSendFile, .clientNavigate, .contactRequestAccept, .groupCreate, .groupRename, .groupAddMembers,
             .broadcastCreate, .broadcastConfirm, .messageBroadcast, .contactAdd: return true
        default: return false
        }
    }

    /// Served by the WeCom official-API handler (through the token-injecting
    /// proxy). `broadcast.confirm` is the desktop step of that same flow.
    public var isWeComAPI: Bool {
        switch self {
        case .groupList, .groupGet, .groupJoinwayCreate, .groupJoinwayGet, .groupJoinwayUpdate, .groupJoinwayDelete,
             .contactWayCreate, .contactWayList, .contactWayGet, .contactWayUpdate, .contactWayDelete,
             .contactWelcomeSend, .contactRemarkSet, .broadcastCreate, .broadcastConfirm, .broadcastGet:
            return true
        default:
            return false
        }
    }
}

public struct SendParams: Codable, Equatable {
    public var target: String
    public var text: String
    public var idempotencyKey: String
    public var ttlMs: Int?
    public var issuedAtMs: Int64?

    public init(target: String, text: String, idempotencyKey: String, ttlMs: Int? = nil, issuedAtMs: Int64? = nil) {
        self.target = target; self.text = text; self.idempotencyKey = idempotencyKey; self.ttlMs = ttlMs; self.issuedAtMs = issuedAtMs
    }
}

/// `message.sendFile`: exactly one of `url` (https, host on policy.json sendFile.allowedHosts) or `ossKey` (object in the configured bucket).
public struct SendFileParams: Codable, Equatable {
    public var target: String
    public var url: String?
    public var ossKey: String?
    public var fileName: String?
    public var idempotencyKey: String
    public var ttlMs: Int?
    public var issuedAtMs: Int64?
    public init(target: String, url: String? = nil, ossKey: String? = nil, fileName: String? = nil, idempotencyKey: String, ttlMs: Int? = nil, issuedAtMs: Int64? = nil) {
        self.target = target; self.url = url; self.ossKey = ossKey; self.fileName = fileName; self.idempotencyKey = idempotencyKey; self.ttlMs = ttlMs; self.issuedAtMs = issuedAtMs
    }
}

/// Where a file to send comes from, after the executor validated the params.
public enum SendFileSource: Equatable {
    case url(URL)
    case ossKey(String)
}

/// `message.sendFile` result: the send outcome plus what was fetched (name as pasted, bytes, sniffed type, image | video | file).
public struct SendFileResult: Codable, Equatable {
    public var state: CommandStateV1
    public var evidence: String?
    public var reason: String?
    public var latencyMs: Int?
    public var fileName: String
    public var bytes: Int64
    public var contentType: String
    public var kind: String
    public init(state: CommandStateV1, evidence: String? = nil, reason: String? = nil, latencyMs: Int? = nil, fileName: String, bytes: Int64, contentType: String, kind: String) {
        self.state = state; self.evidence = evidence; self.reason = reason; self.latencyMs = latencyMs
        self.fileName = fileName; self.bytes = bytes; self.contentType = contentType; self.kind = kind
    }
}

/// Relative navigation the client offers under its 窗口 menu. Menu-driven on
/// purpose: the items are the client's own commands, so no synthetic input.
public enum NavigateAction: String, Codable, CaseIterable {
    case nextConversation
    case previousConversation
    case nextUnreadConversation
}

public struct NavigateParams: Codable, Equatable {
    public var action: NavigateAction
    public var idempotencyKey: String
    public init(action: NavigateAction, idempotencyKey: String) { self.action = action; self.idempotencyKey = idempotencyKey }
}

public struct ContactListParams: Codable, Equatable {
    public var limit: Int?
    /// `customers` (default: 我的客户 only) or `all` (every picker row, with its `section`).
    public var scope: String?
    public init(limit: Int? = nil, scope: String? = nil) { self.limit = limit; self.scope = scope }
}

/// `policy.set`: titles to allow / deny and, when present, the whole `contactRequests` block. B12's
/// `allowPhones` / `denyPhones` went with the phone list (2026-10-13): sent anyway, the decoder ignores them.
public struct PolicySetParams: Codable, Equatable {
    public var allow: [String]?
    public var deny: [String]?
    public var contactRequests: ContactRequestPolicy?
    public var gateReads: Bool?
    /// B13: hosts `message.sendFile` may fetch a `url` source from / may no longer (exact or `.`-suffix match).
    public var allowHosts: [String]?
    public var denyHosts: [String]?
    public init(allow: [String]? = nil, deny: [String]? = nil, contactRequests: ContactRequestPolicy? = nil, gateReads: Bool? = nil,
                allowHosts: [String]? = nil, denyHosts: [String]? = nil) {
        self.allow = allow; self.deny = deny; self.contactRequests = contactRequests; self.gateReads = gateReads
        self.allowHosts = allowHosts; self.denyHosts = denyHosts
    }
}

/// `controller.logs`: how many trailing lines of the daemon log (default 100, max 500).
/// `message.broadcast`: `targets` in order, one send each; `intervalMs` paces the sends (the rate limiter still counts them).
public struct BroadcastParams: Codable, Equatable {
    public var targets: [String]
    public var text: String
    public var idempotencyKey: String
    public var intervalMs: Int?
    public var stopOnFailure: Bool?
    public init(targets: [String], text: String, idempotencyKey: String, intervalMs: Int? = nil, stopOnFailure: Bool? = nil) {
        self.targets = targets; self.text = text; self.idempotencyKey = idempotencyKey; self.intervalMs = intervalMs; self.stopOnFailure = stopOnFailure
    }
}

/// One target's outcome inside a broadcast result.
public struct BroadcastItem: Codable, Equatable {
    public var target: String
    public var commandId: String
    public var state: String
    public var errorCode: String?
    public var errorMessage: String?
    public var evidence: String?
    public init(target: String, commandId: String, state: String, errorCode: String? = nil, errorMessage: String? = nil, evidence: String? = nil) {
        self.target = target; self.commandId = commandId; self.state = state; self.errorCode = errorCode; self.errorMessage = errorMessage; self.evidence = evidence
    }
}

public struct BroadcastResult: Codable, Equatable {
    public var total: Int
    public var succeeded: Int
    public var failed: Int
    public var items: [BroadcastItem]
    public init(total: Int, succeeded: Int, failed: Int, items: [BroadcastItem]) { self.total = total; self.succeeded = succeeded; self.failed = failed; self.items = items }
}

/// `controller.permissions{prompt?}`: `prompt` asks macOS for Accessibility, Screen Recording,
/// and the client's container. The response includes `screenRecording: granted|denied`.
public struct PermissionsParams: Codable, Equatable {
    public var prompt: Bool?
    /// Probe the client's container without the Accessibility prompt (the setup poll while a dialog is up).
    public var probe: Bool?
    public init(prompt: Bool? = nil, probe: Bool? = nil) { self.prompt = prompt; self.probe = probe }
}

/// `contact.add`: `source` picks the match (wechat = 微信 contact, wecom = 企业微信 user, any = first); `dryRun` only lists matches.
public struct ContactAddParams: Codable, Equatable {
    public var phone: String
    public var source: String?
    public var greeting: String?
    public var dryRun: Bool?
    public var idempotencyKey: String
    public init(phone: String, source: String? = nil, greeting: String? = nil, dryRun: Bool? = nil, idempotencyKey: String) {
        self.phone = phone; self.source = source; self.greeting = greeting; self.dryRun = dryRun; self.idempotencyKey = idempotencyKey
    }
}

public struct LogsParams: Codable, Equatable {
    public var lines: Int?
    public init(lines: Int? = nil) { self.lines = lines }
}

public struct MediaCacheParams: Codable, Equatable {
    public var limit: Int?
    public var refresh: Bool?
    /// Diagnostic: list one directory (relative to `root`, default the first root) instead of scanning.
    public var dir: String?
    public var root: String?
    public init(limit: Int? = nil, refresh: Bool? = nil, dir: String? = nil, root: String? = nil) { self.limit = limit; self.refresh = refresh; self.dir = dir; self.root = root }
}

public struct ContactRequestAcceptParams: Codable, Equatable {
    public var name: String
    public var idempotencyKey: String
    public init(name: String, idempotencyKey: String) { self.name = name; self.idempotencyKey = idempotencyKey }
}

public struct GroupCreateParams: Codable, Equatable {
    public var members: [String]
    public var name: String?
    public var idempotencyKey: String
    public init(members: [String], name: String? = nil, idempotencyKey: String) {
        self.members = members; self.name = name; self.idempotencyKey = idempotencyKey
    }
}

/// `group.rename`: `target` in wire form (an allowlisted group), `name` the new title.
public struct GroupRenameParams: Codable, Equatable {
    public var target: String
    public var name: String
    public var idempotencyKey: String
    public init(target: String, name: String, idempotencyKey: String) {
        self.target = target; self.name = name; self.idempotencyKey = idempotencyKey
    }
}

/// `group.addMembers`: add `members` (1…20, names as the picker shows them) to the already-created
/// group `target`. A member already in the group is skipped rather than reselected, so replaying with
/// a superset of names is naturally idempotent. `dryRun` selects then cancels — nothing is submitted.
public struct GroupAddMembersParams: Codable, Equatable {
    public var target: String
    public var members: [String]
    public var dryRun: Bool
    public var idempotencyKey: String
    public var ttlMs: Int?
    public var issuedAtMs: Int64?

    public init(target: String, members: [String], dryRun: Bool = false, idempotencyKey: String, ttlMs: Int? = nil, issuedAtMs: Int64? = nil) {
        self.target = target; self.members = members; self.dryRun = dryRun; self.idempotencyKey = idempotencyKey
        self.ttlMs = ttlMs; self.issuedAtMs = issuedAtMs
    }

    enum CodingKeys: String, CodingKey { case target, members, dryRun, idempotencyKey, ttlMs, issuedAtMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        members = try c.decode([String].self, forKey: .members)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        idempotencyKey = try c.decode(String.self, forKey: .idempotencyKey)
        ttlMs = try c.decodeIfPresent(Int.self, forKey: .ttlMs)
        issuedAtMs = try c.decodeIfPresent(Int64.self, forKey: .issuedAtMs)
    }
}

/// One member `group.addMembers` did not add, and why: `alreadyMember` (already in the group, the
/// picker's own checkbox is disabled — not reselected), `notFound` (no picker row matched), `ambiguous`
/// (more than one row matched).
public struct SkippedMember: Codable, Equatable {
    public var name: String
    public var reason: String
    public init(name: String, reason: String) { self.name = name; self.reason = reason }
}

/// `group.addMembers` result. `before` / `after` are the group's member count when the client exposes
/// one (nil when it could not be read); `evidence` is a free-form proof string, same spirit as
/// `SendFileResult.evidence` (e.g. `"count 3→4"`, a `邀请` row summary, `"dry-run"`, `"nothing-to-add"`).
/// `reason` mirrors `SendFileResult.reason`: why a `failed` add failed, and the one key
/// `CommandExecutor.failureReason(in:)` looks for, so the command record carries it too. Only set on
/// `failed` — an `unknown` has no reason to give, just no evidence.
public struct GroupAddMembersResult: Codable, Equatable {
    public var state: CommandStateV1
    public var target: String
    public var before: Int?
    public var after: Int?
    public var added: [String]
    public var skipped: [SkippedMember]
    public var dryRun: Bool
    public var evidence: String
    public var latencyMs: Int
    public var reason: String?

    public init(state: CommandStateV1, target: String, before: Int? = nil, after: Int? = nil, added: [String], skipped: [SkippedMember],
                dryRun: Bool, evidence: String, latencyMs: Int, reason: String? = nil) {
        self.state = state; self.target = target; self.before = before; self.after = after
        self.added = added; self.skipped = skipped; self.dryRun = dryRun; self.evidence = evidence; self.latencyMs = latencyMs
        self.reason = reason
    }
}

public struct ReadParams: Codable, Equatable {
    public var target: String
    public init(target: String) { self.target = target }
}

public struct HistoryParams: Codable, Equatable {
    public var limit: Int?
    /// When true and fewer than `limit` rows are loaded, scroll the message
    /// area up so the client loads older history first (policy `scrollHistory`).
    public var scrollback: Bool?
    public init(limit: Int? = nil, scrollback: Bool? = nil) { self.limit = limit; self.scrollback = scrollback }
}

public struct CommandRefParams: Codable, Equatable {
    public var commandId: String?
    public var idempotencyKey: String?
    public init(commandId: String? = nil, idempotencyKey: String? = nil) { self.commandId = commandId; self.idempotencyKey = idempotencyKey }
}

public struct PauseParams: Codable, Equatable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public enum PauseReason: String, Codable, CaseIterable {
    case api
    case localGuard = "local_guard"
    case system
}

/// Errors the executor reports to callers; `code` is the wire-level string.
public enum ControlError: Error, Equatable {
    case targetNotFound(String)
    case targetAmbiguous(String)
    case targetMismatch(expected: String, actual: String?)
    case targetNotAllowed(String)
    case paused([PauseReason])
    case expired
    case localGuard(String)
    case invalidParams(String)
    case clientUnavailable(String)
    case internalError(String)
    case rateLimited(String)
    /// The controller cannot do this here (no API route configured, no AX probe target); not an error of the caller.
    case unsupported(String)
    /// B10: no cache file could be matched to this message (never observed by the running daemon, or the file is gone).
    case mediaNotFound(String)
    /// The WeCom platform answered with a non-zero errcode (passed through the proxy).
    case wecomAPI(errcode: Int, errmsg: String)
    /// The token-injecting proxy could not be reached or rejected the request.
    case proxy(String)
    // B13 message.sendFile / message.media over OSS
    case sourceNotAllowed(String)
    case sourceUnsupported(String)
    case sourceTooLarge(String)
    case sourceUnreachable(String)
    /// The attachment never appeared in the composer; nothing was sent.
    case pasteFailed(String)
    case ossNotConfigured(String)
    case mediaTooLarge(String)
    /// The object store answered with an error (HTTP status + its Code / Message, never a key or a signed URL).
    case objectStore(String)
    /// B14 `group.addMembers`: the target has no member list (no header count, no `群成员·` side panel text).
    case notAGroup(String)

    public var code: String {
        switch self {
        case .targetNotFound: return "TARGET_NOT_FOUND"
        case .targetAmbiguous: return "TARGET_AMBIGUOUS"
        case .targetMismatch: return "TARGET_MISMATCH"
        case .targetNotAllowed: return "TARGET_NOT_ALLOWED"
        case .paused: return "PAUSED"
        case .expired: return "EXPIRED"
        case .localGuard: return "LOCAL_GUARD"
        case .invalidParams: return "INVALID_PARAMS"
        case .clientUnavailable: return "CLIENT_UNAVAILABLE"
        case .internalError: return "INTERNAL"
        case .rateLimited: return "RATE_LIMITED"
        case .unsupported: return "UNSUPPORTED"
        case .mediaNotFound: return "MEDIA_NOT_FOUND"
        case .wecomAPI: return "WECOM_API"
        case .proxy: return "PROXY_ERROR"
        case .sourceNotAllowed: return "SOURCE_NOT_ALLOWED"
        case .sourceUnsupported: return "SOURCE_UNSUPPORTED"
        case .sourceTooLarge: return "SOURCE_TOO_LARGE"
        case .sourceUnreachable: return "SOURCE_UNREACHABLE"
        case .pasteFailed: return "PASTE_FAILED"
        case .ossNotConfigured: return "OSS_NOT_CONFIGURED"
        case .mediaTooLarge: return "MEDIA_TOO_LARGE"
        case .objectStore: return "OSS_ERROR"
        case .notAGroup: return "NOT_A_GROUP"
        }
    }

    /// Every wire code a `command.state` / JSON-RPC error can carry, including
    /// the restart-recovery code the executor sets without a `ControlError`.
    /// The protocol document must list each of these (`ProtocolDocTests`).
    public static let allCodes: [String] = [
        "TARGET_NOT_FOUND", "TARGET_AMBIGUOUS", "TARGET_MISMATCH", "TARGET_NOT_ALLOWED", "PAUSED", "EXPIRED", "LOCAL_GUARD",
        "INVALID_PARAMS", "CLIENT_UNAVAILABLE", "INTERNAL", "RATE_LIMITED", "UNSUPPORTED", "WECOM_API", "PROXY_ERROR",
        "UNKNOWN_AFTER_RESTART", "MEDIA_NOT_FOUND",
        "SOURCE_NOT_ALLOWED", "SOURCE_UNSUPPORTED", "SOURCE_TOO_LARGE", "SOURCE_UNREACHABLE", "PASTE_FAILED", "OSS_NOT_CONFIGURED", "MEDIA_TOO_LARGE", "OSS_ERROR",
        "NOT_A_GROUP",
    ]

    public var message: String {
        switch self {
        case .targetNotFound(let t): return "no conversation for target \"\(t)\""
        case .targetAmbiguous(let t): return "several conversations titled \"\(t)\""
        case .targetMismatch(let e, let a): return "expected \"\(e)\", active is \"\(a ?? "-")\""
        case .targetNotAllowed(let t): return "target \"\(t)\" is not allowlisted"
        case .paused(let r): return "controller paused: \(r.map(\.rawValue).joined(separator: ","))"
        case .expired: return "command expired before execution"
        case .localGuard(let why): return why
        case .invalidParams(let why): return why
        case .clientUnavailable(let why): return why
        case .internalError(let why): return why
        case .rateLimited(let why): return why
        case .unsupported(let why): return why
        case .mediaNotFound(let why): return why
        case .wecomAPI(let errcode, let errmsg): return "wecom errcode \(errcode): \(errmsg)"
        case .proxy(let why): return why
        case .sourceNotAllowed(let why): return why
        case .sourceUnsupported(let why): return why
        case .sourceTooLarge(let why): return why
        case .sourceUnreachable(let why): return why
        case .pasteFailed(let why): return why
        case .ossNotConfigured(let why): return why
        case .mediaTooLarge(let why): return why
        case .objectStore(let why): return why
        case .notAGroup(let t): return "\"\(t)\" is not a group (no member count found)"
        }
    }
}

public enum Clock {
    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

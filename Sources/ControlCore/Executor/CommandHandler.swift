import Foundation

public struct SendResult: Codable, Equatable {
    public var state: CommandStateV1
    public var evidence: String?
    public var reason: String?
    public var latencyMs: Int?
    public init(state: CommandStateV1, evidence: String? = nil, reason: String? = nil, latencyMs: Int? = nil) {
        self.state = state; self.evidence = evidence; self.reason = reason; self.latencyMs = latencyMs
    }
}

/// Platform work behind each method. Implemented by the WeCom adapter; faked in tests.
/// Handlers throw `ControlError` for protocol-level failures.
public protocol CommandHandler {
    func describe() throws -> [String: String]
    func accountStatus() throws -> [String: String]
    func conversationList() throws -> [[String: String]]
    func conversationRead(target: String) throws -> [String: String]
    /// Last `limit` rows of the active conversation; `scrollback` asks the client
    /// for older history first when fewer rows are loaded.
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]]
    /// `checkpoint` must be called right before the irreversible step; `afterSubmit` right after it
    /// (crash-injection point) and before evidence collection.
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult
    /// B13: fetch `source` into the outbox (policy-checked), paste it into the target's composer (⌘V) and send it with Return;
    /// `checkpoint` / `afterSubmit` bracket the irreversible step like `messageSend`. Never sends when the paste did not land.
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult
    /// Presses the client's own menu item for `action`; result keys `action`,
    /// `before`, `after` (active titles) and `changed` ("true"/"false").
    func clientNavigate(action: NavigateAction) throws -> [String: String]
    /// Contacts of the group picker: `scope` `customers` (我的客户; name, source, tag) or `all` (every row, with `section`).
    func contactList(limit: Int, scope: String) throws -> [[String: String]]
    /// Read-only look at the client's layout: frames, active title / type, counts, trust — the console's 诊断 over the wire.
    func diagnose() throws -> [String: String]
    /// B11: the daemon's own grants on this Mac; `prompt` triggers the system dialogs that can be triggered.
    func permissions(prompt: Bool, probe: Bool) throws -> [String: String]
    /// B10: inventory of the client's local media cache; `pending` while a scan or the system prompt is outstanding.
    func mediaCache(limit: Int, refresh: Bool) throws -> MediaCacheReport
    /// Diagnostic listing of one cache directory (relative to a root); read-only, names + sizes + first bytes.
    func mediaCacheList(root: String?, dir: String) throws -> MediaCacheReport
    /// B13: the picture / file / video poster behind a row, uploaded to the configured object store; a signed GET URL comes back, never bytes.
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference
    /// Cards on 通讯录 › 新的客户: `status` pending (接受 button) or added (打招呼 button).
    func contactRequestList() throws -> [[String: String]]
    /// Presses 接受 on the unique pending card titled `name`.
    func contactRequestAccept(name: String) throws -> [String: String]
    /// Creates a group from the picker with `members`; with `name` the header title is set once the group opened.
    func groupCreate(members: [String], name: String?) throws -> [String: String]
    /// Sets the header title of an allowlisted group (`target` in wire form): `{title, renamed, requestedName}`.
    func groupRename(target: String, name: String) throws -> [String: String]
    /// B14: add `members` (1…20) to the already-created, policy-allowed group `target` through the
    /// same picker sheet as `groupCreate`; a member already in the group is skipped, not reselected.
    /// `checkpoint` / `afterSubmit` bracket the sheet's own 确定 exactly like `messageSend`.
    func groupAddMembers(target: String, members: [String], dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> GroupAddMembersResult
    /// B12: search a phone number in 添加客户 and press the match's 添加 (or only list the matches when `dryRun`).
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool) throws -> [String: String]
}

/// Desktop mutations with a precise irreversible boundary. The executor persists the
/// command checkpoint immediately before the UI commit, then can inject a crash
/// immediately after it. A handler that has not adopted this interface is run with
/// a conservative checkpoint before its whole call.
public protocol CheckpointedDesktopCommandHandler: CommandHandler {
    func contactRequestAccept(name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String]
    func groupCreate(members: [String], name: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String]
    func groupRename(target: String, name: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String]
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String]
}

/// Only externally requested commands may use the opt-in cloud desktop planner.
/// Background policy automation keeps the deterministic local path.
public enum DesktopCommandOrigin: Equatable {
    case external
    case automation
}

public protocol DesktopCommandOriginAware: AnyObject {
    var desktopCommandOrigin: DesktopCommandOrigin { get set }
    var desktopCommandMethod: RPCMethod? { get set }
    /// True only while executing a message.broadcast child send. The child
    /// keeps its original command origin and existing target-selection flow.
    var desktopCommandIsBroadcastChild: Bool { get set }
    /// B54: set by the handler when a visual round ends the running command (fixed categories only). The
    /// executor clears it before each command and records it on a failed or unknown record.
    var desktopCommandVisualEnd: CommandDiagnosis.Visual? { get set }
}

public extension DesktopCommandOriginAware {
    /// Handlers without visual rounds never end a command visually.
    var desktopCommandVisualEnd: CommandDiagnosis.Visual? {
        get { nil }
        set {}
    }
}

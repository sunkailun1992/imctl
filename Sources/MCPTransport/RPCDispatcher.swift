import ControlCore
import Foundation

/// Line-delimited JSON-RPC 2.0. Accepts both MCP (`initialize`, `tools/list`,
/// `tools/call`) and direct protocol methods (`message.send`, …). Responses
/// are a convenience; the command/event store is the truth.
///
/// `event.replay` is a query, not a command: it reads the event log after a
/// cursor so a consumer can reconcile a gap, and creates no command record
/// and no `command.state` events of its own.
public final class RPCDispatcher: LineHandler {
    public let executor: CommandExecutor
    public let serverName: String
    public static let replayMethod = "event.replay"
    /// B10: a query like replay — the picture bytes never enter the command table.
    public static let mediaMethod = "message.media"
    /// B52: a query like replay — no command record, no events, never on the executor queue. The daemon
    /// sets `readiness`; without it (tests, other hosts) the answer is UNSUPPORTED.
    public static let readinessMethod = "controller.readiness"
    public var readiness: ReadinessProviding?
    public static let replayDefaultLimit = 200
    public static let replayMaxLimit = 1000

    public init(executor: CommandExecutor, serverName: String = "imctl") {
        self.executor = executor
        self.serverName = serverName
    }

    /// Returns nil for notifications (no id) and for empty lines.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request: JSONValue
        do { request = try JSONValue.parse(trimmed) } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "parse error")
        }
        guard let obj = request.objectValue, let method = obj["method"]?.stringValue else {
            return Self.errorResponse(id: obj_id(request), code: -32600, message: "invalid request")
        }
        let id = obj["id"] ?? .null
        let isNotification = obj["id"] == nil
        let params = obj["params"]?.objectValue ?? [:]

        let response: JSONValue
        switch method {
        case "initialize":
            response = .object([
                "protocolVersion": .string(params["protocolVersion"]?.stringValue ?? "2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(IMCTLVersion.string)]),
            ])
        case "notifications/initialized", "ping":
            if isNotification { return nil }
            response = .object([:])
        case "tools/list":
            response = .object(["tools": .array(Self.toolDescriptors())])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "unknown tool")
            }
            let args = params["arguments"]?.objectValue ?? [:]
            if name == Self.replayMethod {
                do {
                    let text = (try? replay(args).serialized()) ?? "{}"
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(false)])
                }
            } else if name == Self.mediaMethod {
                switch media(args) {
                case .success(let value):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string((try? value.serialized()) ?? "{}")])]), "isError": .bool(false)])
                case .failure(let err):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string("\(err.code): \(err.message)")])]), "isError": .bool(true)])
                }
            } else if name == Self.readinessMethod {
                switch readinessResult(args) {
                case .success(let value):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string((try? value.serialized()) ?? "{}")])]), "isError": .bool(false)])
                case .failure(let err):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string("\(err.code): \(err.message)")])]), "isError": .bool(true)])
                }
            } else {
                guard let rpc = RPCMethod(rawValue: name) else {
                    return Self.errorResponse(id: id, code: -32602, message: "unknown tool")
                }
                switch invoke(rpc, args: args) {
                case .success(let record):
                    let text = (try? Self.recordJSON(record).serialized()) ?? "{}"
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                        "isError": .bool(record.state == .failed || record.state == .expired)])
                case .failure(let err):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string("\(err.code): \(err.message)")])]),
                                        "isError": .bool(true)])
                }
            }
        case Self.replayMethod:
            do { response = try replay(params) } catch {
                return Self.errorResponse(id: id, code: -32000, message: String(describing: error), data: .object(["code": .string("INTERNAL")]))
            }
        case Self.mediaMethod:
            switch media(params) {
            case .success(let value): response = value
            case .failure(let err): return Self.errorResponse(id: id, code: -32000, message: err.message, data: .object(["code": .string(err.code)]))
            }
        case Self.readinessMethod:
            switch readinessResult(params) {
            case .success(let value): response = value
            case .failure(let err): return Self.errorResponse(id: id, code: -32000, message: err.message, data: .object(["code": .string(err.code)]))
            }
        default:
            guard let rpc = RPCMethod(rawValue: method) else {
                return Self.errorResponse(id: id, code: -32601, message: "method not found")
            }
            switch invoke(rpc, args: params) {
            case .success(let record): response = Self.recordJSON(record)
            case .failure(let err):
                return Self.errorResponse(id: id, code: -32000, message: err.message, data: .object(["code": .string(err.code)]))
            }
        }
        if isNotification { return nil }
        return (try? JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": response]).serialized()) ?? "{}"
    }

    // MARK: Helpers

    private func obj_id(_ v: JSONValue) -> JSONValue { v.objectValue?["id"] ?? .null }

    private func invoke(_ method: RPCMethod, args: [String: JSONValue]) -> Result<CommandRecord, ControlError> {
        let paramsJSON = (try? JSONValue.object(args).serialized()) ?? "{}"
        // Only state-changing methods are deduplicated by key; for command.get the key is a lookup argument.
        let key = method.requiresIdempotencyKey ? args["idempotencyKey"]?.stringValue : nil
        do {
            return .success(try executor.submit(method: method, paramsJSON: paramsJSON, idempotencyKey: key))
        } catch let e as ControlError {
            return .failure(e)
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }

    /// `{afterEventId, limit}` → `{events: [{eventId, tsMs, kind, payload}], count, lastEventId}`.
    /// `lastEventId` is the newest id in the store, so `count < limit` or
    /// `events.last.eventId == lastEventId` means the consumer has caught up.
    func replay(_ params: [String: JSONValue]) throws -> JSONValue {
        let after = Int64(params["afterEventId"]?.numberValue ?? 0)
        let requested = Int(params["limit"]?.numberValue ?? Double(Self.replayDefaultLimit))
        let limit = min(max(requested, 1), Self.replayMaxLimit)
        let events = try executor.store.events(after: after, limit: limit)
        let items: [JSONValue] = events.map { event in
            var object: [String: JSONValue] = [
                "eventId": .number(Double(event.eventId ?? 0)), "tsMs": .number(Double(event.tsMs)), "kind": .string(event.kind.rawValue),
            ]
            object["payload"] = (try? JSONValue.parse(event.payloadJSON)) ?? .string(event.payloadJSON)
            return .object(object)
        }
        return .object([
            "events": .array(items), "count": .number(Double(items.count)),
            "lastEventId": .number(Double(try executor.store.lastEventId())),
        ])
    }

    /// `{messageKey, hd?=true}` → `MediaReference` as JSON (query, no command record; bytes never leave the Mac — the caller gets a signed URL).
    func media(_ params: [String: JSONValue]) -> Result<JSONValue, ControlError> {
        guard let key = params["messageKey"]?.stringValue, !key.isEmpty else { return .failure(.invalidParams("message.media requires messageKey")) }
        do {
            let content = try executor.serialized { try executor.handler.messageMedia(messageKey: key, hd: params["hd"]?.boolValue ?? true) }
            let data = try JSONEncoder().encode(content)
            return .success(try JSONValue.parse(String(decoding: data, as: UTF8.self)))
        } catch let e as ControlError {
            return .failure(e)
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }

    /// `{online?=true, refresh?=false}` → `ReadinessReport` as JSON. Answers on the caller's queue: the
    /// provider never reads the AX tree or the network here (live tests run in the daemon's background).
    func readinessResult(_ params: [String: JSONValue]) -> Result<JSONValue, ControlError> {
        guard let readiness else { return .failure(.unsupported("controller.readiness needs the daemon")) }
        let report = readiness.readiness(online: params["online"]?.boolValue ?? true, refresh: params["refresh"]?.boolValue ?? false)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return .success(try JSONValue.parse(String(decoding: try encoder.encode(report), as: UTF8.self)))
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }

    static func recordJSON(_ r: CommandRecord) -> JSONValue {
        var o: [String: JSONValue] = [
            "commandId": .string(r.id), "method": .string(r.method), "state": .string(r.state.rawValue),
            "createdMs": .number(Double(r.createdMs)), "updatedMs": .number(Double(r.updatedMs)),
        ]
        if let k = r.idempotencyKey { o["idempotencyKey"] = .string(k) }
        if let j = r.resultJSON, let v = try? JSONValue.parse(j) { o["result"] = v }
        if let c = r.errorCode { o["error"] = .object(["code": .string(c), "message": .string(r.errorMessage ?? "")]) }
        if let cp = r.checkpointMs { o["checkpointMs"] = .number(Double(cp)) }
        if let d = r.diagnosisJSON, let v = try? JSONValue.parse(d) { o["diagnosis"] = v }
        return .object(o)
    }

    static func errorResponse(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> String {
        var err: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { err["data"] = data }
        return (try? JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(err)]).serialized()) ?? "{}"
    }

    static func toolDescriptors() -> [JSONValue] {
        func schema(_ props: [String: (String, String)], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(props.mapValues { .object(["type": .string($0.0), "description": .string($0.1)]) }),
                "required": .array(required.map(JSONValue.string)),
            ])
        }
        let target = ("string", "Conversation title, chatId:<id> or externalUserId:<id> (ids via the identity bridge; must be allowed by the compiled allowlist or policy.json)")
        return [
            ("controller.describe", "Controller identity, platform, policy, protocol version", schema([:], required: [])),
            ("account.status", "Whether the client window is reachable, active conversation, counts", schema([:], required: [])),
            ("conversation.list", "Visible conversation rows: title, preview, time label, badge, selected", schema([:], required: [])),
            ("conversation.read", "Open a conversation in the client (any title unless gateReads is on) and report the active title and visible message count", schema(["target": target], required: ["target"])),
            ("message.send", "Send a text to an allowlisted conversation; idempotent per idempotencyKey; evidence = outbound bubble", schema(["target": target, "text": ("string", "Text to send"), "idempotencyKey": ("string", "Caller-generated unique key"), "ttlMs": ("integer", "Expiry relative to issuedAtMs"), "issuedAtMs": ("integer", "Caller clock, ms since epoch")], required: ["target", "text", "idempotencyKey"])),
            ("message.sendFile", "Send a file (image / video / pdf / office / zip / txt) to an allowlisted conversation: the daemon downloads url (https, host on policy.json sendFile.allowedHosts) or ossKey (object in the configured bucket) into its outbox, pastes it into the composer (⌘V) and presses Return; evidence = a new outbound media / file / video row; idempotent per idempotencyKey", schema(["target": target, "url": ("string", "https source; host must be allowed by policy (imctl policy hosts)"), "ossKey": ("string", "Object key in the configured OSS bucket (alternative to url)"), "fileName": ("string", "Name to send as (default: the URL / key's last path component)"), "idempotencyKey": ("string", "Caller-generated unique key"), "ttlMs": ("integer", "Expiry relative to issuedAtMs"), "issuedAtMs": ("integer", "Caller clock, ms since epoch")], required: ["target", "idempotencyKey"])),
            ("message.history", "Newest rows of the active conversation: normal reads first scroll the client message pane to the latest position; scrollback loads older history. kind is message|media|file|video; files carry fileName / fileSize / fileType, videos duration, media rows mediaType image|unknown. A partial AX row carries readError and may omit messageKey; do not act on it. media / file / video rows with keys carry media: assigned|observed|unmatched", schema(["limit": ("integer", "Max rows (default 50)"), "scrollback": ("boolean", "Scroll up to load older rows when fewer than limit are loaded")], required: [])),
            ("message.media", "The picture / file / video poster behind a media, file or video row, uploaded once to the configured OSS bucket: ossKey, a signed GET url (expires after oss.json viewExpireSeconds), fileName, bytes, contentType; never bytes. OSS_NOT_CONFIGURED without oss.json; MEDIA_NOT_FOUND when nothing can be tied to the key (open the conversation and ask again)", schema(["messageKey": ("string", "messageKey of a media / file / video row from message.history / message.observed"), "hd": ("boolean", "Prefer the downloaded original picture (default true)")], required: ["messageKey"])),
            ("command.get", "Look up a command by commandId or idempotencyKey", schema(["commandId": ("string", "Command id"), "idempotencyKey": ("string", "Idempotency key")], required: [])),
            ("command.cancel", "Cancel a command that has not started (synchronous executor: usually a no-op)", schema(["commandId": ("string", "Command id")], required: [])),
            ("controller.pause", "Add the `api` pause reason (sends fail with PAUSED)", schema([:], required: [])),
            ("controller.resume", "Remove the `api` pause reason", schema([:], required: [])),
            ("client.navigate", "Press one of the client's own 窗口 menu items (nextConversation | previousConversation | nextUnreadConversation); needs idempotencyKey; result = before/after active titles and changed", schema(["action": ("string", "nextConversation | previousConversation | nextUnreadConversation"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["action", "idempotencyKey"])),
            // Contacts route (B7): 通讯录 and the group picker sheet, all UI.
            ("contact.list", "我的客户 through the client's group picker: name, source (wechat|wecom), tag; the sheet is cancelled afterwards, nothing changes", schema(["limit": ("integer", "Max contacts (default 200)"), "scope": ("string", "customers (default) | all — every picker row with its section")], required: [])),
            ("contact.request.list", "通讯录 › 新的客户 cards: name, greeting, source, status pending (接受 button) | added (打招呼 button); switches the client to 通讯录 and back", schema([:], required: [])),
            ("contact.request.accept", "Press 接受 on the pending request called name; needs idempotencyKey; capped per hour by policy.json", schema(["name": ("string", "Nickname exactly as the card shows it"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["name", "idempotencyKey"])),
            ("group.create", "Create a group from the picker with these members (names as the picker shows them); needs idempotencyKey; name is recorded, renaming is not attempted yet", schema(["members": ("array", "Member names"), "name": ("string", "Desired group name"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["members", "idempotencyKey"])),
            ("group.rename", "Write the header title of an allowlisted group and confirm it with the client's own AXConfirm; needs idempotencyKey; result = title, renamed, requestedName", schema(["target": target, "name": ("string", "New group name"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["target", "name", "idempotencyKey"])),
            ("group.addMembers", "Add members to an existing, allowlisted group through the client's 添加群成员 sheet: members already in the group are skipped (alreadyMember), unknown names skipped (notFound); dryRun selects and cancels; NOT_A_GROUP when the target has no member list; evidence = the member count or the client's 邀请 system row", schema(["target": ("string", "Group title / chatId:… / externalUserId:…"), "members": ("array", "Names to add (1–20)"), "dryRun": ("boolean", "Select then cancel, never confirm (default false)"), "idempotencyKey": ("string", "Required")], required: ["target", "members", "idempotencyKey"])),
            ("policy.get", "The local policy file: allowed titles / types / ids, contactRequests automation, remoteEdits switch", schema([:], required: [])),
            ("policy.set", "Allow / deny titles, replace contactRequests, set gateReads; refused unless remoteEdits was enabled on the Mac (imctl policy remote --enable)", schema(["allow": ("array", "Titles to allow"), "deny": ("array", "Titles to deny"), "contactRequests": ("object", "Whole contactRequests block (autoAccept, allowNames, greetingContains, autoGroup, groupDefaultMembers, groupNameTemplate, maxAcceptsPerHour)"), "gateReads": ("boolean", "true: conversation.read / scrollback must target an allowed title; false (default): any conversation can be opened"), "allowHosts": ("array", "Hosts message.sendFile may fetch a url source from (exact host, or a \".suffix\" rule)"), "denyHosts": ("array", "Hosts to remove from that list")], required: [])),
            ("controller.diagnose", "Read-only client layout: frames, active title / type, counts, Accessibility trust", schema([:], required: [])),
            ("controller.logs", "Tail of the daemon log", schema(["lines": ("integer", "Lines (default 100, max 500)")], required: [])),
            ("contact.add", "Add a customer by phone number through 通讯录 › 新的客户 › 添加客户: any number, up to the Mac's hourly cap (a sent request cannot be taken back); dryRun only lists the matches (wechat / wecom) without pressing anything", schema(["phone": ("string", "Phone number (digits)"), "source": ("string", "wechat (default) | wecom | any — which match to add"), "greeting": ("string", "Verification text when the client asks for one"), "dryRun": ("boolean", "Only search and report the matches"), "idempotencyKey": ("string", "Required")], required: ["phone", "idempotencyKey"])),
            ("controller.permissions", "What the daemon may do on this Mac: accessibility, screenRecording, wecomData (the client's container), fullDiskAccess, clientRunning, launchAgent; prompt:true triggers the system dialogs that can be triggered (setup time)", schema(["prompt": ("boolean", "Trigger the Accessibility / Screen Recording / container dialogs (default false)"), "probe": ("boolean", "Probe the client's container without requesting Accessibility or Screen Recording (the container itself may prompt)")], required: [])),
            ("controller.readiness", "Readiness of this Mac per capability (daemon, wecom, read, send, media, contactAdd, autoAccept, vision, mqtt, oss, agents, wecomApi, health): ok / fail / disabled / unknown with the command that fixes it (health only warns). A query: no command record. online:true (default) starts the live tests in the background — one synthetic-image vision call, MQTT publish ack, OSS 1 KB round trip, MCP handshake, proxy health — and answers online.state=running until they finish: call again a second later. refresh:true retests at most once per 60 s for every caller", schema(["online": ("boolean", "Run the live tests (default true)"), "refresh": ("boolean", "Retest instead of reusing the last round (at most once per 60 s for every caller)")], required: [])),
            ("message.broadcast", "The same text to several conversations: one paced message.send per target (child keys <key>#<index>), each judged by the allowlist and the rate limiter; other clients' commands interleave between targets", schema(["targets": ("array", "1…50 distinct conversation titles / chatId: / externalUserId:"), "text": ("string", "Text to send"), "idempotencyKey": ("string", "Key for the whole run; replaying it returns the run"), "intervalMs": ("integer", "Pause between targets (default 3500)"), "stopOnFailure": ("boolean", "Stop at the first failed target (default false)")], required: ["targets", "text", "idempotencyKey"])),
            ("controller.mediaCache", "Read-only inventory of the client's local media cache (pictures are not in the AX tree): newest image / video files and the directories they cluster in; pending while the scan or the macOS 'access data from other apps' prompt is outstanding", schema(["limit": ("integer", "Newest files to return (default 50, max 500)"), "refresh": ("boolean", "Scan again instead of returning the last result")], required: [])),
            (replayMethod, "Query (not a command): events after a cursor, in event_id order, for gap reconciliation", schema(["afterEventId": ("integer", "Return events with event_id greater than this (default 0)"), "limit": ("integer", "Max events (default 200, max 1000)")], required: [])),
            // WeCom official-API route (through the token-injecting proxy); UNSUPPORTED when the controller has no proxy enrolled.
            ("group.list", "Customer groups (groupchat/list); syncNames also fetches names and fills the identity bridge", schema(["cursor": ("string", "Page cursor"), "limit": ("integer", "Page size (max 1000)"), "statusFilter": ("integer", "0 all, 1 pending owner handover, 2 handed over, 3 owner left"), "syncNames": ("boolean", "Fetch each group's name and write chat_id↔name into the bridge")], required: [])),
            ("group.get", "Group detail (groupchat/get) and bridge chat_id↔name", schema(["chatId": ("string", "Group chat_id")], required: ["chatId"])),
            ("group.joinway.create", "Group join QR (groupchat/add_join_way, scene 2): auto_create_room when full, room_base_name+序号, state channel", schema(["chatIds": ("array", "Up to 5 chat_ids"), "remark": ("string", "Remark"), "autoCreateRoom": ("boolean", "Create a new room when the current one is full"), "roomBaseName": ("string", "Base name of auto-created rooms"), "roomBaseId": ("integer", "Starting number appended to roomBaseName"), "state": ("string", "Channel tag (≤30)")], required: ["chatIds"])),
            ("group.joinway.get", "Read a group join QR config (qrCode URL, chatIds, state)", schema(["configId": ("string", "config_id")], required: ["configId"])),
            ("group.joinway.update", "Update a group join QR config", schema(["configId": ("string", "config_id"), "chatIds": ("array", "chat_ids"), "remark": ("string", "Remark"), "autoCreateRoom": ("boolean", "Auto-create"), "roomBaseName": ("string", "Base name"), "roomBaseId": ("integer", "Base id"), "state": ("string", "Channel tag")], required: ["configId"])),
            ("group.joinway.delete", "Delete a group join QR config", schema(["configId": ("string", "config_id")], required: ["configId"])),
            ("contact.way.create", "联系我 QR (add_contact_way): scan adds the staff as a contact; state channel drives the welcome flow", schema(["type": ("integer", "1 single staff (default), 2 multiple"), "scene": ("integer", "2 QR code (default)"), "remark": ("string", "Remark"), "skipVerify": ("boolean", "Add without confirmation (default true)"), "state": ("string", "Channel tag"), "users": ("array", "Staff userids"), "conclusionText": ("string", "Text sent after adding")], required: [])),
            ("contact.way.list", "List 联系我 config ids", schema(["cursor": ("string", "Page cursor"), "limit": ("integer", "Page size")], required: [])),
            ("contact.way.get", "Read a 联系我 config (qrCode, state, users)", schema(["configId": ("string", "config_id")], required: ["configId"])),
            ("contact.way.update", "Update a 联系我 config", schema(["configId": ("string", "config_id"), "remark": ("string", "Remark"), "skipVerify": ("boolean", "Skip verify"), "state": ("string", "Channel tag"), "users": ("array", "Staff userids"), "conclusionText": ("string", "Conclusion text")], required: ["configId"])),
            ("contact.way.delete", "Delete a 联系我 config", schema(["configId": ("string", "config_id")], required: ["configId"])),
            ("contact.welcome.send", "Welcome message within 20 s of add_external_contact (send_welcome_msg); attachments pass through in WeCom shape", schema(["welcomeCode": ("string", "WelcomeCode from the callback"), "text": ("string", "Text"), "attachments": ("array", "WeCom attachments (link/image/miniprogram/video/file)")], required: ["welcomeCode"])),
            ("contact.remark.set", "Set the customer remark (externalcontact/remark) and bridge external_userid↔remark; remark = '<原名>·<短码>' so the desktop client shows a unique title", schema(["userid": ("string", "Staff userid who owns the contact"), "externalUserId": ("string", "external_userid"), "remark": ("string", "Remark shown as the conversation title"), "description": ("string", "Description")], required: ["userid", "externalUserId", "remark"])),
            ("broadcast.create", "Enterprise broadcast task (add_msg_template) to groups or customers; needs idempotencyKey; a human or broadcast.confirm still sends it in the client", schema(["chatIds": ("array", "Group chat_ids (chat_type group)"), "externalUserIds": ("array", "external_userids (chat_type single)"), "sender": ("string", "Staff userid"), "text": ("string", "Text (≤4000 bytes)"), "attachments": ("array", "WeCom attachments"), "allowSelect": ("boolean", "Let staff pick"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["text", "idempotencyKey"])),
            ("broadcast.confirm", "Desktop step: AXPress the send button of the client's 群发助手 task; repeated msgid is deduplicated even for older callers without a key", schema(["msgid": ("string", "msgid from broadcast.create"), "idempotencyKey": ("string", "Optional caller key; when omitted the controller derives one from msgid")], required: ["msgid"])),
            ("broadcast.get", "Task list (get_groupmsg_task) or, with userid, per-chat results (get_groupmsg_send_result)", schema(["msgid": ("string", "msgid"), "userid": ("string", "Staff userid for per-chat results"), "cursor": ("string", "Page cursor"), "limit": ("integer", "Page size")], required: ["msgid"])),
        ].map { name, desc, schema in
            .object(["name": .string(name), "description": .string(desc), "inputSchema": schema])
        }
    }
}

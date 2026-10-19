import ControlCore
import Foundation

/// Write side of the identity bridge; `ControlStore` already has this method.
public protocol IdentityWriter {
    func upsertIdentity(kind: IdentityKind, id: String, title: String, nowMs: Int64) throws
}

extension ControlStore: IdentityWriter {}

/// Maps the protocol's `group.*` / `contact.*` / `broadcast.*` methods onto
/// the WeCom interfaces and writes what it learns (group names, customer
/// remarks) into the identity bridge so UI targets can be addressed by id.
/// `broadcast.confirm` is the one desktop step: it is delegated to a closure
/// the daemon wires to the adapter's AX probe; without one it is UNSUPPORTED.
public final class WeComAPIHandler: CheckpointedBroadcastConfirmHandler {
    public let client: WeComAPIClient
    public let identities: IdentityWriter?
    public let now: () -> Int64
    public var confirmBroadcast: ((String) throws -> [String: String])?
    /// The daemon uses this closure to place a durable checkpoint immediately
    /// before the desktop send button and to trigger crash testing afterwards.
    public var confirmBroadcastWithHooks: ((String, () throws -> Void, () throws -> Void) throws -> [String: String])?

    public init(client: WeComAPIClient, identities: IdentityWriter?, now: @escaping () -> Int64 = Clock.nowMs) {
        self.client = client
        self.identities = identities
        self.now = now
    }

    // MARK: APICommandHandler

    public func broadcastConfirm(paramsJSON: String, checkpoint: () throws -> Void,
                                 afterSubmit: () throws -> Void) throws -> String {
        let params = try decode(BroadcastRefParams.self, paramsJSON)
        let result: [String: String]
        if let confirmBroadcastWithHooks {
            result = try withoutActuallyEscaping(checkpoint) { before in
                try withoutActuallyEscaping(afterSubmit) { after in
                    try confirmBroadcastWithHooks(params.msgid, before, after)
                }
            }
        } else {
            guard let confirmBroadcast else {
                throw ControlError.unsupported("broadcast.confirm needs the desktop client (no confirm probe wired)")
            }
            try checkpoint()
            result = try confirmBroadcast(params.msgid)
            try afterSubmit()
        }
        return try encode(result.mapValues(AnyJSON.string))
    }

    public func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String {
        switch method {
        case .groupList:
            let p = try decode(GroupListParams.self, paramsJSON)
            let page = try client.groupList(GroupListRequest(statusFilter: p.statusFilter, cursor: p.cursor, limit: p.limit))
            var groups: [AnyJSON] = []
            for g in page.groupChatList {
                var item: [String: AnyJSON] = ["chatId": .string(g.chatId)]
                if let s = g.status { item["status"] = .number(Double(s)) }
                if p.syncNames == true, let name = try client.groupGet(chatId: g.chatId).groupChat.name {
                    try identities?.upsertIdentity(kind: .group, id: g.chatId, title: name, nowMs: now())
                    item["name"] = .string(name)
                }
                groups.append(.object(item))
            }
            return try encode(["groups": .array(groups), "nextCursor": .string(page.nextCursor ?? "")])
        case .groupGet:
            let p = try decode(GroupGetParams.self, paramsJSON)
            let group = try client.groupGet(chatId: p.chatId).groupChat
            if let name = group.name { try identities?.upsertIdentity(kind: .group, id: group.chatId, title: name, nowMs: now()) }
            return try encode(Self.groupJSON(group))
        case .groupJoinwayCreate:
            let p = try decode(JoinwayCreateParams.self, paramsJSON)
            let r = try client.joinWayCreate(JoinWayRequest(
                scene: 2, remark: p.remark, autoCreateRoom: (p.autoCreateRoom ?? false) ? 1 : 0, roomBaseName: p.roomBaseName,
                roomBaseId: p.roomBaseId, chatIdList: p.chatIds, state: p.state))
            return try encode(["configId": .string(r.configId)])
        case .groupJoinwayGet:
            let p = try decode(ConfigIdParams.self, paramsJSON)
            let jw = try client.joinWayGet(configId: p.configId).joinWay
            var out: [String: AnyJSON] = ["configId": .string(jw.configId), "chatIds": .array((jw.chatIdList ?? []).map(AnyJSON.string))]
            if let v = jw.qrCode { out["qrCode"] = .string(v) }
            if let v = jw.state { out["state"] = .string(v) }
            if let v = jw.remark { out["remark"] = .string(v) }
            if let v = jw.roomBaseName { out["roomBaseName"] = .string(v) }
            if let v = jw.roomBaseId { out["roomBaseId"] = .number(Double(v)) }
            if let v = jw.autoCreateRoom { out["autoCreateRoom"] = .bool(v == 1) }
            if let v = jw.scene { out["scene"] = .number(Double(v)) }
            return try encode(out)
        case .groupJoinwayUpdate:
            let p = try decode(JoinwayUpdateParams.self, paramsJSON)
            try client.joinWayUpdate(JoinWayRequest(
                configId: p.configId, scene: 2, remark: p.remark, autoCreateRoom: p.autoCreateRoom.map { $0 ? 1 : 0 },
                roomBaseName: p.roomBaseName, roomBaseId: p.roomBaseId, chatIdList: p.chatIds, state: p.state))
            return try encode(["ok": .bool(true), "configId": .string(p.configId)])
        case .groupJoinwayDelete:
            let p = try decode(ConfigIdParams.self, paramsJSON)
            try client.joinWayDelete(configId: p.configId)
            return try encode(["ok": .bool(true), "configId": .string(p.configId)])
        case .contactWayCreate:
            let p = try decode(ContactWayCreateParams.self, paramsJSON)
            let r = try client.contactWayCreate(ContactWayRequest(
                type: p.type ?? 1, scene: p.scene ?? 2, remark: p.remark, skipVerify: p.skipVerify ?? true, state: p.state, user: p.users,
                conclusions: p.conclusionText.map { Conclusions(text: WeComText(content: $0)) }))
            var out: [String: AnyJSON] = ["configId": .string(r.configId)]
            if let q = r.qrCode { out["qrCode"] = .string(q) }
            return try encode(out)
        case .contactWayList:
            let p = try decode(ContactWayListParams.self, paramsJSON)
            let r = try client.contactWayList(ContactWayListRequest(cursor: p.cursor, limit: p.limit))
            return try encode(["configIds": .array((r.contactWay ?? []).map { .string($0.configId) }), "nextCursor": .string(r.nextCursor ?? "")])
        case .contactWayGet:
            let p = try decode(ConfigIdParams.self, paramsJSON)
            let cw = try client.contactWayGet(configId: p.configId).contactWay
            var out: [String: AnyJSON] = ["configId": .string(cw.configId), "users": .array((cw.user ?? []).map(AnyJSON.string))]
            if let v = cw.qrCode { out["qrCode"] = .string(v) }
            if let v = cw.state { out["state"] = .string(v) }
            if let v = cw.remark { out["remark"] = .string(v) }
            if let v = cw.skipVerify { out["skipVerify"] = .bool(v) }
            if let v = cw.scene { out["scene"] = .number(Double(v)) }
            if let v = cw.type { out["type"] = .number(Double(v)) }
            if let v = cw.conclusions?.text?.content { out["conclusionText"] = .string(v) }
            return try encode(out)
        case .contactWayUpdate:
            let p = try decode(ContactWayUpdateParams.self, paramsJSON)
            try client.contactWayUpdate(ContactWayRequest(
                configId: p.configId, type: nil, scene: nil, remark: p.remark, skipVerify: p.skipVerify, state: p.state, user: p.users,
                conclusions: p.conclusionText.map { Conclusions(text: WeComText(content: $0)) }))
            return try encode(["ok": .bool(true), "configId": .string(p.configId)])
        case .contactWayDelete:
            let p = try decode(ConfigIdParams.self, paramsJSON)
            try client.contactWayDelete(configId: p.configId)
            return try encode(["ok": .bool(true), "configId": .string(p.configId)])
        case .contactWelcomeSend:
            let p = try decode(WelcomeSendParams.self, paramsJSON)
            try client.sendWelcome(WelcomeRequest(welcomeCode: p.welcomeCode, text: p.text.map(WeComText.init), attachments: p.attachments))
            return try encode(["ok": .bool(true)])
        case .contactRemarkSet:
            let p = try decode(RemarkSetParams.self, paramsJSON)
            try client.remark(RemarkRequest(userid: p.userid, externalUserid: p.externalUserId, remark: p.remark, description: p.description))
            try identities?.upsertIdentity(kind: .customer, id: p.externalUserId, title: p.remark, nowMs: now())
            return try encode(["ok": .bool(true), "externalUserId": .string(p.externalUserId), "title": .string(p.remark)])
        case .broadcastCreate:
            let p = try decode(BroadcastCreateParams.self, paramsJSON)
            let chatType = (p.chatIds?.isEmpty == false) ? "group" : "single"
            let r = try client.addMsgTemplate(MsgTemplateRequest(
                chatType: chatType, externalUserid: chatType == "single" ? p.externalUserIds : nil,
                chatIdList: chatType == "group" ? p.chatIds : nil, sender: p.sender, allowSelect: p.allowSelect,
                text: WeComText(content: p.text), attachments: p.attachments))
            return try encode(["msgid": .string(r.msgid ?? ""), "failList": .array((r.failList ?? []).map(AnyJSON.string)), "chatType": .string(chatType)])
        case .broadcastConfirm:
            let p = try decode(BroadcastRefParams.self, paramsJSON)
            guard let confirm = confirmBroadcast else {
                throw ControlError.unsupported("broadcast.confirm needs the desktop client (no confirm probe wired)")
            }
            return try encode(try confirm(p.msgid).mapValues(AnyJSON.string))
        case .broadcastGet:
            let p = try decode(BroadcastRefParams.self, paramsJSON)
            if let userid = p.userid {
                let r = try client.groupMsgSendResult(msgid: p.msgid, userid: userid, cursor: p.cursor, limit: p.limit)
                let results: [AnyJSON] = (r.sendList ?? []).map { s in
                    var o: [String: AnyJSON] = [:]
                    if let v = s.chatId { o["chatId"] = .string(v) }
                    if let v = s.externalUserid { o["externalUserId"] = .string(v) }
                    if let v = s.userid { o["userid"] = .string(v) }
                    if let v = s.status { o["status"] = .number(Double(v)) }
                    if let v = s.sendTime { o["sendTime"] = .number(Double(v)) }
                    return .object(o)
                }
                return try encode(["msgid": .string(p.msgid), "results": .array(results), "nextCursor": .string(r.nextCursor ?? "")])
            }
            let r = try client.groupMsgTask(msgid: p.msgid, cursor: p.cursor, limit: p.limit)
            let tasks: [AnyJSON] = (r.taskList ?? []).map { t in
                var o: [String: AnyJSON] = ["userid": .string(t.userid)]
                if let v = t.status { o["status"] = .number(Double(v)) }
                if let v = t.sendTime { o["sendTime"] = .number(Double(v)) }
                return .object(o)
            }
            return try encode(["msgid": .string(p.msgid), "tasks": .array(tasks), "nextCursor": .string(r.nextCursor ?? "")])
        default:
            throw ControlError.invalidParams("\(method.rawValue) is not a WeCom API method")
        }
    }

    // MARK: Bridge sync

    /// Pages through `groupchat/list`, fetches each group's name and writes
    /// `group` identities. Returns what was synced (chat id, name).
    public func syncGroups(pageLimit: Int = 100, statusFilter: Int = 0) throws -> [(chatId: String, name: String)] {
        var cursor: String?
        var synced: [(chatId: String, name: String)] = []
        var pages = 0
        repeat {
            let page = try client.groupList(GroupListRequest(statusFilter: statusFilter, cursor: cursor, limit: pageLimit))
            for g in page.groupChatList {
                guard let name = try client.groupGet(chatId: g.chatId).groupChat.name else { continue }
                try identities?.upsertIdentity(kind: .group, id: g.chatId, title: name, nowMs: now())
                synced.append((g.chatId, name))
            }
            cursor = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
            pages += 1
        } while cursor != nil && pages < 1000
        return synced
    }

    // MARK: Helpers

    static func groupJSON(_ g: GroupChat) -> [String: AnyJSON] {
        var out: [String: AnyJSON] = ["chatId": .string(g.chatId)]
        if let v = g.name { out["name"] = .string(v) }
        if let v = g.owner { out["owner"] = .string(v) }
        if let v = g.createTime { out["createTime"] = .number(Double(v)) }
        if let v = g.notice { out["notice"] = .string(v) }
        let members: [AnyJSON] = (g.memberList ?? []).map { m in
            var o: [String: AnyJSON] = ["userid": .string(m.userid)]
            if let v = m.type { o["type"] = .number(Double(v)) }
            if let v = m.name { o["name"] = .string(v) }
            if let v = m.joinTime { o["joinTime"] = .number(Double(v)) }
            if let v = m.groupNickname { o["groupNickname"] = .string(v) }
            if let v = m.unionid { o["unionid"] = .string(v) }
            return .object(o)
        }
        out["members"] = .array(members)
        out["memberCount"] = .number(Double(members.count))
        return out
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) } catch {
            throw ControlError.invalidParams("cannot decode \(type): \(error)")
        }
    }

    private func encode(_ object: [String: AnyJSON]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(object), as: UTF8.self)
    }
}

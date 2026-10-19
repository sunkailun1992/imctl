import ControlCore
import Foundation

/// Typed calls to the WeCom interfaces imctl uses, all through the proxy.
/// Decodes the standard envelope first: a non-zero `errcode` is
/// `ControlError.wecomAPI`, a non-2xx proxy answer is `ControlError.proxy`.
public struct WeComAPIClient {
    public var transport: WeComTransport

    public init(transport: WeComTransport) { self.transport = transport }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// POST one interface (`externalcontact/...`) and decode `Res` from the same body.
    public func call<Req: Encodable, Res: Decodable>(_ path: String, _ req: Req, as: Res.Type) throws -> Res {
        let body = try Self.encoder.encode(req)
        let response = try transport.post(path: path, body: body)
        switch response.status {
        case 200...299: break
        case 401, 403: throw ControlError.proxy("proxy rejected the token (HTTP \(response.status))")
        default: throw ControlError.proxy("proxy HTTP \(response.status)")
        }
        guard let envelope = try? Self.decoder.decode(WeComEnvelope.self, from: response.body) else {
            throw ControlError.proxy("cannot decode \(path) response: not a WeCom envelope")
        }
        if envelope.errcode != 0 { throw ControlError.wecomAPI(errcode: envelope.errcode, errmsg: envelope.errmsg ?? "") }
        do { return try Self.decoder.decode(Res.self, from: response.body) } catch {
            throw ControlError.proxy("cannot decode \(path) response: \(error)")
        }
    }

    // MARK: Groups

    public func groupList(_ req: GroupListRequest) throws -> GroupListResponse {
        try call("externalcontact/groupchat/list", req, as: GroupListResponse.self)
    }

    public func groupGet(chatId: String) throws -> GroupGetResponse {
        try call("externalcontact/groupchat/get", GroupGetRequest(chatId: chatId, needName: 1), as: GroupGetResponse.self)
    }

    public func joinWayCreate(_ req: JoinWayRequest) throws -> JoinWayCreateResponse {
        try call("externalcontact/groupchat/add_join_way", req, as: JoinWayCreateResponse.self)
    }

    public func joinWayGet(configId: String) throws -> JoinWayGetResponse {
        try call("externalcontact/groupchat/get_join_way", ConfigIdRequest(configId: configId), as: JoinWayGetResponse.self)
    }

    public func joinWayUpdate(_ req: JoinWayRequest) throws {
        _ = try call("externalcontact/groupchat/update_join_way", req, as: WeComEnvelope.self)
    }

    public func joinWayDelete(configId: String) throws {
        _ = try call("externalcontact/groupchat/del_join_way", ConfigIdRequest(configId: configId), as: WeComEnvelope.self)
    }

    // MARK: Contact way (联系我)

    public func contactWayCreate(_ req: ContactWayRequest) throws -> ContactWayCreateResponse {
        try call("externalcontact/add_contact_way", req, as: ContactWayCreateResponse.self)
    }

    public func contactWayList(_ req: ContactWayListRequest) throws -> ContactWayListResponse {
        try call("externalcontact/list_contact_way", req, as: ContactWayListResponse.self)
    }

    public func contactWayGet(configId: String) throws -> ContactWayGetResponse {
        try call("externalcontact/get_contact_way", ConfigIdRequest(configId: configId), as: ContactWayGetResponse.self)
    }

    public func contactWayUpdate(_ req: ContactWayRequest) throws {
        _ = try call("externalcontact/update_contact_way", req, as: WeComEnvelope.self)
    }

    public func contactWayDelete(configId: String) throws {
        _ = try call("externalcontact/del_contact_way", ConfigIdRequest(configId: configId), as: WeComEnvelope.self)
    }

    // MARK: Welcome, remark

    public func sendWelcome(_ req: WelcomeRequest) throws {
        _ = try call("externalcontact/send_welcome_msg", req, as: WeComEnvelope.self)
    }

    public func remark(_ req: RemarkRequest) throws {
        _ = try call("externalcontact/remark", req, as: WeComEnvelope.self)
    }

    // MARK: Broadcast (企业群发)

    public func addMsgTemplate(_ req: MsgTemplateRequest) throws -> MsgTemplateResponse {
        try call("externalcontact/add_msg_template", req, as: MsgTemplateResponse.self)
    }

    public func groupMsgTask(msgid: String, cursor: String?, limit: Int?) throws -> GroupMsgTaskResponse {
        try call("externalcontact/get_groupmsg_task", GroupMsgTaskRequest(msgid: msgid, cursor: cursor, limit: limit), as: GroupMsgTaskResponse.self)
    }

    public func groupMsgSendResult(msgid: String, userid: String, cursor: String?, limit: Int?) throws -> GroupMsgSendResultResponse {
        try call("externalcontact/get_groupmsg_send_result", GroupMsgSendResultRequest(msgid: msgid, userid: userid, cursor: cursor, limit: limit),
                 as: GroupMsgSendResultResponse.self)
    }
}

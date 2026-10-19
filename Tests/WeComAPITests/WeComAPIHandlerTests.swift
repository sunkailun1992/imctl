import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

final class MemoryIdentities: IdentityWriter {
    var rows: [String: (IdentityKind, String)] = [:]
    func upsertIdentity(kind: IdentityKind, id: String, title: String, nowMs: Int64) throws { rows[id] = (kind, title) }
}

@Suite("WeComAPIHandler")
struct WeComAPIHandlerTests {
    func make() -> (WeComAPIHandler, RecordingTransport, MemoryIdentities) {
        let t = RecordingTransport()
        let ids = MemoryIdentities()
        return (WeComAPIHandler(client: WeComAPIClient(transport: t), identities: ids, now: { 42 }), t, ids)
    }

    func json(_ s: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }

    @Test func groupGetAndRemarkFillTheBridge() throws {
        let (h, t, ids) = make()
        t.script["externalcontact/groupchat/get"] = (200, #"{"errcode":0,"errmsg":"ok","group_chat":{"chat_id":"wr1","name":"imctl测试群","owner":"u1","member_list":[{"userid":"wm1","type":2,"name":"小明"}]}}"#)
        let r = try json(try h.handleAPI(method: .groupGet, paramsJSON: #"{"chatId":"wr1"}"#))
        #expect(r["chatId"] as? String == "wr1" && r["name"] as? String == "imctl测试群" && (r["members"] as? [[String: Any]])?.count == 1)
        #expect(ids.rows["wr1"]?.0 == .group && ids.rows["wr1"]?.1 == "imctl测试群")
        _ = try h.handleAPI(method: .contactRemarkSet, paramsJSON: #"{"userid":"u1","externalUserId":"wm1","remark":"小明·a1b2c3"}"#)
        #expect(t.calls.last?.body["remark"] as? String == "小明·a1b2c3" && ids.rows["wm1"]?.0 == .customer && ids.rows["wm1"]?.1 == "小明·a1b2c3")
    }

    @Test func groupListPagesAndSyncsNamesOnRequest() throws {
        let (h, t, ids) = make()
        let pages = [#"{"errcode":0,"errmsg":"ok","group_chat_list":[{"chat_id":"wr1","status":0}],"next_cursor":"n1"}"#,
                     #"{"errcode":0,"errmsg":"ok","group_chat_list":[{"chat_id":"wr2","status":0}],"next_cursor":""}"#]
        t.dynamic["externalcontact/groupchat/list"] = { body in
            let cursor = body["cursor"] as? String
            return (200, cursor == "n1" ? pages[1] : pages[0])
        }
        t.dynamic["externalcontact/groupchat/get"] = { body in
            let id = body["chat_id"] as? String ?? ""
            return (200, #"{"errcode":0,"errmsg":"ok","group_chat":{"chat_id":"\#(id)","name":"群\#(id)"}}"#)
        }
        let synced = try h.syncGroups(pageLimit: 1)
        #expect(synced.map(\.chatId) == ["wr1", "wr2"] && ids.rows["wr2"]?.1 == "群wr2")
        let r = try json(try h.handleAPI(method: .groupList, paramsJSON: #"{"limit":1,"syncNames":false}"#))
        #expect((r["groups"] as? [[String: Any]])?.first?["chatId"] as? String == "wr1" && r["nextCursor"] as? String == "n1")
        let named = try json(try h.handleAPI(method: .groupList, paramsJSON: #"{"limit":1,"syncNames":true}"#))
        #expect((named["groups"] as? [[String: Any]])?.first?["name"] as? String == "群wr1")
    }

    @Test func broadcastCreateConfirmAndGet() throws {
        let (h, t, _) = make()
        t.script["externalcontact/add_msg_template"] = (200, #"{"errcode":0,"errmsg":"ok","fail_list":["wr9"],"msgid":"msg1"}"#)
        t.script["externalcontact/get_groupmsg_task"] = (200, #"{"errcode":0,"errmsg":"ok","task_list":[{"userid":"u1","status":1}],"next_cursor":""}"#)
        t.script["externalcontact/get_groupmsg_send_result"] = (200, #"{"errcode":0,"errmsg":"ok","send_list":[{"chat_id":"wr1","userid":"u1","status":1}],"next_cursor":""}"#)
        let created = try json(try h.handleAPI(method: .broadcastCreate, paramsJSON: #"{"chatIds":["wr1","wr9"],"sender":"u1","text":"公告","idempotencyKey":"b1"}"#))
        #expect(created["msgid"] as? String == "msg1" && created["failList"] as? [String] == ["wr9"])
        #expect(t.calls.last?.body["chat_type"] as? String == "group" && t.calls.last?.body["chat_id_list"] as? [String] == ["wr1", "wr9"])
        #expect(throws: ControlError.unsupported("broadcast.confirm needs the desktop client (no confirm probe wired)")) {
            try h.handleAPI(method: .broadcastConfirm, paramsJSON: #"{"msgid":"msg1"}"#)
        }
        h.confirmBroadcast = { msgid in ["msgid": msgid, "verified": "true"] }
        #expect(try json(try h.handleAPI(method: .broadcastConfirm, paramsJSON: #"{"msgid":"msg1"}"#))["verified"] as? String == "true")
        let tasks = try json(try h.handleAPI(method: .broadcastGet, paramsJSON: #"{"msgid":"msg1"}"#))
        #expect((tasks["tasks"] as? [[String: Any]])?.first?["userid"] as? String == "u1")
        let results = try json(try h.handleAPI(method: .broadcastGet, paramsJSON: #"{"msgid":"msg1","userid":"u1"}"#))
        #expect((results["results"] as? [[String: Any]])?.first?["chatId"] as? String == "wr1")
        let single = try json(try h.handleAPI(method: .broadcastCreate, paramsJSON: #"{"externalUserIds":["wm1"],"text":"hi","idempotencyKey":"b2"}"#))
        #expect(single["chatType"] as? String == "single" && t.calls.last?.body["external_userid"] as? [String] == ["wm1"])
    }

    @Test func joinWayAndContactWayAndWelcome() throws {
        let (h, t, _) = make()
        t.script["externalcontact/groupchat/add_join_way"] = (200, #"{"errcode":0,"errmsg":"ok","config_id":"cfg1"}"#)
        t.script["externalcontact/groupchat/get_join_way"] = (200, #"{"errcode":0,"errmsg":"ok","join_way":{"config_id":"cfg1","qr_code":"https://q/x","chat_id_list":["wr1"]}}"#)
        t.script["externalcontact/add_contact_way"] = (200, #"{"errcode":0,"errmsg":"ok","config_id":"cw1","qr_code":"https://q/y"}"#)
        t.script["externalcontact/list_contact_way"] = (200, #"{"errcode":0,"errmsg":"ok","contact_way":[{"config_id":"cw1"}],"next_cursor":""}"#)
        t.script["externalcontact/get_contact_way"] = (200, #"{"errcode":0,"errmsg":"ok","contact_way":{"config_id":"cw1","state":"ch1","skip_verify":true,"qr_code":"https://q/y"}}"#)
        let jw = try json(try h.handleAPI(method: .groupJoinwayCreate, paramsJSON: #"{"chatIds":["wr1"],"autoCreateRoom":true,"roomBaseName":"imctl群","roomBaseId":1,"state":"ch1"}"#))
        #expect(jw["configId"] as? String == "cfg1" && t.calls.last?.body["scene"] as? Int == 2 && t.calls.last?.body["auto_create_room"] as? Int == 1)
        #expect(try json(try h.handleAPI(method: .groupJoinwayGet, paramsJSON: #"{"configId":"cfg1"}"#))["qrCode"] as? String == "https://q/x")
        _ = try h.handleAPI(method: .groupJoinwayUpdate, paramsJSON: #"{"configId":"cfg1","chatIds":["wr1","wr2"]}"#)
        #expect(t.calls.last?.path == "externalcontact/groupchat/update_join_way")
        _ = try h.handleAPI(method: .groupJoinwayDelete, paramsJSON: #"{"configId":"cfg1"}"#)
        let cw = try json(try h.handleAPI(method: .contactWayCreate, paramsJSON: #"{"scene":2,"skipVerify":true,"state":"ch1","users":["u1"],"conclusionText":"欢迎"}"#))
        #expect(cw["configId"] as? String == "cw1" && (t.calls.last?.body["conclusions"] as? [String: Any]) != nil && t.calls.last?.body["type"] as? Int == 1)
        #expect((try json(try h.handleAPI(method: .contactWayList, paramsJSON: "{}"))["configIds"] as? [String]) == ["cw1"])
        #expect(try json(try h.handleAPI(method: .contactWayGet, paramsJSON: #"{"configId":"cw1"}"#))["state"] as? String == "ch1")
        _ = try h.handleAPI(method: .contactWayUpdate, paramsJSON: #"{"configId":"cw1","skipVerify":false}"#)
        #expect(t.calls.last?.path == "externalcontact/update_contact_way" && t.calls.last?.body["skip_verify"] as? Bool == false)
        _ = try h.handleAPI(method: .contactWayDelete, paramsJSON: #"{"configId":"cw1"}"#)
        _ = try h.handleAPI(method: .contactWelcomeSend, paramsJSON: #"{"welcomeCode":"wc1","text":"欢迎","attachments":[{"msgtype":"link","link":{"title":"群","url":"https://q/x"}}]}"#)
        #expect(t.calls.last?.path == "externalcontact/send_welcome_msg" && t.calls.last?.body["welcome_code"] as? String == "wc1")
        #expect(throws: ControlError.self) { try h.handleAPI(method: .messageSend, paramsJSON: "{}") }
    }
}

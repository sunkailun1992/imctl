import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

@Suite("WeComAPIClient request/response mapping")
struct WeComAPIClientTests {
    @Test func groupListAndGetDecodeSnakeCase() throws {
        let t = RecordingTransport()
        t.script["externalcontact/groupchat/list"] = (200, #"{"errcode":0,"errmsg":"ok","group_chat_list":[{"chat_id":"wr1","status":0}],"next_cursor":"c2"}"#)
        t.script["externalcontact/groupchat/get"] = (200, #"{"errcode":0,"errmsg":"ok","group_chat":{"chat_id":"wr1","name":"imctl测试群","owner":"u1","create_time":1,"member_list":[{"userid":"u1","type":1},{"userid":"wm1","type":2,"name":"小明"}]}}"#)
        let c = WeComAPIClient(transport: t)
        let list = try c.groupList(GroupListRequest(statusFilter: 0, cursor: nil, limit: 50))
        #expect(list.groupChatList.map(\.chatId) == ["wr1"] && list.nextCursor == "c2")
        #expect(t.calls[0].body["limit"] as? Int == 50 && t.calls[0].body["status_filter"] as? Int == 0)
        let got = try c.groupGet(chatId: "wr1")
        #expect(got.groupChat.name == "imctl测试群" && got.groupChat.memberList?.count == 2 && got.groupChat.memberList?[1].type == 2)
        #expect(t.calls[1].body["chat_id"] as? String == "wr1" && t.calls[1].body["need_name"] as? Int == 1)
    }

    @Test func joinWayContactWayWelcomeRemarkAndBroadcastPaths() throws {
        let t = RecordingTransport()
        t.script["externalcontact/groupchat/add_join_way"] = (200, #"{"errcode":0,"errmsg":"ok","config_id":"cfg1"}"#)
        t.script["externalcontact/groupchat/get_join_way"] = (200, #"{"errcode":0,"errmsg":"ok","join_way":{"config_id":"cfg1","scene":2,"auto_create_room":1,"room_base_name":"imctl群","room_base_id":1,"chat_id_list":["wr1"],"qr_code":"https://q/x","state":"ch1"}}"#)
        t.script["externalcontact/add_contact_way"] = (200, #"{"errcode":0,"errmsg":"ok","config_id":"cw1","qr_code":"https://q/y"}"#)
        t.script["externalcontact/add_msg_template"] = (200, #"{"errcode":0,"errmsg":"ok","fail_list":[],"msgid":"msg1"}"#)
        t.script["externalcontact/get_groupmsg_task"] = (200, #"{"errcode":0,"errmsg":"ok","task_list":[{"userid":"u1","status":2,"send_time":5}],"next_cursor":""}"#)
        let c = WeComAPIClient(transport: t)
        let jw = try c.joinWayCreate(JoinWayRequest(scene: 2, remark: "r", autoCreateRoom: 1, roomBaseName: "imctl群", roomBaseId: 1, chatIdList: ["wr1"], state: "ch1"))
        #expect(jw.configId == "cfg1" && t.calls.last?.body["chat_id_list"] as? [String] == ["wr1"] && t.calls.last?.body["auto_create_room"] as? Int == 1)
        #expect(try c.joinWayGet(configId: "cfg1").joinWay.qrCode == "https://q/x")
        try c.joinWayUpdate(JoinWayRequest(configId: "cfg1", scene: 2, remark: nil, autoCreateRoom: 1, roomBaseName: "imctl群", roomBaseId: 1, chatIdList: ["wr1", "wr2"], state: "ch1"))
        #expect(t.calls.last?.path == "externalcontact/groupchat/update_join_way" && t.calls.last?.body["config_id"] as? String == "cfg1")
        try c.joinWayDelete(configId: "cfg1")
        #expect(t.calls.last?.path == "externalcontact/groupchat/del_join_way")
        let cw = try c.contactWayCreate(ContactWayRequest(type: 1, scene: 2, remark: "r", skipVerify: true, state: "ch1", user: ["u1"], conclusions: nil))
        #expect(cw.configId == "cw1" && cw.qrCode == "https://q/y" && t.calls.last?.body["skip_verify"] as? Bool == true)
        try c.sendWelcome(WelcomeRequest(welcomeCode: "wc1", text: WeComText(content: "hi"), attachments: [AnyJSON.object(["msgtype": .string("link"), "link": .object(["title": .string("群"), "url": .string("https://q/x")])])]))
        #expect(t.calls.last?.path == "externalcontact/send_welcome_msg" && (t.calls.last?.body["attachments"] as? [[String: Any]])?.first?["msgtype"] as? String == "link")
        try c.remark(RemarkRequest(userid: "u1", externalUserid: "wm1", remark: "小明·a1b2c3", description: nil))
        #expect(t.calls.last?.body["external_userid"] as? String == "wm1")
        let b = try c.addMsgTemplate(MsgTemplateRequest(chatType: "group", externalUserid: nil, chatIdList: ["wr1"], sender: "u1", allowSelect: false, text: WeComText(content: "公告"), attachments: nil))
        #expect(b.msgid == "msg1" && t.calls.last?.body["chat_type"] as? String == "group")
        #expect(try c.groupMsgTask(msgid: "msg1", cursor: nil, limit: nil).taskList?.first?.status == 2)
    }

    @Test func errorsMapToProxyOrWecomCodes() throws {
        let t = RecordingTransport()
        t.script["a"] = (401, "nope")
        t.script["b"] = (200, #"{"errcode":40014,"errmsg":"invalid access_token"}"#)
        t.script["c"] = (200, "not json")
        t.script["d"] = (502, "")
        let c = WeComAPIClient(transport: t)
        #expect(throws: ControlError.proxy("proxy rejected the token (HTTP 401)")) { try c.call("a", EmptyRequest(), as: WeComEnvelope.self) }
        #expect(throws: ControlError.wecomAPI(errcode: 40014, errmsg: "invalid access_token")) { try c.call("b", EmptyRequest(), as: WeComEnvelope.self) }
        #expect(throws: ControlError.self) { try c.call("c", EmptyRequest(), as: WeComEnvelope.self) }
        #expect(throws: ControlError.proxy("proxy HTTP 502")) { try c.call("d", EmptyRequest(), as: WeComEnvelope.self) }
    }
}

import Foundation

// WeCom request/response shapes for the interfaces imctl uses. Field names
// are the official snake_case ones mapped through the client's snake-case
// coding strategies; everything optional in the response is optional here so
// a platform-side field change never breaks decoding.

/// Standard envelope every WeCom response carries.
public struct WeComEnvelope: Codable, Equatable {
    public var errcode: Int
    public var errmsg: String?
}

public struct EmptyRequest: Codable {
    public init() {}
}

// MARK: groupchat/list, groupchat/get

public struct GroupListRequest: Codable {
    public var statusFilter: Int?
    public var ownerFilter: OwnerFilter?
    public var cursor: String?
    public var limit: Int?
    public init(statusFilter: Int? = nil, ownerFilter: OwnerFilter? = nil, cursor: String? = nil, limit: Int? = nil) {
        self.statusFilter = statusFilter; self.ownerFilter = ownerFilter; self.cursor = cursor; self.limit = limit
    }
}

public struct OwnerFilter: Codable {
    public var useridList: [String]
    public init(useridList: [String]) { self.useridList = useridList }
}

public struct GroupListResponse: Codable {
    public var groupChatList: [GroupSummary]
    public var nextCursor: String?
}

public struct GroupSummary: Codable, Equatable {
    public var chatId: String
    public var status: Int?
}

public struct GroupGetRequest: Codable {
    public var chatId: String
    public var needName: Int
}

public struct GroupGetResponse: Codable {
    public var groupChat: GroupChat
}

public struct GroupChat: Codable {
    public var chatId: String
    public var name: String?
    public var owner: String?
    public var createTime: Int64?
    public var notice: String?
    public var memberList: [GroupMember]?
    public var memberVersion: String?
}

public struct GroupMember: Codable {
    public var userid: String
    public var type: Int?
    public var joinTime: Int64?
    public var joinScene: Int?
    public var groupNickname: String?
    public var name: String?
    public var unionid: String?
}

// MARK: groupchat/add_join_way, get_join_way, update_join_way, del_join_way

public struct JoinWayRequest: Codable {
    public var configId: String?
    public var scene: Int
    public var remark: String?
    public var autoCreateRoom: Int?
    public var roomBaseName: String?
    public var roomBaseId: Int?
    public var chatIdList: [String]?
    public var state: String?
    public init(configId: String? = nil, scene: Int, remark: String?, autoCreateRoom: Int?, roomBaseName: String?, roomBaseId: Int?,
                chatIdList: [String]?, state: String?) {
        self.configId = configId; self.scene = scene; self.remark = remark; self.autoCreateRoom = autoCreateRoom
        self.roomBaseName = roomBaseName; self.roomBaseId = roomBaseId; self.chatIdList = chatIdList; self.state = state
    }
}

public struct JoinWayCreateResponse: Codable {
    public var configId: String
}

public struct JoinWayGetResponse: Codable {
    public var joinWay: JoinWay
}

public struct JoinWay: Codable {
    public var configId: String
    public var scene: Int?
    public var remark: String?
    public var autoCreateRoom: Int?
    public var roomBaseName: String?
    public var roomBaseId: Int?
    public var chatIdList: [String]?
    public var qrCode: String?
    public var state: String?
}

public struct ConfigIdRequest: Codable {
    public var configId: String
    public init(configId: String) { self.configId = configId }
}

// MARK: add_contact_way, list_contact_way, get_contact_way, update_contact_way, del_contact_way

public struct ContactWayRequest: Codable {
    public var configId: String?
    public var type: Int?
    public var scene: Int?
    public var style: Int?
    public var remark: String?
    public var skipVerify: Bool?
    public var state: String?
    public var user: [String]?
    public var party: [Int]?
    public var isTemp: Bool?
    public var expiresIn: Int?
    public var chatExpiresIn: Int?
    public var unionid: String?
    public var conclusions: Conclusions?
    public init(configId: String? = nil, type: Int?, scene: Int?, remark: String?, skipVerify: Bool?, state: String?, user: [String]?,
                conclusions: Conclusions?, style: Int? = nil, party: [Int]? = nil, isTemp: Bool? = nil, expiresIn: Int? = nil,
                chatExpiresIn: Int? = nil, unionid: String? = nil) {
        self.configId = configId; self.type = type; self.scene = scene; self.style = style; self.remark = remark; self.skipVerify = skipVerify
        self.state = state; self.user = user; self.party = party; self.isTemp = isTemp; self.expiresIn = expiresIn
        self.chatExpiresIn = chatExpiresIn; self.unionid = unionid; self.conclusions = conclusions
    }
}

public struct Conclusions: Codable {
    public var text: WeComText?
    public init(text: WeComText?) { self.text = text }
}

public struct WeComText: Codable, Equatable {
    public var content: String
    public init(content: String) { self.content = content }
}

public struct ContactWayCreateResponse: Codable {
    public var configId: String
    public var qrCode: String?
}

public struct ContactWayListRequest: Codable {
    public var startTime: Int64?
    public var endTime: Int64?
    public var cursor: String?
    public var limit: Int?
    public init(startTime: Int64? = nil, endTime: Int64? = nil, cursor: String? = nil, limit: Int? = nil) {
        self.startTime = startTime; self.endTime = endTime; self.cursor = cursor; self.limit = limit
    }
}

public struct ContactWayListResponse: Codable {
    public var contactWay: [ContactWayRef]?
    public var nextCursor: String?
}

public struct ContactWayRef: Codable {
    public var configId: String
}

public struct ContactWayGetResponse: Codable {
    public var contactWay: ContactWay
}

public struct ContactWay: Codable {
    public var configId: String
    public var type: Int?
    public var scene: Int?
    public var style: Int?
    public var remark: String?
    public var skipVerify: Bool?
    public var state: String?
    public var qrCode: String?
    public var user: [String]?
    public var party: [Int]?
    public var isTemp: Bool?
    public var expiresIn: Int?
    public var chatExpiresIn: Int?
    public var conclusions: Conclusions?
}

// MARK: send_welcome_msg, remark, add_msg_template, get_groupmsg_task, get_groupmsg_send_result

public struct WelcomeRequest: Codable {
    public var welcomeCode: String
    public var text: WeComText?
    public var attachments: [AnyJSON]?
    public init(welcomeCode: String, text: WeComText?, attachments: [AnyJSON]?) {
        self.welcomeCode = welcomeCode; self.text = text; self.attachments = attachments
    }
}

public struct RemarkRequest: Codable {
    public var userid: String
    public var externalUserid: String
    public var remark: String?
    public var description: String?
    public init(userid: String, externalUserid: String, remark: String?, description: String?) {
        self.userid = userid; self.externalUserid = externalUserid; self.remark = remark; self.description = description
    }
}

public struct MsgTemplateRequest: Codable {
    public var chatType: String
    public var externalUserid: [String]?
    public var chatIdList: [String]?
    public var sender: String?
    public var allowSelect: Bool?
    public var text: WeComText?
    public var attachments: [AnyJSON]?
    public init(chatType: String, externalUserid: [String]?, chatIdList: [String]?, sender: String?, allowSelect: Bool?,
                text: WeComText?, attachments: [AnyJSON]?) {
        self.chatType = chatType; self.externalUserid = externalUserid; self.chatIdList = chatIdList; self.sender = sender
        self.allowSelect = allowSelect; self.text = text; self.attachments = attachments
    }
}

public struct MsgTemplateResponse: Codable {
    public var failList: [String]?
    public var msgid: String?
}

public struct GroupMsgTaskRequest: Codable {
    public var msgid: String
    public var cursor: String?
    public var limit: Int?
}

public struct GroupMsgTaskResponse: Codable {
    public var taskList: [GroupMsgTask]?
    public var nextCursor: String?
}

public struct GroupMsgTask: Codable {
    public var userid: String
    public var status: Int?
    public var sendTime: Int64?
}

public struct GroupMsgSendResultRequest: Codable {
    public var msgid: String
    public var userid: String
    public var cursor: String?
    public var limit: Int?
}

public struct GroupMsgSendResultResponse: Codable {
    public var sendList: [GroupMsgSendResult]?
    public var nextCursor: String?
}

public struct GroupMsgSendResult: Codable {
    public var externalUserid: String?
    public var chatId: String?
    public var userid: String?
    public var status: Int?
    public var sendTime: Int64?
}

import Foundation

// Wire parameters of the protocol's API methods (camelCase, as Java sends
// them). Decoded with a plain JSONDecoder; unknown keys are ignored.

struct GroupListParams: Decodable {
    var cursor: String?
    var limit: Int?
    var statusFilter: Int?
    var syncNames: Bool?
}

struct GroupGetParams: Decodable {
    var chatId: String
}

struct JoinwayCreateParams: Decodable {
    var chatIds: [String]
    var remark: String?
    var autoCreateRoom: Bool?
    var roomBaseName: String?
    var roomBaseId: Int?
    var state: String?
}

struct JoinwayUpdateParams: Decodable {
    var configId: String
    var chatIds: [String]?
    var remark: String?
    var autoCreateRoom: Bool?
    var roomBaseName: String?
    var roomBaseId: Int?
    var state: String?
}

struct ConfigIdParams: Decodable {
    var configId: String
}

struct ContactWayCreateParams: Decodable {
    var type: Int?
    var scene: Int?
    var remark: String?
    var skipVerify: Bool?
    var state: String?
    var users: [String]?
    var conclusionText: String?
}

struct ContactWayListParams: Decodable {
    var cursor: String?
    var limit: Int?
}

struct ContactWayUpdateParams: Decodable {
    var configId: String
    var remark: String?
    var skipVerify: Bool?
    var state: String?
    var users: [String]?
    var conclusionText: String?
}

struct WelcomeSendParams: Decodable {
    var welcomeCode: String
    var text: String?
    var attachments: [AnyJSON]?
}

struct RemarkSetParams: Decodable {
    var userid: String
    var externalUserId: String
    var remark: String
    var description: String?
}

struct BroadcastCreateParams: Decodable {
    var chatIds: [String]?
    var externalUserIds: [String]?
    var sender: String?
    var text: String
    var attachments: [AnyJSON]?
    var allowSelect: Bool?
    var idempotencyKey: String?
}

struct BroadcastRefParams: Decodable {
    var msgid: String
    var userid: String?
    var cursor: String?
    var limit: Int?
}

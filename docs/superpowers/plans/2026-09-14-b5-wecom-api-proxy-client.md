# 批次 B5：`WeComAPI`（经令牌注入代理的企微官方接口客户端）与 API 路线命令 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 imctl 通过云端令牌注入代理调用企微官方接口（群列表/详情、群活码、联系我、欢迎语、客户备注、企业群发），把结果写进本地身份桥表，并把这些能力作为协议方法 `group.*` / `contact.*` / `broadcast.*` 暴露给 Java；`broadcast.confirm` 是同一流程里的桌面 UI 步骤（AX 按"群发助手"的发送按钮，探针不可达即 `UNSUPPORTED`）。

**Architecture:** 新 SwiftPM 库 `WeComAPI`（只依赖 `ControlCore` 与 Foundation）：`WeComProxySettings`（本地 0600 文件：代理地址 + Bearer token，secret 永不落本机）→ `WeComTransport`（协议；`URLSessionWeComTransport` 同步 POST `{base}/wecom/{path}`）→ `WeComAPIClient`（企微信封 `errcode/errmsg` 解码与错误映射、每个接口一个类型化方法）→ `WeComAPIHandler`（实现 `ControlCore.APICommandHandler`，把协议参数映射到接口调用并回写身份桥；`broadcast.confirm` 委托给适配器注入的闭包）。`CommandExecutor` 新增 `apiHandler` 并把 API 类方法路由过去（未配置 → `UNSUPPORTED`）。适配器新增 `WeComActions.confirmBroadcast`（纯 AXPress，策略 `confirmBroadcast`）。CLI `imctl wecom enroll|status|call|sync-groups`。测试用 `URLProtocol` 伪代理验证传输层、用记录式 `WeComTransport` 验证客户端与处理器。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，swift-testing，Foundation `URLSession` + `URLProtocol`，GRDB（身份桥表已在 B4）。

## Global Constraints

- 代理参数（corpid / secret / agentid / 回调 Token / EncodingAESKey）只在代理环境变量；本机只存代理地址与 Bearer token（`~/Library/Application Support/imctl/wecom-proxy.json`，0600），token 不进日志、`describe`、状态文件、仓库、wiki。
- 白名单与策略不变：API 方法不改变桌面客户端状态（`broadcast.confirm` 除外，它经 `ActionPolicy` 的 `confirmBroadcast` 启用位，且只 `AXPress`）；不新增合成输入；`ForbiddenAPITests` 继续拦截。
- 本批**不部署代理、不调真实企微接口、不建群、不群发、不发欢迎语**：没有自建应用参数与代理主机；所有 API 路径只在伪代理上跑。
- `broadcast.create` 需 `idempotencyKey`（会产生群发任务）；同键回放既有结果。API 方法不受 `api/local_guard/system` 暂停影响（它们不碰客户端），文档写明。
- 协议：`RPCMethod` 从 10 个增到 26 个，`tools/list` 从 11 增到 27（含 `event.replay`）；`ProtocolTests` / `DispatcherTests` 同步。
- 工作方式（用户约定）：批量实现，最后一次 `swift test`。

---

### Task 1: 协议扩展（`RPCMethod` 16 个 API 方法、`APICommandHandler`、`ControlError` 三个新码）与执行器路由

**Files:**
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`
- Create: `Sources/ControlCore/Executor/APICommandHandler.swift`
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`
- Modify: `Sources/ControlCore/Policy/ActionKind.swift`（`confirmBroadcast`）
- Test: `Tests/ControlCoreTests/ProtocolTests.swift`、`Tests/ControlCoreTests/CommandExecutorTests.swift`（追加）

**Interfaces:**
- `RPCMethod` 新 case：`groupList "group.list"`、`groupGet "group.get"`、`groupJoinwayCreate|Get|Update|Delete "group.joinway.create|get|update|delete"`、`contactWayCreate|List|Get|Update|Delete "contact.way.create|list|get|update|delete"`、`contactWelcomeSend "contact.welcome.send"`、`contactRemarkSet "contact.remark.set"`、`broadcastCreate|Confirm|Get "broadcast.create|confirm|get"`；`requiresIdempotencyKey` = `messageSend || broadcastCreate`；`var isWeComAPI: Bool`
- `ControlError.unsupported(String)` → `UNSUPPORTED`；`.wecomAPI(errcode: Int, errmsg: String)` → `WECOM_API`；`.proxy(String)` → `PROXY_ERROR`
- `public protocol APICommandHandler { func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String }`（返回结果 JSON）
- `CommandExecutor.apiHandler: APICommandHandler?`（可后置注入）；API 方法路由；nil → `UNSUPPORTED`
- `ActionKind.confirmBroadcast`（`requiresTarget == false`）

- [ ] **Step 1: 失败测试**

```swift
// ProtocolTests 追加
    @Test func wecomApiMethodsAreRoutedSeparately() {
        #expect(RPCMethod.allCases.count == 26)
        #expect(RPCMethod.allCases.filter(\.requiresIdempotencyKey) == [.messageSend, .broadcastCreate])
        #expect(RPCMethod.allCases.filter(\.isWeComAPI).count == 16)
        #expect(RPCMethod(rawValue: "group.joinway.create") == .groupJoinwayCreate && RPCMethod.broadcastConfirm.isWeComAPI)
        #expect(!RPCMethod.messageSend.isWeComAPI)
        #expect(ControlError.unsupported("x").code == "UNSUPPORTED" && ControlError.wecomAPI(errcode: 40014, errmsg: "invalid token").code == "WECOM_API")
        #expect(ControlError.wecomAPI(errcode: 40014, errmsg: "invalid token").message == "wecom errcode 40014: invalid token")
        #expect(ControlError.proxy("down").code == "PROXY_ERROR")
        #expect(!ActionKind.confirmBroadcast.requiresTarget)
    }

// CommandExecutorTests 追加
final class FakeAPIHandler: APICommandHandler {
    var calls: [(RPCMethod, String)] = []
    var result = #"{"chatId":"wr1"}"#
    func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String { calls.append((method, paramsJSON)); return result }
}

    @Test func apiMethodsGoToTheApiHandlerAndAreUnsupportedWithoutOne() throws {
        let (exec, handler, _) = try make()
        let none = try exec.submit(method: .groupGet, paramsJSON: #"{"chatId":"wr1"}"#, idempotencyKey: nil)
        #expect(none.state == .failed && none.errorCode == "UNSUPPORTED")
        let api = FakeAPIHandler()
        exec.apiHandler = api
        let got = try exec.submit(method: .groupGet, paramsJSON: #"{"chatId":"wr1"}"#, idempotencyKey: nil)
        #expect(got.state == .succeeded && got.resultJSON == #"{"chatId":"wr1"}"# && api.calls.count == 1 && api.calls[0].0 == .groupGet)
        #expect(handler.sendCalls == 0)
        #expect(throws: ControlError.invalidParams("broadcast.create requires idempotencyKey")) {
            try exec.submit(method: .broadcastCreate, paramsJSON: "{}", idempotencyKey: nil)
        }
        let b1 = try exec.submit(method: .broadcastCreate, paramsJSON: #"{"text":"hi","idempotencyKey":"b1"}"#, idempotencyKey: "b1")
        let b2 = try exec.submit(method: .broadcastCreate, paramsJSON: #"{"text":"hi","idempotencyKey":"b1"}"#, idempotencyKey: "b1")
        #expect(b1.id == b2.id && api.calls.count == 2)
        // pause does not gate API methods
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        #expect(try exec.submit(method: .groupList, paramsJSON: "{}", idempotencyKey: nil).state == .succeeded)
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`RPCTypes.swift` 的 `RPCMethod` 追加 16 个 case 与：

```swift
    /// Methods that change client or platform state and therefore need an idempotency key.
    public var requiresIdempotencyKey: Bool { self == .messageSend || self == .broadcastCreate }

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
```

`ControlError` 追加 `case unsupported(String)`、`case wecomAPI(errcode: Int, errmsg: String)`、`case proxy(String)`；`code`：`UNSUPPORTED` / `WECOM_API` / `PROXY_ERROR`；`message`：`why` / `"wecom errcode \(errcode): \(errmsg)"` / `why`。

```swift
// Sources/ControlCore/Executor/APICommandHandler.swift
/// Platform work behind the official-API methods (`group.*`, `contact.*`,
/// `broadcast.*`). Returns the result JSON; throws `ControlError` for
/// protocol-level failures. Implemented by `WeComAPI`; faked in tests.
public protocol APICommandHandler {
    func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String
}
```

`CommandExecutor`：`public var apiHandler: APICommandHandler?`；`execute` 里在 `switch method` 前加：

```swift
        if method.isWeComAPI {
            guard let api = apiHandler else {
                throw ControlError.unsupported("WeCom API route not configured on this controller (imctl wecom enroll)")
            }
            return (.succeeded, try api.handleAPI(method: method, paramsJSON: paramsJSON))
        }
```
并让 `switch` 的 16 个 API case 落到 `default`（或 `case ... : fatalError`）——用 `default: throw ControlError.internalError("unrouted method")`。

`ActionKind` 加 `case confirmBroadcast`（文档：只 `AXPress` 群发助手的发送按钮），`requiresTarget` 返回 false。

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(core): WeCom API methods (group/contact/broadcast), APICommandHandler routing, UNSUPPORTED/WECOM_API/PROXY_ERROR`

---

### Task 2: `WeComAPI` target：设置文件、传输、客户端与模型

**Files:**
- Modify: `Package.swift`（`.library("WeComAPI")`、`.target("WeComAPI", dependencies: ["ControlCore"])`、`.testTarget("WeComAPITests")`；`imctld` 与 `imctl` 依赖 `WeComAPI`）
- Create: `Sources/WeComAPI/WeComProxySettings.swift`、`WeComTransport.swift`、`WeComAPIClient.swift`、`WeComModels.swift`、`AnyJSON.swift`
- Test: `Tests/WeComAPITests/FakeProxy.swift`、`Tests/WeComAPITests/WeComTransportTests.swift`、`Tests/WeComAPITests/WeComAPIClientTests.swift`、`Tests/WeComAPITests/WeComProxySettingsTests.swift`

**Interfaces:**
```swift
public struct WeComProxySettings: Codable, Equatable { baseURL, token: String; corpId: String?; agentId: Int?; timeoutSeconds: Double }
  static let fileName = "wecom-proxy.json"; static var defaultURL: URL; static func load(from:) throws; func save(to:) throws (0700/0600); var summary: String  // never the token
public struct ProxyResponse { status: Int; body: Data }
public protocol WeComTransport { func post(path: String, body: Data) throws -> ProxyResponse }
public final class URLSessionWeComTransport: WeComTransport { init(settings:, session: URLSession = .shared) }   // POST {base}/wecom/{path}, Authorization: Bearer, JSON
public struct WeComAPIClient { init(transport:); func call<Req: Encodable, Res: Decodable>(_ path: String, _ req: Req, as: Res.Type) throws -> Res; 16 typed methods }
```
错误映射：传输错误 / 无 HTTP 响应 / 非 2xx → `ControlError.proxy`（401/403 文案 "proxy rejected the token"）；信封 `errcode != 0` → `ControlError.wecomAPI`；解码失败 → `ControlError.proxy("cannot decode …")`。企微 JSON 用 snake_case 编解码策略（`chat_id_list` ↔ `chatIdList`）。

- [ ] **Step 1: 失败测试**

```swift
// Tests/WeComAPITests/FakeProxy.swift
import Foundation

/// URLProtocol that plays the token-injecting proxy: records every request
/// (path, Authorization header, JSON body) and answers from `respond`.
final class FakeProxyProtocol: URLProtocol {
    struct Seen { var path: String; var authorization: String?; var body: [String: Any] }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var respond: (String) -> (Int, String) = { _ in (200, #"{"errcode":0,"errmsg":"ok"}"#) }

    static func reset() { seen = []; respond = { _ in (200, #"{"errcode":0,"errmsg":"ok"}"#) } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProxyProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let bodyData = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        Self.seen.append(Seen(path: path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let (status, text) = Self.respond(path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

```swift
// Tests/WeComAPITests/WeComTransportTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

@Suite("URLSessionWeComTransport through a URLProtocol proxy", .serialized)
struct WeComTransportTests {
    func transport() -> URLSessionWeComTransport {
        URLSessionWeComTransport(settings: WeComProxySettings(baseURL: "https://proxy.example.test", token: "t0k3n", corpId: "wwtest"),
                                 session: FakeProxyProtocol.session())
    }

    @Test func postsJsonWithBearerUnderTheWecomPrefix() throws {
        FakeProxyProtocol.reset()
        let r = try transport().post(path: "externalcontact/groupchat/list", body: Data(#"{"limit":10}"#.utf8))
        #expect(r.status == 200 && String(decoding: r.body, as: UTF8.self).contains("\"errcode\":0"))
        let seen = try #require(FakeProxyProtocol.seen.first)
        #expect(seen.path == "/wecom/externalcontact/groupchat/list" && seen.authorization == "Bearer t0k3n" && seen.body["limit"] as? Int == 10)
    }

    @Test func statusCodesArePassedThroughForTheClientToMap() throws {
        FakeProxyProtocol.reset()
        FakeProxyProtocol.respond = { _ in (401, #"{"error":"bad token"}"#) }
        #expect(try transport().post(path: "x", body: Data()).status == 401)
    }
}
```

```swift
// Tests/WeComAPITests/WeComAPIClientTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

/// Records requests and answers from a script, no URL machinery.
final class RecordingTransport: WeComTransport {
    var calls: [(path: String, body: [String: Any])] = []
    var script: [String: (Int, String)] = [:]
    var fallback: (Int, String) = (200, #"{"errcode":0,"errmsg":"ok"}"#)
    func post(path: String, body: Data) throws -> ProxyResponse {
        calls.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
        let (status, text) = script[path] ?? fallback
        return ProxyResponse(status: status, body: Data(text.utf8))
    }
}

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
        #expect(try c.groupMsgTask(msgid: "msg1", cursor: nil, limit: nil).taskList.first?.status == 2)
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
```

```swift
// Tests/WeComAPITests/WeComProxySettingsTests.swift
import Foundation
import Testing
@testable import WeComAPI

@Suite("WeComProxySettings")
struct WeComProxySettingsTests {
    @Test func savesPrivatelyAndSummaryHidesTheToken() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-wecom-\(UUID().uuidString)/wecom-proxy.json")
        let s = WeComProxySettings(baseURL: "https://proxy.example.test/", token: "secret-token", corpId: "wwx", agentId: 1000002)
        try s.save(to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        let back = try WeComProxySettings.load(from: url)
        #expect(back == s && !back.summary.contains("secret-token") && back.summary.contains("wwx"))
        #expect(back.normalizedBaseURL.absoluteString == "https://proxy.example.test")
        #expect(WeComProxySettings.defaultURL.path.hasSuffix("/imctl/wecom-proxy.json"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → **Step 3: 实现**（`Package.swift` 与四个源文件；模型见 `WeComModels.swift`，请求类型有可选字段以便省略）→ **Step 4: 通过**
- [ ] **Step 5: Commit** `feat(wecom-api): proxy settings (0600), URLSession transport with Bearer, typed client for groupchat/join-way/contact-way/welcome/remark/msg-template`

---

### Task 3: `WeComAPIHandler`（协议参数 → 接口调用 → 身份桥回写；`broadcast.confirm` 委托）

**Files:**
- Create: `Sources/WeComAPI/WeComAPIHandler.swift`、`Sources/WeComAPI/APIParams.swift`
- Test: `Tests/WeComAPITests/WeComAPIHandlerTests.swift`

**Interfaces:**
```swift
public protocol IdentityWriter { func upsertIdentity(kind: IdentityKind, id: String, title: String, nowMs: Int64) throws }
extension ControlStore: IdentityWriter {}
public final class WeComAPIHandler: APICommandHandler {
    public init(client: WeComAPIClient, identities: IdentityWriter?, now: @escaping () -> Int64 = Clock.nowMs)
    public var confirmBroadcast: ((String) throws -> [String: String])?
    public func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String
    public func syncGroups(pageLimit: Int = 100, statusFilter: Int = 0) throws -> [(chatId: String, name: String)]   // group.list 分页 + group.get，回写 group 身份
}
```
协议参数（camelCase wire）：`group.list{cursor?, limit?, statusFilter?, syncNames?}`；`group.get{chatId}`；`group.joinway.create{chatIds, remark?, autoCreateRoom?, roomBaseName?, roomBaseId?, state?}`；`group.joinway.get|delete{configId}`；`group.joinway.update{configId, chatIds?, remark?, autoCreateRoom?, roomBaseName?, roomBaseId?, state?}`；`contact.way.create{type?, scene?, remark?, skipVerify?, state?, users?, conclusionText?}`；`contact.way.list{cursor?, limit?}`；`contact.way.get|delete{configId}`；`contact.way.update{configId, remark?, skipVerify?, state?, users?, conclusionText?}`；`contact.welcome.send{welcomeCode, text?, attachments?}`；`contact.remark.set{userid, externalUserId, remark, description?}`；`broadcast.create{chatIds?, externalUserIds?, sender?, text, attachments?, idempotencyKey}`；`broadcast.confirm{msgid}`；`broadcast.get{msgid, userid?, cursor?, limit?}`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/WeComAPITests/WeComAPIHandlerTests.swift
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
        let t = RecordingTransport(); let ids = MemoryIdentities()
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
        var page = 0
        t.script["externalcontact/groupchat/list"] = (200, "")   // replaced per call below
        let pages = [#"{"errcode":0,"errmsg":"ok","group_chat_list":[{"chat_id":"wr1","status":0}],"next_cursor":"n1"}"#,
                     #"{"errcode":0,"errmsg":"ok","group_chat_list":[{"chat_id":"wr2","status":0}],"next_cursor":""}"#]
        t.dynamic["externalcontact/groupchat/list"] = { _ in defer { page += 1 }; return (200, pages[min(page, 1)]) }
        t.dynamic["externalcontact/groupchat/get"] = { body in
            let id = body["chat_id"] as? String ?? ""
            return (200, #"{"errcode":0,"errmsg":"ok","group_chat":{"chat_id":"\#(id)","name":"群\#(id)"}}"#)
        }
        let synced = try h.syncGroups(pageLimit: 1)
        #expect(synced.map(\.chatId) == ["wr1", "wr2"] && ids.rows["wr2"]?.1 == "群wr2")
        page = 0
        let r = try json(try h.handleAPI(method: .groupList, paramsJSON: #"{"limit":1,"syncNames":false}"#))
        #expect((r["groups"] as? [[String: Any]])?.first?["chatId"] as? String == "wr1" && r["nextCursor"] as? String == "n1")
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
```
（`RecordingTransport` 加 `dynamic: [String: ([String: Any]) -> (Int, String)]`，优先于 `script`。）

- [ ] **Step 2 → 4**：实现 `APIParams.swift`（协议参数 Decodable）与 `WeComAPIHandler.swift`；结果 JSON 用 camelCase 键（`chatId`、`configId`、`qrCode`、`failList`、`nextCursor`、`groups`、`members`、`tasks`、`results`）。
- [ ] **Step 5: Commit** `feat(wecom-api): APICommandHandler mapping group/contact/broadcast methods, identity bridge fill, syncGroups`

---

### Task 4: `broadcast.confirm` 的 AX 探针（`WeComActions.confirmBroadcast`）与处理器桥接

**Files:**
- Create: `Sources/WeComAdapter/Actions/BroadcastConfirm.swift`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`（`confirmBroadcast(msgid:) -> [String: String]`）
- Test: `Tests/WeComAdapterTests/BroadcastConfirmTests.swift`

**Interfaces:**
- `extension WeComActions { public func confirmBroadcast(reader: WeComReader, msgid: String?) throws -> ActionOutcome }`：策略 `confirmBroadcast`；在主窗口子树、再在应用其它窗口里找"含 `群发` 的静态文本 + 看起来是发送的按钮"，`AXPress`，等按钮消失或禁用（`verifyTimeout`）→ `verified`；找不到 → `ActionError.actionUnavailable("群发助手 send button")`。
- `WeComCommandHandler.confirmBroadcast(msgid:)`：`mapErrors` 把 `actionUnavailable` 映射为 `ControlError.unsupported`。

- [ ] **Step 1: 失败测试**

```swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("broadcast.confirm AX probe on fake")
struct BroadcastConfirmTests {
    /// Main window plus a 群发助手 sheet: title text + a 发送 button.
    static func windowWithAssistant() -> AXNode {
        var window = GroupFixture.window()
        let sheet = AXNode(role: AXRole.group, frame: CGRect(x: 600, y: 300, width: 700, height: 500), children: [
            AXNode(role: AXRole.staticText, value: .string("群发助手"), frame: CGRect(x: 620, y: 310, width: 100, height: 20)),
            AXNode(role: AXRole.staticText, value: .string("待发送 1 条"), frame: CGRect(x: 620, y: 340, width: 200, height: 20)),
            AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 1200, y: 760, width: 80, height: 30), enabled: true, actions: [AXAction.press]),
        ])
        window.children[0].children.append(sheet)
        return window
    }

    @Test func pressesTheSendButtonAndVerifiesItWentAway() throws {
        let fake = FakeAXBackend(root: Self.windowWithAssistant())
        let reader = try WeComReader(window: fake.rootElement)
        let button = try #require(fake.handle(atPath: [0, 3, 2]))
        fake.reactions["action:AXPress"] = { fake.mutate(button, attribute: AXAttribute.enabled, to: .bool(false)) }
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        actions.verifyTimeout = 0.2; actions.verifyInterval = 0.02
        let out = try actions.confirmBroadcast(reader: reader, msgid: "msg1")
        #expect(out.verified && out.details["button"] == "发送" && out.details["msgid"] == "msg1")
        #expect(fake.recordedActions.map(\.action) == [AXAction.press] && fake.recordedSets.isEmpty)
    }

    @Test func missingAssistantIsUnsupportedAndPolicyGated() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast]))
        #expect(throws: ActionError.actionUnavailable("群发助手 send button")) { try actions.confirmBroadcast(reader: reader, msgid: nil) }
        #expect(throws: PolicyError.notEnabled(.confirmBroadcast)) {
            try WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"])).confirmBroadcast(reader: reader, msgid: nil)
        }
        #expect(fake.recordedActions.isEmpty)
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.confirmBroadcast], phase: .phase1),
                                    checkpoints: try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-bc-\(UUID().uuidString)")))
        #expect(throws: ControlError.unsupported("action 群发助手 send button unavailable")) { try h.confirmBroadcast(msgid: "m") }
    }
}
```

- [ ] **Step 2 → 4**：实现；`WeComCommandHandler.map(ActionError.actionUnavailable)` 改为 `.unsupported("action \(name) unavailable")`（原为 `clientUnavailable`；影响的既有测试断言按新码更新——`grep actionUnavailable Tests`）。
- [ ] **Step 5: Commit** `feat(adapter): broadcast.confirm AX probe (AXPress on the 群发助手 send button, UNSUPPORTED when absent)`

---

### Task 5: 守护进程与 CLI 接线、工具描述、契约文档

**Files:**
- Modify: `Sources/imctld/main.swift`（`--wecom-config`；文件存在即启用 API 路线；`confirmBroadcast` 闭包；策略 enabled 加 `.confirmBroadcast`）
- Create: `Sources/imctl/Commands/WeComCommand.swift`（`imctl wecom enroll|status|call|sync-groups`）
- Modify: `Sources/imctl/IMCTL.swift`、`Sources/MCPTransport/RPCDispatcher.swift`（16 个工具描述）、`Tests/MCPTransportTests/DispatcherTests.swift`（27）、`Tests/imctlTests/CommandParsingTests.swift`
- Create: `docs/protocol/wecom-token-proxy.md`；Modify: `docs/protocol/java-consumer.md`、`README.md`
- Test: `Tests/imctlTests/WeComCommandTests.swift`

- [ ] **Step 1: 失败测试**

```swift
// Tests/imctlTests/WeComCommandTests.swift
import Foundation
import Testing
@testable import imctl
@testable import WeComAPI

@Suite("imctl wecom")
struct WeComCommandTests {
    @Test func enrollWritesPrivateSettingsAndStatusHidesToken() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-wecom-cli-\(UUID().uuidString)/wecom-proxy.json").path
        try WeComEnrollCommand.parse(["--proxy", "https://proxy.example.test", "--token", "abc123", "--corp-id", "wwx", "--agent-id", "7", "--config", file]).run()
        let s = try WeComProxySettings.load(from: URL(fileURLWithPath: file))
        #expect(s.token == "abc123" && s.corpId == "wwx" && s.agentId == 7)
        let status = try WeComStatusCommand.parse(["--config", file]).collect()
        #expect(status["present"] as? Bool == true && (status["summary"] as? String)?.contains("abc123") == false)
        let sub = WeComCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["enroll", "status", "call", "sync-groups"])
    }
}
```
`CommandParsingTests` 根列表加 `"wecom"`；`DispatcherTests.initializeAndToolsList` 期望 27。

- [ ] **Step 2 → 4**：实现。`imctl wecom call <path> --body '{}'` 直接经 `URLSessionWeComTransport` 打代理并打印响应（联调用）；`sync-groups` 用 `WeComAPIHandler.syncGroups` 写 `--db`。
- [ ] **Step 5: Commit** `feat(cli,daemon): imctl wecom enroll/status/call/sync-groups; imctld enables the API route when wecom-proxy.json exists; tools/list 27; proxy contract doc`

---

### Task 6: 全量测试、门报告、提交推送

- [ ] `swift test`（期望 ≥ 182 + 本批新增，0 失败）
- [ ] `bash scripts/check-secrets.sh`（无新增命中）
- [ ] `docs/gates/2026-09-14-b5-wecom-api-client.md`：实现、单测数字、伪代理覆盖的接口清单、**未做**（真实代理/企微接口、建群、群发、欢迎语活体）、待用户事项（自建应用参数、代理主机与域名）
- [ ] Commit + push

## Self-review

- 规格覆盖：§2 `WeComAPI`（Task 2/3）、§3 方法清单 16 个（Task 1/3/5）、§4 身份桥回写（Task 3）、§7 群发 + AX 确认探针（Task 3/4）、§8 代理契约（Task 5 文档）、§10 伪代理单测（Task 2/3）。
- 占位扫描：无 TBD。
- 类型一致性：`WeComAPIClient.call(_:_:as:)`、`GroupListRequest(statusFilter:cursor:limit:)`、`JoinWayRequest(configId:scene:remark:autoCreateRoom:roomBaseName:roomBaseId:chatIdList:state:)`、`ContactWayRequest(type:scene:remark:skipVerify:state:user:conclusions:)`、`WelcomeRequest(welcomeCode:text:attachments:)`、`RemarkRequest(userid:externalUserid:remark:description:)`、`MsgTemplateRequest(chatType:externalUserid:chatIdList:sender:allowSelect:text:attachments:)`、`WeComAPIHandler(client:identities:now:)`、`confirmBroadcast(reader:msgid:)` 在各任务一致。

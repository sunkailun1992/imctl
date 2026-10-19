# 批次 B7：通讯录能力（好友列表、新客户请求与自动接受、接受后自动拉群、策略与控制台）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-09-15-contacts-requests-groups-design.md`（用户 2026-09-15 10:34 批准："按规格做，允许 ⌘2，测试联系人A 是我的测试号"；10:45 定拉群默认一人一群、可配默认成员、群名 = 客户名 + "群聊"）实现四个协议方法 `contact.list` / `contact.request.list` / `contact.request.accept` / `group.create`、三个事件、`policy.json.contactRequests` 策略、守护进程自动化循环、CLI 与控制台页。

**Architecture:** ControlCore 加方法 / 参数 / 事件 / 策略结构与执行器路由（含每小时接受上限、成功后写 `contact.request.accepted` / `group.created` 事件）。WeComAdapter 加三个纯解析器（`NewCustomersPage`、`GroupPickerSheet`、`RailBadges`）与动作（`openContacts` = 置前 + `⌘8` + `⌃Tab` 逐步校验、`returnToMessages` = 深链 `wxwork://conversationlist`、`acceptRequest`、`readContacts`、`createGroup`），处理器把它们绑到方法。imctld 加 `RequestAutomation`（角标触发的一轮：读卡片 → 发观察事件 → 按策略接受 → 自动拉群），策略热加载沿用 `PolicyProvider`。控制台加「通讯录」页与策略开关。全部按键只经 `KeystrokeInjector` 投递给企微 pid。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，swift-testing，`FakeAXBackend` 反应式夹具，SwiftUI（控制台）。

## Global Constraints

- 合成输入只在 `KeystrokeInjector.swift`：回车（已有）+ **`⌘1`–`⌘8` 与 `⌃Tab`（用户 10:34 批准）**，只 `postToPid`，`ForbiddenAPITests` 的禁令不变。
- 进入通讯录：`AXFrontmost` 置前 → `⌘8` → `⌃Tab` 直到窗口出现「新的客户」文字（≤ 6 步）→ 选中「新的客户」行；回消息视图只用深链。每个动作结束都回消息视图并把焦点还给之前的前台应用。
- 接受好友与建群默认全关（`autoAccept: off`、`autoGroup: off`）；远程只能在 `remote` 模式逐条接受；每小时接受上限（默认 20）在执行器硬拦。
- 活体只对 测试联系人A（用户本人测试号）做接受与建群；真实姓名只进本机日志与事件流；夹具脱敏。
- 协议文档与代码同一提交；`ProtocolDocTests` 兜底；`RPCMethod` 31、`tools/list` 32、`ControlEventKind` 8。
- 工作方式：批量实现，最后一次 `swift test`。

---

### Task 1: ControlCore——方法、参数、事件、策略、执行器

**Files:**
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`（`RPCMethod` +4、参数类型）
- Modify: `Sources/ControlCore/Protocol/ControlEvent.swift`（+3 事件）
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift`（+4 方法）
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`（暂停门、路由、接受上限、领域事件）
- Modify: `Sources/ControlCore/Policy/ActionKind.swift`（+4）
- Create: `Sources/ControlCore/Policy/ContactRequestPolicy.swift`；Modify: `Sources/ControlCore/Policy/SendPolicy.swift`（字段 + summary）
- Modify: `Sources/ControlCore/Store/ControlStore.swift`（`countCommands`）
- Test: `Tests/ControlCoreTests/ProtocolTests.swift`、`CommandExecutorTests.swift`、`SendPolicyTests.swift`、`ControlStoreTests.swift`；伪处理器补方法：`Tests/MCPTransportTests/DispatcherTests.swift`、`Tests/MQTTTransportTests/MQTTBindingTests.swift`、`Tests/imctl-consoleTests/RPCServiceTests.swift`

**Interfaces（后续任务依赖）:**
- `RPCMethod.contactList = "contact.list"`, `.contactRequestList = "contact.request.list"`, `.contactRequestAccept = "contact.request.accept"`, `.groupCreate = "group.create"`（声明在 `clientNavigate` 之后、`groupList` 之前）；`requiresIdempotencyKey` += `contactRequestAccept`, `groupCreate`；都不是 `isWeComAPI`
- `ContactListParams { limit: Int? }`、`ContactRequestAcceptParams { name: String; idempotencyKey: String }`、`GroupCreateParams { members: [String]; name: String?; idempotencyKey: String }`
- `CommandHandler`: `contactList(limit: Int) throws -> [[String: String]]`、`contactRequestList() throws -> [[String: String]]`、`contactRequestAccept(name: String) throws -> [String: String]`、`groupCreate(members: [String], name: String?) throws -> [String: String]`
- `ControlEventKind.contactRequestObserved = "contact.request.observed"`, `.contactRequestAccepted = "contact.request.accepted"`, `.groupCreated = "group.created"`
- `ActionKind.openContacts`, `.acceptRequest`, `.openGroupPicker`, `.createGroup`（`requiresTarget == false`）
- `ContactRequestPolicy { autoAccept: AcceptMode(off/all/rules/remote); allowNames: [String]; greetingContains: [String]; autoGroup: GroupMode(off/perPerson); groupDefaultMembers: [String]; groupNameSuffix: String = "群聊"; maxAcceptsPerHour: Int = 20 }`，`func decides(name:greeting:) -> Bool`，`func groupName(for customer: String) -> String`
- `SendPolicy.contactRequests: ContactRequestPolicy`（缺省 = 全关；旧文件无该键也能解码）；`summary` 末尾追加 ` requests=<mode>/<groupMode>`
- `ControlStore.countCommands(method: RPCMethod, state: CommandStateV1, sinceMs: Int64) throws -> Int`
- `CommandExecutor.acceptsPerHour: () -> Int = { 20 }`（守护进程从策略注入）；成功的 `contactRequestAccept` 追加事件 `contact.request.accepted{name, by, commandId}`（`by = idempotencyKey.hasPrefix("auto-") ? "policy" : "remote"`），成功的 `groupCreate` 追加 `group.created{title, memberCount, members, requestedName?}`

- [ ] **Step 1: 失败测试**

```swift
// ProtocolTests：27 → 31；idempotency 列表
        #expect(RPCMethod.allCases.count == 31)
        #expect(RPCMethod.allCases.filter(\.requiresIdempotencyKey) == [.messageSend, .clientNavigate, .contactRequestAccept, .groupCreate, .broadcastCreate])
    @Test func contactsMethodsEventsAndPolicy() throws {
        #expect(RPCMethod(rawValue: "contact.request.accept") == .contactRequestAccept && !RPCMethod.contactList.isWeComAPI && !RPCMethod.groupCreate.isWeComAPI)
        #expect(ControlEventKind.allCases.count == 8 && ControlEventKind.groupCreated.rawValue == "group.created")
        #expect(ActionKind.allCases.count == 12 && !ActionKind.createGroup.requiresTarget && !ActionKind.openContacts.requiresTarget)
        let p = try JSONDecoder().decode(GroupCreateParams.self, from: Data(#"{"members":["测试联系人A"],"idempotencyKey":"g1"}"#.utf8))
        #expect(p.members == ["测试联系人A"] && p.name == nil)
        var policy = ContactRequestPolicy()
        #expect(policy.autoAccept == .off && policy.autoGroup == .off && policy.maxAcceptsPerHour == 20 && policy.groupNameSuffix == "群聊")
        #expect(policy.groupName(for: "测试联系人A") == "测试联系人A群聊")
        policy.autoAccept = .rules; policy.allowNames = ["测试联系人A"]; policy.greetingContains = ["示例公司"]
        #expect(policy.decides(name: "测试联系人A", greeting: "") && policy.decides(name: "x", greeting: "我来自示例公司") && !policy.decides(name: "x", greeting: "hi"))
        policy.autoAccept = .all; #expect(policy.decides(name: "anyone", greeting: nil))
        policy.autoAccept = .remote; #expect(!policy.decides(name: "测试联系人A", greeting: nil))
    }

// SendPolicyTests 追加
    @Test func contactRequestsRoundTripAndDefaultForOldFiles() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data(#"{"allowedTitles":["a"],"allowedTypes":{"group":false,"customer":false,"internal":false},"allowedChatIds":[],"allowedExternalUserIds":[]}"#.utf8))
        #expect(old.contactRequests == ContactRequestPolicy() && old.summary.hasSuffix("requests=off/off"))
        var p = SendPolicy(); p.contactRequests.autoAccept = .rules; p.contactRequests.groupDefaultMembers = ["同事A"]; p.contactRequests.autoGroup = .perPerson
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SendPolicy.self, from: data)
        #expect(back.contactRequests.autoAccept == .rules && back.contactRequests.groupDefaultMembers == ["同事A"] && back.summary.hasSuffix("requests=rules/perPerson"))
    }

// ControlStoreTests 追加
    @Test func countsCommandsByMethodStateAndTime() throws {
        let store = try ControlStore(path: ":memory:")
        for (i, state) in [CommandStateV1.succeeded, .succeeded, .failed].enumerated() {
            let r = CommandRecord(method: .contactRequestAccept, paramsJSON: "{}", idempotencyKey: "a\(i)", nowMs: Int64(10 + i))
            _ = try store.insertCommand(r); try store.updateCommand(id: r.id, state: state, nowMs: Int64(20 + i))
        }
        #expect(try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: 0) == 2)
        #expect(try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: 21) == 1)
        #expect(try store.countCommands(method: .groupCreate, state: .succeeded, sinceMs: 0) == 0)
    }

// CommandExecutorTests：FakeHandler 追加
    var accepted: [String] = []
    var groups: [[String]] = []
    func contactList(limit: Int) throws -> [[String: String]] { [["name": "测试联系人A", "source": "wechat"]] }
    func contactRequestList() throws -> [[String: String]] { [["name": "测试联系人A", "greeting": "我是 测试联系人A", "source": "wechat", "status": "pending"]] }
    func contactRequestAccept(name: String) throws -> [String: String] { accepted.append(name); return ["name": name, "accepted": "true", "status": "added"] }
    func groupCreate(members: [String], name: String?) throws -> [String: String] {
        groups.append(members); return ["title": name ?? members.joined(separator: "、"), "memberCount": String(members.count + 1), "renamed": "false"]
    }
// CommandExecutorTests 追加
    @Test func acceptAndGroupCreateEmitDomainEventsAndAcceptsAreCapped() throws {
        let (exec, handler, store) = try make()
        exec.acceptsPerHour = { 2 }
        let a1 = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"测试联系人A","idempotencyKey":"auto-1"}"#, idempotencyKey: "auto-1")
        #expect(a1.state == .succeeded && handler.accepted == ["测试联系人A"])
        let accepted = try store.events(after: 0, limit: 50).filter { $0.kind == .contactRequestAccepted }
        #expect(accepted.count == 1 && accepted[0].payloadJSON.contains(#""by":"policy""#) && accepted[0].payloadJSON.contains(a1.id))
        _ = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"B","idempotencyKey":"r-2"}"#, idempotencyKey: "r-2")
        let third = try exec.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"C","idempotencyKey":"r-3"}"#, idempotencyKey: "r-3")
        #expect(third.state == .failed && third.errorCode == "RATE_LIMITED" && handler.accepted.count == 2)
        let g = try exec.submit(method: .groupCreate, paramsJSON: #"{"members":["测试联系人A"],"name":"测试联系人A群聊","idempotencyKey":"g1"}"#, idempotencyKey: "g1")
        #expect(g.state == .succeeded && handler.groups == [["测试联系人A"]])
        let created = try store.events(after: 0, limit: 50).filter { $0.kind == .groupCreated }
        #expect(created.count == 1 && created[0].payloadJSON.contains(#""requestedName":"测试联系人A群聊""#))
        #expect(throws: ControlError.invalidParams("group.create requires idempotencyKey")) {
            try exec.submit(method: .groupCreate, paramsJSON: #"{"members":["x"],"idempotencyKey":"g2"}"#, idempotencyKey: nil)
        }
        try store.setPause(.api, on: true, nowMs: 5)
        #expect(try exec.submit(method: .contactList, paramsJSON: "{}", idempotencyKey: nil).errorCode == "PAUSED")
    }
```

`DispatchFakeHandler` / `BindingFakeHandler` / `ConsoleFakeHandler` 各补同样四个方法（返回上面的固定值）。

- [ ] **Step 2: 编译确认失败**：`swift build --build-tests` → 未定义符号。

- [ ] **Step 3: 实现**

`RPCTypes.swift`：

```swift
    case clientNavigate = "client.navigate"
    // Contacts (通讯录 / picker sheet) route, B7: all UI, no platform API.
    case contactList = "contact.list"
    case contactRequestList = "contact.request.list"
    case contactRequestAccept = "contact.request.accept"
    case groupCreate = "group.create"
    …
    public var requiresIdempotencyKey: Bool {
        switch self {
        case .messageSend, .clientNavigate, .contactRequestAccept, .groupCreate, .broadcastCreate: return true
        default: return false
        }
    }

public struct ContactListParams: Codable, Equatable {
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
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
    public init(members: [String], name: String? = nil, idempotencyKey: String) { self.members = members; self.name = name; self.idempotencyKey = idempotencyKey }
}
```

`ControlEvent.swift`：`case contactRequestObserved = "contact.request.observed"`, `case contactRequestAccepted = "contact.request.accepted"`, `case groupCreated = "group.created"`。

`CommandHandler.swift`：

```swift
    /// Contacts the client lists under 我的客户 in the group picker (name, source, tag).
    func contactList(limit: Int) throws -> [[String: String]]
    /// Cards on 通讯录 › 新的客户: `status` pending (接受 button) or added (打招呼 button).
    func contactRequestList() throws -> [[String: String]]
    /// Presses 接受 on the unique pending card titled `name`.
    func contactRequestAccept(name: String) throws -> [String: String]
    /// Creates a group from the picker with `members` (+ policy defaults added by the caller); `name` is recorded, renaming is not attempted.
    func groupCreate(members: [String], name: String?) throws -> [String: String]
```

`ActionKind.swift`：`case openContacts`, `case acceptRequest`, `case openGroupPicker`, `case createGroup`；`requiresTarget` 的 `false` 分支加上它们。

`Policy/ContactRequestPolicy.swift`：

```swift
import Foundation

/// How the daemon treats 通讯录 › 新的客户 requests and what it does after
/// accepting one. Lives in policy.json (a human's local decision); default is
/// everything off. Java can only accept individually in `remote` mode.
public struct ContactRequestPolicy: Codable, Equatable {
    public enum AcceptMode: String, Codable, CaseIterable { case off, all, rules, remote }
    public enum GroupMode: String, Codable, CaseIterable { case off, perPerson }

    public var autoAccept: AcceptMode
    public var allowNames: [String]
    public var greetingContains: [String]
    public var autoGroup: GroupMode
    public var groupDefaultMembers: [String]
    public var groupNameSuffix: String
    public var maxAcceptsPerHour: Int

    public init(autoAccept: AcceptMode = .off, allowNames: [String] = [], greetingContains: [String] = [], autoGroup: GroupMode = .off,
                groupDefaultMembers: [String] = [], groupNameSuffix: String = "群聊", maxAcceptsPerHour: Int = 20) {
        self.autoAccept = autoAccept; self.allowNames = allowNames; self.greetingContains = greetingContains; self.autoGroup = autoGroup
        self.groupDefaultMembers = groupDefaultMembers; self.groupNameSuffix = groupNameSuffix; self.maxAcceptsPerHour = maxAcceptsPerHour
    }

    /// Whether the daemon itself accepts this request (`remote` and `off` never do).
    public func decides(name: String, greeting: String?) -> Bool {
        switch autoAccept {
        case .off, .remote: return false
        case .all: return true
        case .rules:
            if allowNames.contains(name) { return true }
            guard let greeting, !greeting.isEmpty else { return false }
            return greetingContains.contains { !$0.isEmpty && greeting.contains($0) }
        }
    }

    public func groupName(for customer: String) -> String { customer + groupNameSuffix }
    public var summary: String { "requests=\(autoAccept.rawValue)/\(autoGroup.rawValue)" }
}
```

`SendPolicy.swift`：字段 `public var contactRequests: ContactRequestPolicy`（init 默认 `ContactRequestPolicy()`）；自定义 `init(from:)`：`contactRequests = try c.decodeIfPresent(ContactRequestPolicy.self, forKey: .contactRequests) ?? ContactRequestPolicy()`（其余四个字段 `decodeIfPresent ?? 默认`）；`summary` 返回 `"titles=… externalUserIds=\(…) \(contactRequests.summary)"`。

`ControlStore.swift`：

```swift
    public func countCommands(method: RPCMethod, state: CommandStateV1, sinceMs: Int64) throws -> Int {
        try dbQueue.read { db in
            try CommandRecord.filter(Column("method") == method.rawValue).filter(Column("state") == state.rawValue)
                .filter(Column("updated_ms") >= sinceMs).fetchCount(db)
        }
    }
```

`CommandExecutor.swift`：属性 `public var acceptsPerHour: () -> Int = { 20 }`；暂停门 `if [.messageSend, .conversationRead, .clientNavigate, .contactList, .contactRequestList, .contactRequestAccept, .groupCreate].contains(method)`；在速率门之后加

```swift
        if method == .contactRequestAccept {
            let limit = acceptsPerHour()
            if try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: now() - 3_600_000) >= limit {
                let err = ControlError.rateLimited("\(limit) contact requests accepted in the last hour; limit \(limit)")
                return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
            }
        }
```

`execute` 分支：

```swift
        case .contactList:
            let p = (try? decode(ContactListParams.self, from: paramsJSON)) ?? ContactListParams()
            return (.succeeded, try encode(try handler.contactList(limit: p.limit ?? 200)))
        case .contactRequestList:
            return (.succeeded, try encode(try handler.contactRequestList()))
        case .contactRequestAccept:
            let p = try decode(ContactRequestAcceptParams.self, from: paramsJSON)
            let result = try handler.contactRequestAccept(name: p.name)
            var event = result; event["by"] = p.idempotencyKey.hasPrefix("auto-") ? "policy" : "remote"; event["commandId"] = record.id
            try store.appendEvent(kind: .contactRequestAccepted, payloadJSON: try encode(event), nowMs: now())
            return (.succeeded, try encode(result))
        case .groupCreate:
            let p = try decode(GroupCreateParams.self, from: paramsJSON)
            let result = try handler.groupCreate(members: p.members, name: p.name)
            var event = result; event["members"] = p.members.joined(separator: ","); event["commandId"] = record.id
            if let name = p.name { event["requestedName"] = name }
            try store.appendEvent(kind: .groupCreated, payloadJSON: try encode(event), nowMs: now())
            return (.succeeded, try encode(result))
```

- [ ] **Step 4: 编译检查** `swift build --build-tests`。

---

### Task 2: 按键、导航与角标（`KeystrokeInjector` 扩展、`ContactsView`、`RailBadges`、`openContacts` / `returnToMessages`）

**Files:**
- Modify: `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`
- Create: `Sources/WeComAdapter/Contacts/ContactsView.swift`（视图签名、选中「新的客户」）
- Create: `Sources/WeComAdapter/Contacts/RailBadges.swift`
- Create: `Sources/WeComAdapter/Actions/Contacts.swift`（`openContacts`、`returnToMessages`、`withContactsView`）
- Modify: `Sources/WeComAdapter/Actions/WeComActions.swift`（注入点 `postShortcut`、`openURL`）
- Modify: `Sources/WeComAdapter/Watch/WatchSnapshot.swift`（`contactRequestsPending`）、`WatchDiff.swift`（`.contactRequestsChanged`）、`WatchEngine.swift`（草稿 `controller.state{contactRequestsPending}`）
- Test: Create `Tests/WeComAdapterTests/ContactsNavigationTests.swift`；Modify `Tests/WeComAdapterTests/WatchDiffTests.swift`

**Interfaces:**
- `KeystrokeInjector.Shortcut { case commandDigit(Int) /* 1...8 */, controlTab, shiftControlTab }`；`static func postShortcut(_ s: Shortcut, toPid: pid_t) throws`
- `WeComContactsView.isShowing(window: AXElement) -> Bool`（窗口内有 `AXTextArea`/`AXStaticText` 值 `"新的客户"` 且有 `"添加成员..."` 或 `"智能机器人"`）；`static func selectNewCustomers(window:) throws`（找值为「新的客户」的行，父 `AXOutline`/`AXTable` 设 `AXSelectedRows`）；`static func newCustomersTable(window:) throws -> AXElement?`（x ≥ 400 且宽 ≥ 1000 的 `AXTable`，页头「新的客户」在其上方）
- `RailBadges.contactRequestsPending(window: AXElement) -> Int`（x < 0、`AXButton`、标题为整数、y ∈ 370…400；无则 0）
- `WeComActions.postShortcut: (KeystrokeInjector.Shortcut, pid_t) throws -> Void`、`WeComActions.openURL: (URL) -> Bool`（默认 `NSWorkspace.shared.open`）
- `WeComActions.openContacts(app: AXElement, window: AXElement) throws -> ActionOutcome`（details: `steps`），`returnToMessages(window:) throws -> ActionOutcome`
- `WatchSnapshot.contactRequestsPending: Int = 0`；`WatchEvent.contactRequestsChanged(from: Int, to: Int)`；`WatchEngine.contactRequestsPending`

- [ ] **Step 1: 失败测试**（`ContactsNavigationTests.swift`）

```swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

enum ContactsFixture {
    static func newCustomers() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json")))
    }
}

@Suite("Contacts navigation on fixtures")
struct ContactsNavigationTests {
    @Test func badgeAndContactsSignatureAreReadFromTheTree() throws {
        let contacts = try ContactsFixture.newCustomers()
        #expect(RailBadges.contactRequestsPending(window: contacts.rootElement) == 2)
        #expect(WeComContactsView.isShowing(window: contacts.rootElement))
        let messages = try Fixtures.mainWindow()
        #expect(RailBadges.contactRequestsPending(window: messages.rootElement) == 0)
        #expect(!WeComContactsView.isShowing(window: messages.rootElement))
        #expect(try WeComContactsView.newCustomersTable(window: contacts.rootElement) != nil)
    }

    @Test func openContactsPressesCommand8ThenControlTabUntilTheSignatureAppears() throws {
        // start on the 消息 fixture; the "client" switches to the contacts tree after ⌘8 + 2×⌃Tab
        let fake = try Fixtures.mainWindow()
        let contactsRoot = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-new-customers.json"))
        var keys: [KeystrokeInjector.Shortcut] = []
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        actions.frontmostPid = { nil }
        actions.postShortcut = { key, _ in
            keys.append(key)
            if keys.count == 3 { fake.replaceChildren(of: fake.rootHandle, with: contactsRoot.children) }
        }
        let out = try actions.openContacts(app: fake.rootElement, window: fake.rootElement)
        #expect(keys == [.commandDigit(8), .controlTab, .controlTab] && out.details["steps"] == "2")
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.selectedRows })   // 新的客户 row selected
    }

    @Test func openContactsGivesUpAfterSixTabsAndReturnUsesTheDeepLink() throws {
        let fake = try Fixtures.mainWindow()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts]))
        actions.verifyTimeout = 0.02; actions.verifyInterval = 0.01; actions.frontmostPid = { nil }
        var presses = 0
        actions.postShortcut = { _, _ in presses += 1 }
        #expect(throws: ActionError.verifyFailed("contacts view did not appear after 6 tab steps")) {
            try actions.openContacts(app: fake.rootElement, window: fake.rootElement)
        }
        #expect(presses == 7)
        var opened: [URL] = []
        actions.openURL = { opened.append($0); return true }
        let back = try actions.returnToMessages(window: fake.rootElement)
        #expect(opened.map(\.absoluteString) == ["wxwork://conversationlist"] && back.verified)
    }

    @Test func shortcutsAreRestrictedToTheApprovedKeys() {
        #expect(KeystrokeInjector.Shortcut.commandDigit(8).keyCode == 28 && KeystrokeInjector.Shortcut.controlTab.keyCode == 48)
        #expect(KeystrokeInjector.Shortcut.commandDigit(9).keyCode == nil)
    }
}

// WatchDiffTests 追加
    @Test func badgeChangeIsAnEvent() {
        var a = WatchSnapshot(active: "a", conversations: [], messages: [], composerLength: 0)
        var b = a; b.contactRequestsPending = 2
        #expect(WatchDiff.compare(a, b).contains { if case .contactRequestsChanged(0, 2) = $0 { return true }; return false })
        a.contactRequestsPending = 2
        #expect(!WatchDiff.compare(a, b).contains { if case .contactRequestsChanged = $0 { return true }; return false })
    }
```

- [ ] **Step 2: 实现**

`KeystrokeInjector.swift`（保留 `postReturn`；文档注释改为"两类例外：回车（2026-09-12）与切换左侧 Tab 的 `⌘1–8` / `⌃Tab`（2026-09-15）"）：

```swift
    /// Keys the user approved on 2026-09-15 for reaching 通讯录: the client's
    /// own "切换左侧 Tab" shortcuts. Nothing else.
    enum Shortcut: Equatable {
        case commandDigit(Int)
        case controlTab
        case shiftControlTab

        var keyCode: CGKeyCode? {
            switch self {
            case .commandDigit(let d): return [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28][d]
            case .controlTab, .shiftControlTab: return 48
            }
        }
        var flags: CGEventFlags {
            switch self {
            case .commandDigit: return [.maskCommand]
            case .controlTab: return [.maskControl]
            case .shiftControlTab: return [.maskControl, .maskShift]
            }
        }
    }

    static func postShortcut(_ shortcut: Shortcut, toPid pid: pid_t) throws {
        guard let key = shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw Failure.eventCreation }
        down.flags = shortcut.flags; up.flags = shortcut.flags
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
        up.postToPid(pid)
    }
```

`Contacts/RailBadges.swift`：

```swift
import AXKit
import CoreGraphics

/// The navigation rail exposes its badge counts as tiny disabled buttons at
/// x < 0 whose title is the number (2026-09-15, 5.0.11). The 通讯录 item sits
/// at y ≈ 385 in a 1200 px window; the message badge is near y ≈ 97.
public enum RailBadges {
    public static let contactsBadgeY: ClosedRange<CGFloat> = 370...400

    public static func contactRequestsPending(window: AXElement) -> Int {
        guard let children = try? window.children().first?.children() else { return 0 }
        for child in children {
            guard (try? child.role()) == AXRole.button, let f = try? child.frame(), f.minX < 0, contactsBadgeY.contains(f.minY),
                  let title = try? child.title(), let n = Int(title) else { continue }
            return n
        }
        return 0
    }
}
```

`Contacts/ContactsView.swift`：

```swift
import AXKit
import CoreGraphics

/// The 通讯录 view: a left outline (新的客户 / 智能机器人 / <company> / 添加成员...)
/// and, with 新的客户 selected, a right-hand table of request cards.
public enum WeComContactsView {
    public static let newCustomersTitle = "新的客户"
    static let signatureTexts: Set<String> = ["智能机器人", "添加成员..."]

    static func texts(in window: AXElement) -> [(String, AXElement)] {
        window.descendants(maxDepth: 10, maxNodes: 3000).compactMap { e in
            guard let role = try? e.role(), role == AXRole.textArea || role == AXRole.staticText, let v = try? e.valueString(), !v.isEmpty else { return nil }
            return (v, e)
        }
    }

    public static func isShowing(window: AXElement) -> Bool {
        let values = Set(texts(in: window).map(\.0))
        return values.contains(newCustomersTitle) && !values.isDisjoint(with: signatureTexts)
    }

    /// Selects the 新的客户 row of the left outline (its parent chain: text → cell → row → outline).
    public static func selectNewCustomers(window: AXElement) throws {
        guard let text = texts(in: window).first(where: { $0.0 == newCustomersTitle && ((try? $0.1.frame()?.minX) ?? 999) < 400 })?.1 else {
            throw WeComError.region("contacts.newCustomersRow")
        }
        var node: AXElement? = text
        var row: AXElement?
        for _ in 0..<4 { node = try node?.parent(); if (try? node?.role()) == AXRole.row { row = node; break } }
        guard let row, let outline = try row.parent(), try outline.isSettable(AXAttribute.selectedRows) else { throw WeComError.region("contacts.outline") }
        try outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
    }

    /// The cards table (right pane): wide table right of the outline.
    public static func newCustomersTable(window: AXElement) throws -> AXElement? {
        for e in window.descendants(maxDepth: 10, maxNodes: 3000) where (try? e.role()) == AXRole.table {
            if let f = try e.frame(), f.minX >= 400, f.width >= 1000 { return e }
        }
        return nil
    }
}
```

`Actions/WeComActions.swift` 注入点（放在 `restoreFrontmost` 之后）：

```swift
    /// The approved tab shortcuts, delivered to the client's pid only. Replaced in tests.
    public var postShortcut: (KeystrokeInjector.Shortcut, pid_t) throws -> Void = { try KeystrokeInjector.postShortcut($0, toPid: $1) }
    /// Deep links (`wxwork://…`) are opened through the workspace, not typed. Replaced in tests.
    public var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
```

`Actions/Contacts.swift`：

```swift
import AppKit
import AXKit
import ControlCore

public extension WeComActions {
    static let conversationListDeepLink = URL(string: "wxwork://conversationlist")!
    static let maxTabSteps = 6

    /// ⌘8 puts the client on its 8th tab; ⌃Tab steps on until the 通讯录
    /// signature (新的客户 + 智能机器人 / 添加成员...) shows, then 新的客户 is
    /// selected in the left outline. The rail order is user-configurable, so
    /// the signature check — not a fixed count — decides when to stop.
    func openContacts(app: AXElement, window: AXElement) throws -> ActionOutcome {
        try policy.authorize(.openContacts, target: nil)
        let pid = try app.pid()
        if (try? app.isSettable(AXAttribute.frontmost)) == true { try app.setAttribute(AXAttribute.frontmost, to: .bool(true)) }
        try postShortcut(.commandDigit(8), pid)
        var steps = 0
        var showing = try waitUntil { WeComContactsView.isShowing(window: window) }
        while !showing && steps < Self.maxTabSteps {
            try postShortcut(.controlTab, pid)
            steps += 1
            showing = try waitUntil { WeComContactsView.isShowing(window: window) }
        }
        guard showing else { throw ActionError.verifyFailed("contacts view did not appear after \(Self.maxTabSteps) tab steps") }
        try WeComContactsView.selectNewCustomers(window: window)
        let table = try waitUntil { try WeComContactsView.newCustomersTable(window: window) != nil }
        return ActionOutcome(kind: ActionKind.openContacts.rawValue, target: nil, verified: table, details: ["steps": String(steps)])
    }

    /// Back to 消息 through the client's own deep link; waits for the conversation table.
    func returnToMessages(window: AXElement) throws -> ActionOutcome {
        let opened = openURL(Self.conversationListDeepLink)
        let back = try waitUntil { (try? WeComLayout.locate(in: window)) != nil && !WeComContactsView.isShowing(window: window) }
        return ActionOutcome(kind: "returnToMessages", target: nil, verified: opened && back, details: ["deepLink": Self.conversationListDeepLink.absoluteString])
    }

    /// Runs `body` on the contacts view and always tries to return to 消息 and hand focus back.
    func withContactsView<T>(app: AXElement, window: AXElement, _ body: () throws -> T) throws -> T {
        let previous = frontmostPid()
        let clientPid = try? app.pid()
        defer {
            _ = try? returnToMessages(window: window)
            if let previous, previous != clientPid { restoreFrontmost(previous) }
        }
        _ = try openContacts(app: app, window: window)
        return try body()
    }
}
```

`WatchSnapshot`：`public var contactRequestsPending: Int = 0`，`take` 里 `contactRequestsPending: RailBadges.contactRequestsPending(window: reader.layout.window)`；`WatchDiff`：`case contactRequestsChanged(from: Int, to: Int)`（描述 `"contact requests \(f) -> \(t)"`；`compare` 末尾 `if old.contactRequestsPending != new.contactRequestsPending { events.append(...) }`；`observable` 不过滤它）；`WatchEngine.draft`：`case .contactRequestsChanged(_, let to): return WatchDraft(kind: .controllerState, payload: ["contactRequestsPending": String(to)])`，并暴露 `public var contactRequestsPending: Int { previous?.contactRequestsPending ?? 0 }`。

- [ ] **Step 3: 编译检查**。

---

### Task 3: 新的客户卡片：解析、`contactRequestList` / `contactRequestAccept`

**Files:**
- Create: `Sources/WeComAdapter/Contacts/NewCustomersPage.swift`
- Create: `Sources/WeComAdapter/Actions/ContactRequests.swift`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Test: Create `Tests/WeComAdapterTests/NewCustomersTests.swift`

**Interfaces:**
- `NewCustomerCard { name: String; greeting: String?; source: String /* "wechat"|"wecom" */; status: Status(pending/added); button: AXElement }`
- `NewCustomersPage.parse(table: AXElement) throws -> [NewCustomerCard]`
- `WeComActions.contactRequestList(app:window:) throws -> [NewCustomerCard]`、`contactRequestAccept(name:app:window:) throws -> ActionOutcome`（details `name`, `status`）
- 处理器 `contactRequestList()` → `[{name, greeting?, source, status}]`；`contactRequestAccept(name:)` → `{name, accepted:"true", status:"added"}`

- [ ] **Step 1: 失败测试**

```swift
@Suite("新的客户 cards")
struct NewCustomersTests {
    func actions(_ enabled: Set<ActionKind>) -> WeComActions {
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: enabled))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }
        a.postShortcut = { _, _ in }; a.openURL = { _ in true }
        return a
    }

    @Test func parsesCardsWithStatusFromTheButton() throws {
        let fake = try ContactsFixture.newCustomers()
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let cards = try NewCustomersPage.parse(table: table)
        #expect(cards.count == 2 && cards.map(\.status) == [.added, .pending])
        #expect(cards.allSatisfy { $0.source == "wechat" && $0.name.hasPrefix("«") && ($0.greeting ?? "").hasPrefix("«") })
        #expect(try cards[1].button.title() == "接受")
    }

    @Test func acceptPressesTheUniquePendingCardAndVerifiesTheButtonChange() throws {
        let fake = try ContactsFixture.newCustomers()   // already on the contacts view: ⌘8/⌃Tab are no-ops
        let table = try #require(try WeComContactsView.newCustomersTable(window: fake.rootElement))
        let pending = try NewCustomersPage.parse(table: table)[1]
        let button = pending.button.handle
        fake.reactions["action:AXPress"] = { fake.mutate(button, attribute: AXAttribute.title, to: .string("打招呼")) }
        let out = try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: pending.name, app: fake.rootElement, window: fake.rootElement)
        #expect(out.verified && out.details["status"] == "added" && fake.recordedActions.map(\.action) == [AXAction.press])
        #expect(throws: ActionError.targetNotFound("nobody")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: "nobody", app: fake.rootElement, window: fake.rootElement)
        }
        let added = try NewCustomersPage.parse(table: table)[0]
        #expect(throws: ActionError.localGuard("\(added.name) is already added")) {
            try actions([.openContacts, .acceptRequest]).contactRequestAccept(name: added.name, app: fake.rootElement, window: fake.rootElement)
        }
    }

    @Test func handlerMapsCardsToWireRows() throws {
        let fake = try ContactsFixture.newCustomers()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-b7-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.openContacts, .acceptRequest], phase: .phase1), checkpoints: cps)
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }; a.postShortcut = { _, _ in }; a.openURL = { _ in true } }
        let rows = try h.contactRequestList()
        #expect(rows.count == 2 && rows[1]["status"] == "pending" && rows[0]["status"] == "added" && rows[1]["source"] == "wechat")
    }
}
```

（`rootProvider` 返回窗口根：`WeComWindowLocator.mainWindow(from:)` 接受窗口；`app.pid()` 在 fake 上返回 4242。）

- [ ] **Step 2: 实现**

`Contacts/NewCustomersPage.swift`：

```swift
import AXKit
import CoreGraphics

public struct NewCustomerCard: Equatable {
    public enum Status: String { case pending, added }
    public var name: String
    public var greeting: String?
    public var source: String
    public var status: Status
    public var button: AXElement
    public static func == (a: NewCustomerCard, b: NewCustomerCard) -> Bool { a.name == b.name && a.greeting == b.greeting && a.status == b.status }
}

/// One request card = one 122 px row: source label (微信), a small icon, the
/// avatar, the name (bold, second text), the greeting (third text) and one
/// button — 接受 for a pending request, 打招呼 once the person is a contact
/// (2026-09-15, 5.0.11). Texts are taken by vertical order, never by position.
public enum NewCustomersPage {
    public static let acceptTitle = "接受"
    public static let greetTitle = "打招呼"

    public static func parse(table: AXElement) throws -> [NewCustomerCard] {
        var cards: [NewCustomerCard] = []
        for row in try table.children() where (try? row.role()) == AXRole.row {
            let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
            var texts: [(String, CGRect)] = []
            var button: AXElement?
            for child in try cell.children() {
                switch try child.role() {
                case AXRole.staticText:
                    if let v = try child.valueString(), !v.isEmpty, let f = try child.frame() { texts.append((v, f)) }
                case AXRole.button:
                    let title = try child.title() ?? ""
                    if title == acceptTitle || title == greetTitle { button = child }
                default: continue
                }
            }
            guard let button else { continue }
            texts.sort { $0.1.minY < $1.1.minY }
            var source = "wecom"
            if let first = texts.first, first.1.width <= 40 { source = first.0 == "微信" ? "wechat" : "wecom"; texts.removeFirst() }
            guard let name = texts.first?.0 else { continue }
            let greeting = texts.dropFirst().first?.0
            let status: NewCustomerCard.Status = (try button.title()) == acceptTitle ? .pending : .added
            cards.append(NewCustomerCard(name: name, greeting: greeting, source: source, status: status, button: button))
        }
        return cards
    }
}
```

`Actions/ContactRequests.swift`：

```swift
import AXKit
import ControlCore

public extension WeComActions {
    func contactRequestList(app: AXElement, window: AXElement) throws -> [NewCustomerCard] {
        try withContactsView(app: app, window: window) {
            guard let table = try WeComContactsView.newCustomersTable(window: window) else { throw WeComError.region("contacts.newCustomersTable") }
            return try NewCustomersPage.parse(table: table)
        }
    }

    /// 接受 on the unique pending card called `name`; verified by the button
    /// turning into 打招呼 (or the card leaving the list).
    func contactRequestAccept(name: String, app: AXElement, window: AXElement) throws -> ActionOutcome {
        try policy.authorize(.acceptRequest, target: nil)
        return try withContactsView(app: app, window: window) {
            guard let table = try WeComContactsView.newCustomersTable(window: window) else { throw WeComError.region("contacts.newCustomersTable") }
            let cards = try NewCustomersPage.parse(table: table)
            let matches = cards.filter { $0.name == name }
            guard !matches.isEmpty else { throw ActionError.targetNotFound(name) }
            guard matches.count == 1 else { throw ActionError.targetAmbiguous(name, count: matches.count) }
            let card = matches[0]
            guard card.status == .pending else { throw ActionError.localGuard("\(name) is already added") }
            try card.button.perform(AXAction.press)
            let done = try waitUntil {
                let now = try NewCustomersPage.parse(table: table)
                return now.first { $0.name == name }.map { $0.status == .added } ?? true
            }
            guard done else { throw ActionError.verifyFailed("接受 pressed but \(name) still pending") }
            return ActionOutcome(kind: ActionKind.acceptRequest.rawValue, target: name, verified: true, details: ["name": name, "status": "added"])
        }
    }
}
```

处理器（`WeComCommandHandler`，`clientNavigate` 之后）：

```swift
    public func contactRequestList() throws -> [[String: String]] {
        try mapErrors {
            let app = try rootProvider(); let window = try WeComWindowLocator.mainWindow(from: app)
            return try actions(for: nil).contactRequestList(app: app, window: window).map { card in
                var d = ["name": card.name, "source": card.source, "status": card.status.rawValue]
                if let g = card.greeting { d["greeting"] = g }
                return d
            }
        }
    }

    public func contactRequestAccept(name: String) throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider(); let window = try WeComWindowLocator.mainWindow(from: app)
            let out = try actions(for: nil).contactRequestAccept(name: name, app: app, window: window)
            return ["name": name, "accepted": "true", "status": out.details["status"] ?? "added"]
        }
    }
```

- [ ] **Step 3: 编译检查**。

---

### Task 4: 「发起群聊」面板：好友列表与建群

**Files:**
- Create: `Sources/WeComAdapter/Contacts/GroupPickerSheet.swift`
- Create: `Sources/WeComAdapter/Actions/GroupPicker.swift`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Test: Create `Tests/WeComAdapterTests/GroupPickerTests.swift`

**Interfaces:**
- `PickerContact { name: String; tag: String?; source: String; row: AXElement; section: String }`
- `GroupPickerSheet { sheet: AXElement; searchField: AXElement?; outline: AXElement; selectedTable: AXElement?; doneButton: AXElement?; cancelButton: AXElement? }`；`static func locate(window:) throws -> GroupPickerSheet?`；`func rows() throws -> [PickerContact]`（按节归类：节头缩进 x ≤ 700，组头 700 < x ≤ 730，条目 > 730；`section` = 最近的节头文字）；`var customers: [PickerContact]`（`section == "我的客户"`）
- `WeComLayout.plusButton: AXElement?`（顶部 60 px 内、宽 ≤ 40、位于搜索框右侧的 `AXButton`）
- `WeComActions.openGroupPicker(window:) throws -> GroupPickerSheet`（`AXPress` +，等 `AXSheet`）、`closeGroupPicker(_:)`（`取消`）、`readContacts(window:limit:) throws -> [PickerContact]`（滚动条 `AXValue` 0/0.25/…/1 合并）、`createGroup(members:window:) throws -> ActionOutcome`（details `title`, `memberCount`, `selected`）
- 处理器 `contactList(limit:)` → `[{name, source, tag?}]`；`groupCreate(members:name:)` → `{title, memberCount, renamed:"false", requestedName?}`

- [ ] **Step 1: 失败测试**

```swift
@Suite("Group picker sheet")
struct GroupPickerTests {
    static func sheetFixture() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json")))
    }
    func actions(_ enabled: Set<ActionKind>) -> WeComActions {
        var a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: enabled))
        a.verifyTimeout = 0.05; a.verifyInterval = 0.01; a.frontmostPid = { nil }; a.openURL = { _ in true }
        return a
    }

    @Test func locatesTheSheetAndClassifiesRowsBySection() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(sheet.searchField != nil && sheet.doneButton != nil && sheet.cancelButton != nil)
        let rows = try sheet.rows()
        #expect(rows.count == 2)                                     // one WeChat contact, one company member
        #expect(sheet.customers.count == 1 && sheet.customers[0].section == "我的客户" && sheet.customers[0].source == "wechat")
        #expect(rows[1].section != "我的客户")
        #expect(try sheet.doneButton?.isEnabled() == false)
    }

    @Test func plusButtonIsLocatedOnTheMessagesView() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-filter-panel.json")))
        let layout = try WeComLayout.locate(in: fake.rootElement)
        #expect(try layout.plusButton?.frame()?.minX == 361)
    }

    @Test func createGroupSelectsEachMemberAndPressesDone() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let contact = sheet.customers[0]
        let selectedTable = try #require(sheet.selectedTable?.handle)
        let done = try #require(sheet.doneButton?.handle)
        // client behaviour: selecting the row adds it to the right-hand table and enables 完成; 完成 closes the sheet
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.appendChild(to: selectedTable, node: AXNode(role: AXRole.row, frame: CGRect(x: 961, y: 388, width: 319, height: 36)))
            fake.mutate(done, attribute: AXAttribute.enabled, to: .bool(true))
        }
        fake.reactions["action:AXPress"] = { fake.replaceChildren(of: fake.rootHandle, with: [try! AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())).children[0]]) }
        var a = actions([.openGroupPicker, .createGroup])
        a.postShortcut = { _, _ in }
        let out = try a.createGroup(members: [contact.name], window: fake.rootElement, sheet: sheet)
        #expect(out.verified && out.details["selected"] == "1" && fake.recordedActions.last?.action == AXAction.press)
        #expect(fake.recordedSets.contains { $0.attribute == AXAttribute.value })   // search typed
    }

    @Test func createGroupRefusesUnknownMembersBeforeDone() throws {
        let fake = try Self.sheetFixture()
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        #expect(throws: ActionError.targetNotFound("nobody")) {
            try actions([.openGroupPicker, .createGroup]).createGroup(members: ["nobody"], window: fake.rootElement, sheet: sheet)
        }
        #expect(fake.recordedActions.contains { $0.action == AXAction.press && (try? AXElement(handle: $0.handle, backend: fake).title()) == "取消" })
    }
}
```

- [ ] **Step 2: 实现**

`Contacts/GroupPickerSheet.swift`：

```swift
import AXKit
import CoreGraphics

public struct PickerContact: Equatable {
    public var name: String
    public var tag: String?
    public var source: String
    public var section: String
    public var row: AXElement
    public static func == (a: PickerContact, b: PickerContact) -> Bool { a.name == b.name && a.section == b.section }
}

/// The 发起群聊 sheet opened by the + button (2026-09-15, 5.0.11): a search
/// field and an outline on the left, the chosen members on the right, 取消 /
/// 完成 below. Rows are classified by indentation: section headers (我的客户,
/// the company) at x ≤ 700, the 微信联系人 group header at ≤ 730, items beyond.
public struct GroupPickerSheet {
    public let sheet: AXElement
    public let searchField: AXElement?
    public let outline: AXElement
    public let selectedTable: AXElement?
    public let doneButton: AXElement?
    public let cancelButton: AXElement?

    public static let customersSection = "我的客户"

    public static func locate(window: AXElement) throws -> GroupPickerSheet? {
        guard let sheet = try window.children().first(where: { (try? $0.role()) == "AXSheet" }) else { return nil }
        var searchField: AXElement?, outline: AXElement?, selectedTable: AXElement?, done: AXElement?, cancel: AXElement?
        for e in sheet.descendants(maxDepth: 8, maxNodes: 2000) {
            switch try e.role() {
            case AXRole.textField: if searchField == nil { searchField = e }
            case AXRole.outline: if outline == nil { outline = e }
            case AXRole.table: if selectedTable == nil { selectedTable = e }
            case AXRole.button:
                switch try e.title() { case "完成": done = e; case "取消": cancel = e; default: break }
            default: break
            }
        }
        guard let outline else { throw WeComError.region("groupPicker.outline") }
        return GroupPickerSheet(sheet: sheet, searchField: searchField, outline: outline, selectedTable: selectedTable, doneButton: done, cancelButton: cancel)
    }

    public func rows() throws -> [PickerContact] {
        var out: [PickerContact] = []
        var section = ""
        for row in try outline.children() where (try? row.role()) == AXRole.row {
            let cell = try row.children().first { (try? $0.role()) == AXRole.cell } ?? row
            var name: (String, CGRect)?
            var trailing: [(String, CGRect)] = []
            for child in try cell.children() {
                let role = try child.role()
                guard let v = try child.valueString(), !v.isEmpty, let f = try child.frame() else { continue }
                if role == AXRole.textArea, name == nil { name = (v, f) } else if role == AXRole.staticText { trailing.append((v, f)) }
            }
            guard let (text, frame) = name else { continue }
            if frame.minX <= 700 { section = text; continue }        // section header
            if frame.minX <= 730 { continue }                         // group header (微信联系人)
            let tag = trailing.first { $0.1.minX > frame.maxX }?.0
            let source = (tag ?? "").contains("微信") ? "wechat" : "wecom"
            out.append(PickerContact(name: text, tag: tag, source: source, section: section, row: row))
        }
        return out
    }

    public var customers: [PickerContact] { (try? rows().filter { $0.section == Self.customersSection }) ?? [] }
    public func selectedCount() throws -> Int { try selectedTable?.children().filter { (try? $0.role()) == AXRole.row }.count ?? 0 }
}
```

`WeComLayout`：新属性 `public let plusButton: AXElement?`，`locate` 里 `let plus = candidates.first { $0.role == AXRole.button && $0.frame.minY < 60 && $0.frame.width <= 40 && (search.map { $0.frame.maxX } ?? 0) <= $0.frame.minX }`。

`Actions/GroupPicker.swift`：

```swift
import AXKit
import ControlCore

public extension WeComActions {
    func openGroupPicker(window: AXElement) throws -> GroupPickerSheet {
        try policy.authorize(.openGroupPicker, target: nil)
        if let existing = try GroupPickerSheet.locate(window: window) { return existing }
        let layout = try WeComLayout.locate(in: window)
        guard let plus = layout.plusButton else { throw ActionError.actionUnavailable("+ button") }
        try plus.perform(AXAction.press)
        var sheet: GroupPickerSheet?
        let shown = try waitUntil { sheet = try GroupPickerSheet.locate(window: window); return sheet != nil }
        guard shown, let sheet else { throw ActionError.verifyFailed("group picker sheet did not open") }
        return sheet
    }

    func closeGroupPicker(_ sheet: GroupPickerSheet, window: AXElement) throws {
        guard let cancel = sheet.cancelButton else { return }
        try cancel.perform(AXAction.press)
        _ = try waitUntil { try GroupPickerSheet.locate(window: window) == nil }
    }

    /// Reads 我的客户 through the picker, scrolling the outline to reach rows the client has not laid out.
    func readContacts(window: AXElement, limit: Int) throws -> [PickerContact] {
        let sheet = try openGroupPicker(window: window)
        defer { try? closeGroupPicker(sheet, window: window) }
        var seen: [String: PickerContact] = [:]
        var order: [String] = []
        let bar = try sheet.outline.parent()?.children().first { (try? $0.role()) == AXRole.scrollBar }
        let positions: [Double] = (try? bar?.isSettable(AXAttribute.value)) == true ? [0, 0.25, 0.5, 0.75, 1] : [0]
        for p in positions {
            if positions.count > 1, let bar { try bar.setAttribute(AXAttribute.value, to: .double(p)) }
            for c in sheet.customers where seen[c.name] == nil { seen[c.name] = c; order.append(c.name) }
            if order.count >= limit { break }
        }
        if positions.count > 1, let bar { try? bar.setAttribute(AXAttribute.value, to: .double(0)) }
        return order.prefix(limit).compactMap { seen[$0] }
    }

    /// Search each member, select its row (the client toggles the check and
    /// lists it on the right), then 完成. Unknown members abort before 完成.
    func createGroup(members: [String], window: AXElement, sheet given: GroupPickerSheet? = nil) throws -> ActionOutcome {
        try policy.authorize(.createGroup, target: nil)
        let sheet = try given ?? openGroupPicker(window: window)
        var selected = 0
        do {
            for member in members {
                if let field = sheet.searchField { try field.setAttribute(AXAttribute.value, to: .string(member)) }
                var row: AXElement?
                let found = try waitUntil { row = try sheet.rows().first { $0.name == member }?.row; return row != nil }
                guard found, let row else { throw ActionError.targetNotFound(member) }
                let before = try sheet.selectedCount()
                try sheet.outline.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle]))
                guard try waitUntil({ try sheet.selectedCount() > before }) else { throw ActionError.verifyFailed("selecting \(member) did not add it to the chosen list") }
                selected += 1
                if let field = sheet.searchField { try field.setAttribute(AXAttribute.value, to: .string("")) }
            }
        } catch {
            try? closeGroupPicker(sheet, window: window)
            throw error
        }
        guard let done = sheet.doneButton, try done.isEnabled() ?? true else { throw ActionError.actionUnavailable("完成") }
        try done.perform(AXAction.press)
        let closed = try waitUntil { try GroupPickerSheet.locate(window: window) == nil }
        let header = try? WeComReader(window: window).activeConversationHeader()
        return ActionOutcome(kind: ActionKind.createGroup.rawValue, target: nil, verified: closed, details: [
            "selected": String(selected), "title": header?.title ?? "", "memberCount": header?.memberCount.map(String.init) ?? "",
        ])
    }
}
```

处理器：

```swift
    public func contactList(limit: Int) throws -> [[String: String]] {
        try mapErrors {
            let window = try WeComWindowLocator.mainWindow(from: try rootProvider())
            return try actions(for: nil).readContacts(window: window, limit: limit).map { c in
                var d = ["name": c.name, "source": c.source]
                if let t = c.tag { d["tag"] = t }
                return d
            }
        }
    }

    public func groupCreate(members: [String], name: String?) throws -> [String: String] {
        try mapErrors {
            let window = try WeComWindowLocator.mainWindow(from: try rootProvider())
            let out = try actions(for: nil).createGroup(members: members, window: window)
            var d = ["title": out.details["title"] ?? "", "memberCount": out.details["memberCount"] ?? "", "renamed": "false"]
            if let name { d["requestedName"] = name }
            return d
        }
    }
```

（改名：本批不尝试——群聊页群名编辑的 AX 路径待活体取证；结果 `renamed:"false"` + `requestedName` 让调用方知道期望名。）

- [ ] **Step 3: 编译检查**。

---

### Task 5: 分发器、协议文档、CLI `policy requests`、守护进程自动化与状态

**Files:**
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（4 个 descriptor）、`Tests/MCPTransportTests/DispatcherTests.swift`（28 → 32）
- Modify: `docs/protocol/im-control-protocol.md`（§6.29–6.32、§7.6–7.8、7.1 `contactRequestsPending`、§12）
- Modify: `Sources/imctl/Commands/PolicyCommand.swift`（`requests` 子命令 + list 输出）、`Tests/imctlTests/PolicyCommandTests.swift`
- Create: `Sources/imctld/RequestAutomation.swift`；Modify: `Sources/imctld/DaemonWatcher.swift`（状态文件 `contactRequestsPending`、触发）、`Sources/imctld/main.swift`（装配、`executor.acceptsPerHour`、策略 `enabled` +4）
- Create: `Sources/WeComAdapter/Contacts/RequestDecision.swift`（纯函数，可测）；Test: `Tests/WeComAdapterTests/RequestDecisionTests.swift`

**Interfaces:**
- `RequestDecision.plan(cards: [(name: String, greeting: String?, status: String)], policy: ContactRequestPolicy, seen: Set<String>) -> (observe: [String], accept: [String], seen: Set<String>)`（`seen` 键 = `name + "\u{1f}" + greeting`；observe = 未见过的 pending 卡；accept = pending 且 `policy.decides`）
- `RequestAutomation(executor:policyProvider:store:log:)`：`func noteBadge(_ pending: Int)`（pending > 0、模式 ≠ off、距上轮 ≥ 60 s、未在跑 → 后台队列 `runRound()`）；`runRound()`：`contact.request.list` → 对 observe 追加 `contact.request.observed` 事件并把 `seen` 存 kv `requests.seen`（JSON 数组，最多 500）→ 对 accept 逐个 `contact.request.accept`（键 `auto-accept-<sha16>`）→ 成功且 `autoGroup == .perPerson` → `group.create{members: [name] + groupDefaultMembers, name: policy.groupName(for:)}`（键 `auto-group-<sha16>`）
- `imctl policy requests [--auto-accept off|all|rules|remote] [--auto-group off|perPerson] [--allow-name …]* [--greeting-contains …]* [--default-member …]* [--group-name-suffix 群聊] [--max-accepts-per-hour N] [--clear-lists]`

- [ ] **Step 1: 失败测试**

```swift
// DispatcherTests：28 → 32
// PolicyCommandTests 追加
    @Test func requestsSubcommandWritesContactRequestPolicy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-req-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("policy.json").path
        let cmd = try PolicyRequestsCommand.parse(["--file", file, "--auto-accept", "rules", "--allow-name", "测试联系人A", "--greeting-contains", "示例公司", "--auto-group", "perPerson", "--default-member", "同事A", "--group-name-suffix", "群聊", "--max-accepts-per-hour", "5"])
        let policy = try cmd.apply()
        #expect(policy.contactRequests.autoAccept == .rules && policy.contactRequests.allowNames == ["测试联系人A"] && policy.contactRequests.groupDefaultMembers == ["同事A"] && policy.contactRequests.maxAcceptsPerHour == 5)
        #expect(try SendPolicy.load(from: URL(fileURLWithPath: file)).contactRequests.autoGroup == .perPerson)
        #expect(throws: (any Error).self) { try PolicyRequestsCommand.parse(["--auto-accept", "always"]) }
        #expect(PolicyCommand.configuration.subcommands.compactMap { $0.configuration.commandName } == ["list", "allow", "deny", "requests"])
    }

// RequestDecisionTests
@Suite("RequestDecision")
struct RequestDecisionTests {
    @Test func observesNewPendingCardsOnceAndAcceptsPerPolicy() {
        var policy = ContactRequestPolicy(autoAccept: .rules, allowNames: ["测试联系人A"])
        let cards = [(name: "测试联系人A", greeting: "我是 测试联系人A", status: "pending"), (name: "路人", greeting: "hi", status: "pending"), (name: "老客户", greeting: nil, status: "added")]
        let first = RequestDecision.plan(cards: cards, policy: policy, seen: [])
        #expect(first.observe == ["测试联系人A", "路人"] && first.accept == ["测试联系人A"] && first.seen.count == 2)
        let second = RequestDecision.plan(cards: cards, policy: policy, seen: first.seen)
        #expect(second.observe.isEmpty && second.accept == ["测试联系人A"])
        policy.autoAccept = .remote
        #expect(RequestDecision.plan(cards: cards, policy: policy, seen: []).accept.isEmpty)
        policy.autoAccept = .all
        #expect(RequestDecision.plan(cards: cards, policy: policy, seen: []).accept == ["测试联系人A", "路人"])
    }
}
```

- [ ] **Step 2: 实现**

`RPCDispatcher.toolDescriptors`（`client.navigate` 之后）：

```swift
            ("contact.list", "我的客户 through the client's group picker: name, source (wechat|wecom), tag; transient sheet, nothing changes", schema(["limit": ("integer", "Max contacts (default 200)")], required: [])),
            ("contact.request.list", "通讯录 › 新的客户 cards: name, greeting, source, status pending (接受 button) | added (打招呼 button); switches the client to 通讯录 and back", schema([:], required: [])),
            ("contact.request.accept", "Press 接受 on the pending request called name; needs idempotencyKey; capped per hour", schema(["name": ("string", "Nickname exactly as the card shows it"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["name", "idempotencyKey"])),
            ("group.create", "Create a group from the picker with these members (customers by name; policy default members are added by the daemon only for automatic groups); needs idempotencyKey", schema(["members": ("array", "Member names as the picker shows them"), "name": ("string", "Desired group name (recorded; renaming is not attempted yet)"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["members", "idempotencyKey"])),
```

协议文档：§6 新增

```markdown
### 6.29 `contact.list`

参数 `{limit?=200}`。经客户端「+ › 发起群聊」面板读「我的客户」：`[{name, source:"wechat"|"wecom", tag?}]`；面板只在读取瞬间打开，之后 `取消`，不改活动会话。官方接口路线（带 `external_userid`）待代理部署。

### 6.30 `contact.request.list`

无参数。切到「通讯录 › 新的客户」读卡片再回消息视图：`[{name, greeting?, source, status:"pending"|"added"}]`——`pending` = 卡片上是「接受」按钮（可接受），`added` = 「打招呼」（已是联系人）。切换用客户端自己的快捷键（`⌘8` + `⌃Tab`，pid 级）与深链 `wxwork://conversationlist`；企微会短暂成为前台。

### 6.31 `contact.request.accept`

参数 `{name, idempotencyKey（必填）}`。找到唯一同名 `pending` 卡片按「接受」，复核按钮变「打招呼」：`{name, accepted:"true", status:"added"}`。0 个 `TARGET_NOT_FOUND`、多个 `TARGET_AMBIGUOUS`、已添加 `LOCAL_GUARD`；每小时接受上限（`policy.json.contactRequests.maxAcceptsPerHour`，默认 20）超出 `RATE_LIMITED`。成功后事件 `contact.request.accepted`。

### 6.32 `group.create`

参数 `{members:[name…], name?, idempotencyKey（必填）}`。经「+ › 发起群聊」逐个搜索并选中成员后「完成」：`{title, memberCount, renamed:"false", requestedName?}`（群名由客户端生成；`name` 只记录，改名待后续）。成员找不到 `TARGET_NOT_FOUND`，面板关闭不建群。成功后事件 `group.created`。
```

§7 新增 `### 7.6 contact.request.observed`（`{name, greeting?, source, status}`，守护进程每轮对新出现的待接受卡片各发一次）、`### 7.7 contact.request.accepted`（`{name, accepted, status, by:"policy"|"remote", commandId}`）、`### 7.8 group.created`（`{title, memberCount, members, requestedName?, commandId}`）；7.1 `controller.state` 增 `contactRequestsPending`；§5 增一段"自动接受策略 `policy.json.contactRequests`（autoAccept off/all/rules/remote、autoGroup off/perPerson、groupDefaultMembers、groupNameSuffix、maxAcceptsPerHour）"；§12 追加 B7 行。

`PolicyCommand.swift`：新增

```swift
struct PolicyRequestsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "requests", abstract: "Contact-request automation: auto-accept mode, rules, auto group, default members, hourly cap (policy.json, hot-reloaded).")
    @Option(name: .customLong("auto-accept"), help: "off | all | rules | remote") var autoAccept: String?
    @Option(name: .customLong("auto-group"), help: "off | perPerson") var autoGroup: String?
    @Option(name: .customLong("allow-name"), parsing: .upToNextOption, help: "Nickname(s) accepted in rules mode.") var allowNames: [String] = []
    @Option(name: .customLong("greeting-contains"), parsing: .upToNextOption, help: "Greeting keyword(s) accepted in rules mode.") var greetingContains: [String] = []
    @Option(name: .customLong("default-member"), parsing: .upToNextOption, help: "Member(s) added to every automatic group.") var defaultMembers: [String] = []
    @Option(name: .customLong("group-name-suffix"), help: "Group name = customer name + suffix.") var groupNameSuffix: String?
    @Option(name: .customLong("max-accepts-per-hour")) var maxAcceptsPerHour: Int?
    @Flag(name: .customLong("clear-lists"), help: "Replace the name / keyword / member lists instead of appending.") var clearLists = false
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if let a = autoAccept, ContactRequestPolicy.AcceptMode(rawValue: a) == nil { throw ValidationError("--auto-accept must be off, all, rules or remote") }
        if let g = autoGroup, ContactRequestPolicy.GroupMode(rawValue: g) == nil { throw ValidationError("--auto-group must be off or perPerson") }
    }

    func apply() throws -> SendPolicy {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        var r = policy.contactRequests
        if let a = autoAccept { r.autoAccept = ContactRequestPolicy.AcceptMode(rawValue: a)! }
        if let g = autoGroup { r.autoGroup = ContactRequestPolicy.GroupMode(rawValue: g)! }
        func merge(_ current: [String], _ new: [String]) -> [String] { clearLists ? new : current + new.filter { !current.contains($0) } }
        if clearLists || !allowNames.isEmpty { r.allowNames = merge(r.allowNames, allowNames) }
        if clearLists || !greetingContains.isEmpty { r.greetingContains = merge(r.greetingContains, greetingContains) }
        if clearLists || !defaultMembers.isEmpty { r.groupDefaultMembers = merge(r.groupDefaultMembers, defaultMembers) }
        if let s = groupNameSuffix { r.groupNameSuffix = s }
        if let m = maxAcceptsPerHour { r.maxAcceptsPerHour = max(0, m) }
        policy.contactRequests = r
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        print("wrote \(file) (0600): \(policy.contactRequests.summary) names=\(policy.contactRequests.allowNames.count) keywords=\(policy.contactRequests.greetingContains.count) defaultMembers=\(policy.contactRequests.groupDefaultMembers.count) maxAcceptsPerHour=\(policy.contactRequests.maxAcceptsPerHour)")
    }
}
```

`PolicyCommand.subcommands` 加 `PolicyRequestsCommand.self`；`PolicyListCommand.run` 文本输出加一行 `requests: \(view.policy.contactRequests.summary) …`。

`Contacts/RequestDecision.swift`：

```swift
import ControlCore

/// Which cards of one round to report and which to accept. Pure, so the
/// daemon's automation is testable without a client.
public enum RequestDecision {
    public static func key(name: String, greeting: String?) -> String { name + "\u{1f}" + (greeting ?? "") }

    public static func plan(cards: [(name: String, greeting: String?, status: String)], policy: ContactRequestPolicy, seen: Set<String>)
        -> (observe: [String], accept: [String], seen: Set<String>) {
        var seen = seen, observe: [String] = [], accept: [String] = []
        for card in cards where card.status == "pending" {
            let k = key(name: card.name, greeting: card.greeting)
            if !seen.contains(k) { observe.append(card.name); seen.insert(k) }
            if policy.decides(name: card.name, greeting: card.greeting) { accept.append(card.name) }
        }
        return (observe, accept, seen)
    }
}
```

`imctld/RequestAutomation.swift`：

```swift
import ControlCore
import CryptoKit
import Foundation
import WeComAdapter

/// One round per badge change: read the cards through the executor (so every
/// step is a command with events), report new ones, accept per policy, and
/// create one group per accepted person when asked to.
final class RequestAutomation {
    let executor: CommandExecutor
    let policyProvider: PolicyProvider
    let store: ControlStore
    let log: DaemonLog
    var minIntervalMs: Int64 = 60_000
    private let queue = DispatchQueue(label: "com.sunkailun.imctl.requests")
    private var running = false
    private var lastRoundMs: Int64 = 0
    static let seenKey = "requests.seen"

    init(executor: CommandExecutor, policyProvider: PolicyProvider, store: ControlStore, log: DaemonLog) {
        self.executor = executor; self.policyProvider = policyProvider; self.store = store; self.log = log
    }

    func noteBadge(_ pending: Int) {
        let policy = policyProvider.current().contactRequests
        guard pending > 0, policy.autoAccept != .off, !running, Clock.nowMs() - lastRoundMs >= minIntervalMs else { return }
        running = true
        queue.async { [self] in
            defer { running = false }
            lastRoundMs = Clock.nowMs()
            do { try runRound(policy: policy) } catch { log.info("requests: round failed: \(error)") }
        }
    }

    func runRound(policy: ContactRequestPolicy) throws {
        let list = try executor.submit(method: .contactRequestList, paramsJSON: "{}", idempotencyKey: nil)
        guard list.state == .succeeded, let json = list.resultJSON,
              let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return }
        let cards = rows.map { (name: $0["name"] ?? "", greeting: $0["greeting"], status: $0["status"] ?? "") }
        let seenBefore = Set((try? store.value(forKey: Self.seenKey)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        let plan = RequestDecision.plan(cards: cards, policy: policy, seen: seenBefore)
        for name in plan.observe {
            guard let card = rows.first(where: { $0["name"] == name }) else { continue }
            try store.appendEvent(kind: .contactRequestObserved, payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: card, options: [.sortedKeys]), as: UTF8.self), nowMs: Clock.nowMs())
        }
        let seen = Array(plan.seen).suffix(500)
        try store.setValue(String(decoding: try JSONEncoder().encode(Array(seen)), as: UTF8.self), forKey: Self.seenKey)
        for name in plan.accept {
            let digest = SHA256.hash(data: Data(RequestDecision.key(name: name, greeting: cards.first { $0.name == name }?.greeting).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let accept = try executor.submit(method: .contactRequestAccept, paramsJSON: #"{"name":"\#(name)","idempotencyKey":"auto-accept-\#(digest)"}"#, idempotencyKey: "auto-accept-\(digest)")
            log.info("requests: accept \(name.count) chars -> \(accept.state.rawValue) \(accept.errorCode ?? "")")
            guard accept.state == .succeeded, policy.autoGroup == .perPerson else { continue }
            let members = ([name] + policy.groupDefaultMembers).map { "\"\($0)\"" }.joined(separator: ",")
            let group = try executor.submit(method: .groupCreate, paramsJSON: #"{"members":[\#(members)],"name":"\#(policy.groupName(for: name))","idempotencyKey":"auto-group-\#(digest)"}"#, idempotencyKey: "auto-group-\(digest)")
            log.info("requests: group for \(name.count) chars -> \(group.state.rawValue) \(group.errorCode ?? "")")
        }
    }
}
```

（`name` 含引号的情况：用 `JSONSerialization` 生成参数而不是字符串拼接——实现时用 `try JSONSerialization.data(withJSONObject: ["name": name, "idempotencyKey": key])`；上面示意。）

`DaemonWatcher`：属性 `var automation: RequestAutomation?`；成功轮询后 `automation?.noteBadge(engine.contactRequestsPending)`；状态文件加 `"contactRequestsPending": engine.contactRequestsPending`。`main.swift`：`enabled` 加 `.openContacts, .acceptRequest, .openGroupPicker, .createGroup`；`executor.acceptsPerHour = { policyProvider.current().contactRequests.maxAcceptsPerHour }`；`watcher.automation = RequestAutomation(executor: executor, policyProvider: policyProvider, store: store, log: log)`。

- [ ] **Step 3: 编译检查**。

---

### Task 6: 控制台「通讯录」页与策略开关

**Files:**
- Modify: `Sources/imctl-console/Model/ConsoleModel.swift`（`contacts`, `requests`, `loadContacts()`, `loadRequests()`, `accept(name:)`, `createGroup(members:name:)`, `policyRequests(args:)`）、`Model/RPCService.swift`（`acceptParams`, `groupCreateParams`）
- Create: `Sources/imctl-console/Views/ContactsView.swift`；Modify: `Views/ConsoleWindow.swift`（新节 `.contacts` "通讯录"）、`Views/PolicyView.swift`（自动接受 / 拉群控件）
- Test: `Tests/imctl-consoleTests/RPCServiceTests.swift`（参数构造）

**Interfaces:**
- `RPCService.acceptParams(name:) -> [String: JSONValue]`（带 `console-` 幂等键）、`groupCreateParams(members:name:)`
- 通讯录页：「读取新的客户」→ 列表（状态、打招呼语）+ 每行「接受」（pending 时）；「读取好友列表」→ 勾选列表；群名输入 + 「创建群」；页内错误 / 守护进程提示同其它页
- 策略页：`autoAccept` 分段选择（off/all/rules/remote）、`autoGroup` 开关、名单 / 关键词 / 默认成员文本（逗号分隔）、后缀、每小时上限 → `imctl policy requests …`

- [ ] **Step 1: 失败测试**

```swift
    @Test func contactsParamsCarryConsoleKeys() {
        let a = RPCService.acceptParams(name: "测试联系人A")
        #expect(a["name"] == .string("测试联系人A") && a["idempotencyKey"]?.stringValue?.hasPrefix("console-") == true)
        let g = RPCService.groupCreateParams(members: ["测试联系人A", "同事A"], name: "测试联系人A群聊")
        #expect(g["members"] == .array([.string("测试联系人A"), .string("同事A")]) && g["name"] == .string("测试联系人A群聊"))
        #expect(RPCService.groupCreateParams(members: ["x"], name: nil)["name"] == nil)
    }
```

- [ ] **Step 2: 实现**（视图代码见实现；模型方法都经 `rpc`；策略页动作经 `cli.run(["policy", "requests", …])`）。

---

### Task 7: 全量测试、活体（测试联系人A）、门报告、提交、wiki

- [ ] `swift test` 全过（预计 ≥ 250）。
- [ ] 活体（临时守护进程或已装守护进程均可，此时 launchd 跑的是包内新版且已授权）：`imctl call contact.request.list`（2 张卡：1 added、1 pending = 测试联系人A）→ `contact.request.accept{name:"测试联系人A"}` → 再 `list` 应为 added → `contact.list` 含 测试联系人A → `group.create{members:["测试联系人A"], name:"测试联系人A群聊"}` → 活动会话头部 `…(N)`；探一下群聊页群名编辑的 AX 路径（供改名后续）；`policy requests --auto-accept remote` 后确认守护进程一轮（角标 > 0 时）发 `contact.request.observed`。
- [ ] 门报告 `docs/gates/2026-09-15-b7-contacts-requests-groups.md`；重建包装回 `~/Applications` 并 kickstart；提交推送；wiki（query + repo/topic/synthesis/review/overview/log + 交接）。

# 批次 B3：观察者并入 imctld、历史回读、接管信号、事件对账与常驻/收口准备 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"下一步"里不需要用户输入的四项做完（AXObserver 通知路径并入 `imctld`、`message.history` 向上滚动读历史、`origin: other` 接管信号、Developer ID 签名准备），并把需要用户决定的三项（LaunchAgent、EMQX 凭据/ACL、Java 消费方）推进到"用户一个决定就能执行"的状态：安装命令写好但不执行、控制器侧 ACL 守卫与 `event.replay` 对账方法做好、配置与契约文档写好。

**Architecture:** 观察逻辑从 `imctld` 下沉到 `WeComAdapter/Watch/`（`WatchEngine` 负责定位/快照/diff/归因，`WeComObserver` 负责订阅标准通知集，纯逻辑可用 `FakeAXBackend` 测试），`DaemonWatcher` 只保留定时器、去抖、状态文件与落库。历史回读是一个新的受策略约束的动作 `scrollHistory`（`AXScrollBar.AXValue`/`AXScrollUpByPage`，纯 AX，无合成事件）。`origin` 由 `OriginClassifier` 用 `ControlStore` 里最近 10 分钟 succeeded/unknown 的 `message.send` 归因，同一条发送只消费一次。`event.replay` 是查询而不是命令：在 `RPCDispatcher` 层直接读事件表，不产生命令记录与 `command.state` 事件。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，swift-testing，GRDB 7.11.1，mqtt-nio 2.13.0，swift-argument-parser 1.8.2；launchd（`launchctl bootstrap/bootout/print`）。

## Global Constraints

- 白名单编译在 `WeComClient.fileTransferAssistantTitle`，只有"文件传输助手"；本批任何动作（滚动、发送）只对它；不向真实联系人或客户群发消息。
- 除 `KeystrokeInjector.swift` 的 pid 级回车外不出现 `CGEvent*`；`ForbiddenAPITests` 继续拦截。滚动只用 AX 动作/属性（`AXScrollUpByPage`、`AXScrollBar.AXValue`）。
- 权限面只有辅助功能；不申请录屏/输入监控。
- 仓库与 wiki 不含 secret、凭据、broker 地址、真实联系人内容。
- **不安装 LaunchAgent、不改 EMQX 配置、不扩大白名单**：这三项等用户决定；本批只交付命令、文档与守卫。
- 工作方式：批量实现，最后一次 `swift test`，再对真实客户端做一次 E2E。

---

### Task 1: `WatchDiff` 识别"历史被前插"（prepend）

**Files:**
- Modify: `Sources/WeComAdapter/Watch/WatchDiff.swift`
- Test: `Tests/WeComAdapterTests/WatchDiffTests.swift`

**Interfaces:**
- Produces: `WatchEvent.messagesPrepended(count: Int)`；`WatchDiff.compare` 在"新列表尾部等于旧列表且头部不等"时不再报 `messageAdded`，改报 `messagesPrepended` 并按尾对齐比较 `messageChanged`。

- [ ] **Step 1: 失败测试**

```swift
@Test func prependedHistoryIsNotNewMessages() {
    func m(_ i: Int, _ t: String, _ d: String = "outbound") -> WatchSnapshot.Message { .init(index: i, text: t, timeLabel: nil, direction: d, y: Double(i)) }
    let old = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "x"), m(1, "y")], composerLength: 0)
    let new = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "h1"), m(1, "h2"), m(2, "x"), m(3, "y")], composerLength: 0)
    let events = WatchDiff.compare(old, new)
    #expect(events.contains(.messagesPrepended(count: 2)))
    #expect(!events.contains { if case .messageAdded = $0 { return true }; return false })
    #expect(!events.contains { if case .messageChanged = $0 { return true }; return false })
    // 头尾都匹配（重复文本）按追加处理
    let dup = WatchSnapshot(active: "a", conversations: [], messages: [m(0, "x"), m(1, "y"), m(2, "x"), m(3, "y")], composerLength: 0)
    #expect(WatchDiff.compare(old, dup).contains(.messageAdded(index: 2, direction: "outbound", timeLabel: nil)))
}
```

- [ ] **Step 2: 跑测试确认失败**（`messagesPrepended` 不存在，编译失败）

- [ ] **Step 3: 实现**

```swift
case messagesPrepended(count: Int)   // summary: "messages prepended \(count)"

static func prependedCount(old: [WatchSnapshot.Message], new: [WatchSnapshot.Message]) -> Int? {
    let k = new.count - old.count
    guard k > 0, !old.isEmpty else { return nil }
    func same(_ a: WatchSnapshot.Message, _ b: WatchSnapshot.Message) -> Bool { a.text == b.text && a.direction == b.direction }
    let tailMatches = zip(old, new.dropFirst(k)).allSatisfy(same)
    let headMatches = zip(old, new).allSatisfy(same)
    return tailMatches && !headMatches ? k : nil
}
```
`compare` 中：若 `prependedCount` 非 nil → append `.messagesPrepended(count:)`，用 `zip(old.messages, new.messages.dropFirst(k))` 产生 `messageChanged`，不产生 `messageCountChanged`/`messageAdded`；否则走原逻辑。

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(adapter): WatchDiff detects prepended history instead of reporting it as new messages`

---

### Task 2: `MessageOrigin`、`ControllerSend`、`ControlStore.recentSends`、`OriginClassifier`

**Files:**
- Create: `Sources/ControlCore/Protocol/MessageOrigin.swift`
- Modify: `Sources/ControlCore/Store/ControlStore.swift`
- Create: `Sources/WeComAdapter/Watch/OriginClassifier.swift`
- Test: `Tests/ControlCoreTests/ControlStoreTests.swift`（追加）、`Tests/WeComAdapterTests/OriginClassifierTests.swift`

**Interfaces:**
```swift
public enum MessageOrigin: String, Codable, Equatable { case controller, other, peer, unknown }
public struct ControllerSend: Equatable { public var commandId: String; public var target: String; public var text: String; public var tsMs: Int64 }
extension ControlStore { public func recentSends(sinceMs: Int64, limit: Int = 100) throws -> [ControllerSend] }   // method == message.send, state ∈ {succeeded, unknown}, updated_ms ≥ sinceMs, 按 updated_ms 升序
public struct OriginClassifier {
    public init()
    public mutating func classify(direction: MessageDirection, text: String?, conversation: String?, sends: [ControllerSend]) -> (origin: MessageOrigin, commandId: String?)
}
```
规则：inbound → `peer`；文本等于某条未消费的 `ControllerSend.text`（且 target 等于 conversation 或 conversation 为空）→ `controller` + commandId，并标记消费；outbound 未匹配 → `other`（接管信号）；其余 → `unknown`。

- [ ] **Step 1: 失败测试**

```swift
@Test func recentSendsReturnsSucceededAndUnknownSendsOnly() throws {
    let store = try ControlStore(path: ":memory:")
    var a = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"a","idempotencyKey":"k1"}"#, idempotencyKey: "k1", nowMs: 10)
    try store.insertCommand(a); try store.updateCommand(id: a.id, state: .succeeded, nowMs: 20)
    var b = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"b","idempotencyKey":"k2"}"#, idempotencyKey: "k2", nowMs: 30)
    try store.insertCommand(b); try store.updateCommand(id: b.id, state: .failed, nowMs: 40)
    let c = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 50)
    try store.insertCommand(c); try store.updateCommand(id: c.id, state: .succeeded, nowMs: 60)
    #expect(try store.recentSends(sinceMs: 0).map(\.text) == ["a"])
    #expect(try store.recentSends(sinceMs: 21).isEmpty)
}

@Test func classifierAttributesOnceAndFlagsTakeover() {
    var c = OriginClassifier()
    let sends = [ControllerSend(commandId: "c1", target: "文件传输助手", text: "hi", tsMs: 1)]
    #expect(c.classify(direction: .inbound, text: "hi", conversation: "文件传输助手", sends: sends).origin == .peer)
    let first = c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends)
    #expect(first.origin == .controller && first.commandId == "c1")
    #expect(c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends).origin == .other)
    #expect(c.classify(direction: .outbound, text: "bye", conversation: nil, sends: sends).origin == .other)
    #expect(c.classify(direction: .unknown, text: "zzz", conversation: nil, sends: sends).origin == .unknown)
}
```

- [ ] **Step 2: 确认失败** → **Step 3: 实现** → **Step 4: 通过**
- [ ] **Step 5: Commit** `feat(core): message origin + recent sends query; adapter OriginClassifier (takeover = outbound not ours)`

---

### Task 3: `WeComObserver` + `WatchEngine`；`DaemonWatcher` 改用引擎并接入 AXObserver 去抖

**Files:**
- Create: `Sources/WeComAdapter/Watch/WeComObserver.swift`
- Create: `Sources/WeComAdapter/Watch/WatchEngine.swift`
- Modify: `Sources/imctld/DaemonWatcher.swift`（重写为定时器 + 去抖 + 落库 + 状态文件）
- Modify: `Sources/imctld/main.swift`（`--no-observe`、`--debounce`；策略 enabled 加 `.scrollHistory`）
- Modify: `Sources/imctl/Probe/WatchRunner.swift`（`subscribe()` 改用 `WeComObserver`）
- Test: `Tests/WeComAdapterTests/WeComObserverTests.swift`、`Tests/WeComAdapterTests/WatchEngineTests.swift`

**Interfaces:**
```swift
public struct WeComObserverSubscription { public let observer: AXObserving; public let added: Int; public let unsupported: [String] }
public enum WeComObserver {
    /// app: activated/deactivated/hidden/shown/windowCreated/mainWindowChanged/focusedWindowChanged/focusedUIElementChanged；
    /// window: layoutChanged/titleChanged/created/destroyed；会话表: rowCount/selectedRows/value/created/destroyed/layout；
    /// 消息表（可缺）: rowCount/value/created/destroyed/layout；输入框（可缺）: valueChanged。
    public static func subscribe(to layout: WeComLayout, handler: @escaping (AXNotificationEvent) -> Void) throws -> WeComObserverSubscription
}
public struct WatchDraft: Equatable { public var kind: ControlEventKind; public var payload: [String: String] }
public final class WatchEngine {
    public init(readerProvider: @escaping () throws -> WeComReader, recentSends: @escaping () -> [ControllerSend] = { [] })
    public var relocateEvery: Int   // 默认 60
    public var onRelocated: ((WeComLayout) -> Void)?
    public private(set) var reader: WeComReader?
    public private(set) var previous: WatchSnapshot?
    public private(set) var polls: Int, relocations: Int, errors: Int
    public func invalidate()
    public func poll() throws -> [WatchDraft]   // 抛错 = 客户端不可达；抛错后 reader 置空
}
```
`poll()`：reader 为空则定位并回调 `onRelocated`；取快照；与上一快照 diff；`WatchDiff.observable` 后生成草稿：`conversationChanged` → `conversation.activity{title,fields,preview,timeLabel,badge}`；`activeChanged` → `conversation.activity{activeFrom,activeTo}`；`messageAdded` → `message.observed{conversation,direction,timeLabel,text,origin[,commandId]}`（origin 由 `OriginClassifier` + `recentSends()` 归因，`recentSends` 只在有 `messageAdded` 时调用）；`messagesPrepended`/计数/composer 事件不落库。切换会话、消息表或输入框缺失、每 `relocateEvery` 次轮询 → 下次重定位。

`DaemonWatcher`：`init(store:bundleID:backend:interval:observe:debounce:statePath:log:)`；`start()` 立即 poll 一次并启动定时器；`engine.onRelocated` → `observe` 为真时 `WeComObserver.subscribe`（先 stop 旧订阅）；通知 → 计数 + 去抖 `debounce` 秒后 `poll(trigger: "ax:<name>")`；由通知触发且产生草稿时记录 `observer: <n> event(s) via ax:<name> in <ms> ms`；poll 抛错 → stop 订阅、`system` 暂停；状态文件新增 `notifications`、`lastNotificationMs`、`observer`。

- [ ] **Step 1: 失败测试**

```swift
@Test func subscribesStandardSetAndDeliversTableNotifications() throws {
    let fake = try Fixtures.mainWindow()
    let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
    var got: [String] = []
    let sub = try WeComObserver.subscribe(to: layout) { got.append($0.name) }
    #expect(sub.added >= 20 && sub.unsupported.isEmpty)
    fake.emit(AXNotification.rowCountChanged, on: layout.conversationTable.handle)
    fake.emit(AXNotification.rowCountChanged, on: try #require(layout.messageTable).handle)
    fake.emit(AXNotification.valueChanged, on: try #require(layout.composer).handle)
    #expect(got == [AXNotification.rowCountChanged, AXNotification.rowCountChanged, AXNotification.valueChanged])
    sub.observer.stop()
    fake.emit(AXNotification.rowCountChanged, on: layout.conversationTable.handle)
    #expect(got.count == 3)
}

@Test func engineAttributesAppendedOutboundRowAndIgnoresPrepend() throws {
    let fake = try Fixtures.mainWindow()
    let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
    let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
    let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
    var relocated = 0
    let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) },
                             recentSends: { [ControllerSend(commandId: "c1", target: "文件传输助手", text: "b1", tsMs: 1)] })
    engine.onRelocated = { _ in relocated += 1 }
    #expect(try engine.poll().isEmpty && relocated == 1)          // 基线
    func row(_ text: String, x: CGFloat) -> AXNode { AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [AXNode(role: AXRole.textArea, value: .string(text), frame: CGRect(x: x, y: 160, width: 94, height: 15))])]) }
    var rows = existing.children
    rows.insert(row("b1", x: 1800), at: rows.count - 1)          // 我们发的
    fake.replaceChildren(of: table, with: rows)
    let d1 = try engine.poll()
    #expect(d1.count == 1 && d1[0].kind == .messageObserved && d1[0].payload["origin"] == "controller" && d1[0].payload["commandId"] == "c1")
    rows.insert(row("someone", x: 1800), at: rows.count - 1)    // 人从别处发的
    fake.replaceChildren(of: table, with: rows)
    let d2 = try engine.poll()
    #expect(d2.count == 1 && d2[0].payload["origin"] == "other" && d2[0].payload["direction"] == "outbound")
    rows.insert(contentsOf: [row("old1", x: 380), row("old2", x: 380)], at: 0)   // 历史前插
    fake.replaceChildren(of: table, with: rows)
    #expect(try engine.poll().isEmpty)
}

@Test func engineRelocatesAfterErrorAndEverySixtyPolls() throws {
    let fake = try Fixtures.mainWindow()
    var calls = 0
    let engine = WatchEngine(readerProvider: { calls += 1; if calls == 2 { throw AXKitError.cannotComplete("x") }; return try WeComReader(window: fake.rootElement) })
    engine.relocateEvery = 3
    _ = try engine.poll(); _ = try engine.poll(); _ = try engine.poll()   // 第 3 次后置空
    #expect(throws: AXKitError.self) { try engine.poll() }                 // 第 2 次定位抛错
    _ = try engine.poll()
    #expect(engine.relocations == 2 && engine.errors == 1 && calls == 3)
}
```

- [ ] **Step 2: 确认失败** → **Step 3: 实现（含 DaemonWatcher/main/WatchRunner 改造）** → **Step 4: `swift build` + 测试通过**
- [ ] **Step 5: Commit** `feat(daemon): AXObserver notifications drive imctld polling (debounced) via WatchEngine/WeComObserver; message.observed carries origin`

---

### Task 4: `message.history` 向上滚动读历史（`scrollback`）

**Files:**
- Modify: `Sources/ControlCore/Policy/ActionKind.swift`（`case scrollHistory`，requiresTarget = true）
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`（`HistoryParams.scrollback: Bool?`）
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift`（`messageHistory(limit:scrollback:)`）
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`
- Modify: `Sources/WeComAdapter/WeComLayout.swift`（`messageScrollArea: AXElement?`：消息表的父元素若为 `AXScrollArea` 即是，否则取与消息表相交面积最大的 `AXScrollArea`）
- Modify: `Sources/WeComAdapter/Actions/ActionOutcome.swift`（`ActionError.actionUnavailable(String)`）
- Create: `Sources/WeComAdapter/Actions/Scrollback.swift`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（`message.history` 工具 schema 加 `scrollback`）
- Modify: 三个 fake handler（`CommandExecutorTests`、`DispatcherTests`、`MQTTBindingTests`）签名
- Test: `Tests/WeComAdapterTests/ScrollbackTests.swift`、`Tests/WeComAdapterTests/WeComLayoutTests.swift`、`Tests/ControlCoreTests/ActionPolicyTests.swift`

**Interfaces:**
```swift
public struct ScrollbackOutcome: Equatable, Codable { public var scrolls: Int; public var rowsBefore: Int; public var rowsAfter: Int; public var restored: Bool }
extension WeComActions {
    /// 策略 `.scrollHistory`（活动会话必须在白名单）。每轮：把消息区所有可设 `AXValue` 的 `AXScrollBar` 设为 0（到顶），
    /// 若没有可设的滚动条则 `AXScrollUpByPage` ×3；等待行数增长（verifyTimeout）；连续两轮不增长或达到 maxScrolls 停止。
    /// 结束后把滚动条设回 1（底部）/ 或 `AXScrollDownByPage` 对称次数，尽力而为。不碰输入框。
    public func loadOlderMessages(reader: WeComReader, minRows: Int, maxScrolls: Int = 20) throws -> ScrollbackOutcome
}
```
`WeComCommandHandler.messageHistory(limit:scrollback:)`：`scrollback && count < limit` 时先 `loadOlderMessages(minRows: limit)`，再返回最后 `limit` 行。`CommandExecutor`：`handler.messageHistory(limit: p.limit ?? 50, scrollback: p.scrollback ?? false)`。

- [ ] **Step 1: 失败测试**

```swift
@Test func layoutExposesMessageScrollArea() throws {
    let fake = try Fixtures.mainWindow()
    let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
    #expect(try layout.messageScrollArea?.role() == AXRole.scrollArea)
    #expect(try layout.messageScrollArea?.actions().contains(AXAction.scrollUpByPage) == true)
}

@Test func scrollbackLoadsUntilMinRowsThenRestores() throws {
    let fake = try Fixtures.mainWindow()
    let reader = try WeComReader(window: fake.rootElement)
    let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
    let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
    let existing = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
    var rows = existing.children
    var loads = 0
    fake.reactions["set:AXValue"] = {   // 滚动条被设为 0 → 客户端"加载"两条更早的消息
        guard let last = fake.recordedSets.last, last.value == .double(0) else { return }
        loads += 1
        rows.insert(contentsOf: [AXNode(role: AXRole.row, subrole: "AXTableRow", frame: .init(x: 311, y: 64, width: 1609, height: 60), children: [AXNode(role: AXRole.cell, children: [AXNode(role: AXRole.textArea, value: .string("old-\(loads)-a"), frame: .init(x: 380, y: 70, width: 90, height: 15))])]),
                                 AXNode(role: AXRole.row, subrole: "AXTableRow", frame: .init(x: 311, y: 64, width: 1609, height: 60), children: [AXNode(role: AXRole.cell, children: [AXNode(role: AXRole.textArea, value: .string("old-\(loads)-b"), frame: .init(x: 380, y: 70, width: 90, height: 15))])])], at: 0)
        fake.replaceChildren(of: table, with: rows)
    }
    var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
    actions.verifyTimeout = 0.2; actions.verifyInterval = 0.02
    let out = try actions.loadOlderMessages(reader: reader, minRows: 4)
    #expect(out.rowsBefore == 1 && out.rowsAfter == 5 && out.scrolls == 2 && out.restored)
    #expect(try reader.messages().count == 5)
    #expect(fake.recordedSets.last?.value == .double(1))   // 恢复到底部
}

@Test func scrollbackStopsWhenNothingLoadsAndRefusesUnlistedConversation() throws {
    let fake = try Fixtures.mainWindow()
    let reader = try WeComReader(window: fake.rootElement)
    var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.scrollHistory]))
    actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
    let out = try actions.loadOlderMessages(reader: reader, minRows: 10, maxScrolls: 5)
    #expect(out.rowsAfter == 1 && out.scrolls == 2)   // 两轮不增长即停
    let title = try #require(fake.handle(atPath: [0, 33, 5]))
    fake.mutate(title, attribute: AXAttribute.value, to: .string("someone"))
    let r2 = try WeComReader(window: fake.rootElement)
    #expect(throws: PolicyError.targetNotAllowed("someone")) { try actions.loadOlderMessages(reader: r2, minRows: 3) }
}

@Test func historyWithScrollbackGoesThroughHandler() throws {   // WeComCommandHandlerTests
    let fake = try Fixtures.mainWindow()
    let h = try handler(fake)
    #expect(try h.messageHistory(limit: 5, scrollback: false).count == 1)
    #expect(try h.messageHistory(limit: 1, scrollback: true).count == 1)   // 已够，不滚动
    #expect(fake.recordedSets.isEmpty)
}
```

- [ ] **Step 2: 确认失败** → **Step 3: 实现** → **Step 4: 通过**
- [ ] **Step 5: Commit** `feat(adapter): message.history scrollback loads older rows via AX scroll bar/page actions under scrollHistory policy`

---

### Task 5: `event.replay` 查询（gap 对账的控制器侧）

**Files:**
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`
- Test: `Tests/MCPTransportTests/DispatcherTests.swift`

**Interfaces:** JSON-RPC 方法 `event.replay`，params `{afterEventId: Int (默认 0), limit: Int (默认 200, 上限 1000)}` → result `{events: [{eventId, tsMs, kind, payload}], count, lastEventId}`（`lastEventId` = 存储里的最大 event_id，用来判断是否还有更多）。作为查询直接读 `executor.store`，**不建命令记录、不发 `command.state`**；`tools/list` 增加同名工具（11 个）。

- [ ] **Step 1: 失败测试**

```swift
@Test func eventReplayReadsAfterCursorWithoutCreatingCommands() throws {
    let (d, _) = try make()
    _ = d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"message.send","params":{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}}"#)
    let r = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"event.replay","params":{"afterEventId":1,"limit":10}}"#))
    let result = try #require(r["result"]?.objectValue)
    guard case .array(let events) = try #require(result["events"]) else { Issue.record("events"); return }
    #expect(events.count == 2 && events.first?.objectValue?["eventId"] == .number(2))
    #expect(result["lastEventId"] == .number(3) && result["count"] == .number(2))
    #expect(events.first?.objectValue?["payload"]?.objectValue?["state"] == .string("running"))
    #expect(try d.executor.store.lastEventId() == 3)   // 查询不产生事件
    let list = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
    if case .array(let arr) = try #require(list["result"]?.objectValue?["tools"]) { #expect(arr.count == 11) }
}
```
并把 `initializeAndToolsList` 的 10 改 11。

- [ ] **Step 2–4** → **Step 5: Commit** `feat(transport): event.replay query for consumer gap reconciliation (no command record)`

---

### Task 6: MQTT Response Topic 只允许本机子树（ACL 守卫）

**Files:**
- Modify: `Sources/MQTTTransport/MQTTSettings.swift`（`ownTopicPrefix`）、`Sources/MQTTTransport/MQTTBinding.swift`
- Test: `Tests/MQTTTransportTests/MQTTBindingTests.swift`

**Interfaces:** `MQTTSettings.ownTopicPrefix = "\(topicPrefix)/\(controllerID)/"`；`MQTTBinding.resolvedResponseTopic(_ requested: String?) -> String`：为空或不以 `ownTopicPrefix` 开头 → 缺省 `…/rsp`；否则原样。

- [ ] **Step 1: 失败测试**（改写 `mqtt5ResponseTopicOverridesDefault`）

```swift
@Test func responseTopicMustLiveUnderOwnSubtree() throws {
    let (binding, link, _) = try make()
    _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":2,"method":"account.status"}"#.utf8), responseTopic: "im/mac-01/rsp/java-1", correlationData: nil)
    #expect(link.messages.last?.topic == "im/mac-01/rsp/java-1")
    _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":3,"method":"account.status"}"#.utf8), responseTopic: "java/replies/x", correlationData: nil)
    #expect(link.messages.last?.topic == "im/mac-01/rsp")
}
```

- [ ] **Step 2–4** → **Step 5: Commit** `fix(mqtt): ignore response topics outside im/{id}/ so a per-machine ACL cannot break replies`

---

### Task 7: `imctl agent install|uninstall|status`（LaunchAgent，只写命令，不执行）

**Files:**
- Create: `Sources/imctl/Host/LaunchAgent.swift`（`LaunchAgentSpec`、`LaunchctlStatus`、`Launchctl` 运行器）
- Create: `Sources/imctl/Commands/AgentCommand.swift`
- Modify: `Sources/imctl/IMCTL.swift`（注册 `agent`）
- Test: `Tests/imctlTests/AgentCommandTests.swift`、`Tests/imctlTests/CommandParsingTests.swift`（子命令表加 `agent`）

**Interfaces:**
```swift
struct LaunchAgentSpec: Equatable {
    var label = "com.sunkailun.imctl"; var daemonPath: String; var arguments: [String]; var logDirectory: String
    func plistObject() -> [String: Any]   // Label, ProgramArguments, RunAtLoad=true, KeepAlive={SuccessfulExit:false}, ThrottleInterval=5,
                                          // ProcessType=Interactive, LimitLoadToSessionType=Aqua, StandardOutPath/StandardErrorPath 在 logDirectory 下,
                                          // EnvironmentVariables={IMCTL_LAUNCHD:"1"}
    func plistXML() throws -> String
    static func defaultPlistPath(label:) -> URL   // ~/Library/LaunchAgents/<label>.plist
    static var defaultLogDirectory: URL           // ~/Library/Logs/imctl
    static var defaultDaemonPath: String          // 与当前 imctl 可执行文件同目录的 imctld
}
struct LaunchctlStatus: Equatable { var loaded: Bool; var state: String?; var pid: Int?; var lastExitCode: String?
    static func parse(_ launchctlPrint: String) -> LaunchctlStatus }
enum Launchctl { static var run: ([String]) throws -> (status: Int32, output: String) }   // 测试可替换
```
`agent install [--daemon] [--mqtt] [--socket] [--watch-interval 1] [--no-observe] [--label] [--plist] [--log-dir] [--dry-run] [--no-load]`：校验 daemon 可执行、`--mqtt` 时 `mqtt.json` 存在；建日志目录；写 plist；`launchctl bootout gui/<uid>/<label>`（忽略失败）→ `launchctl bootstrap gui/<uid> <plist>`。`--dry-run` 只打印 plist。`agent uninstall`：bootout + 删 plist。`agent status`：`launchctl print gui/<uid>/<label>` 解析 + plist 是否存在 + 状态文件是否存在。

- [ ] **Step 1: 失败测试**

```swift
@Test func specRendersLaunchdKeys() throws {
    let spec = LaunchAgentSpec(daemonPath: "/x/imctld", arguments: ["run", "--mqtt", "--watch-interval", "1"], logDirectory: "/y/logs")
    let o = spec.plistObject()
    #expect(o["Label"] as? String == "com.sunkailun.imctl")
    #expect(o["ProgramArguments"] as? [String] == ["/x/imctld", "run", "--mqtt", "--watch-interval", "1"])
    #expect(o["RunAtLoad"] as? Bool == true && (o["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
    #expect(o["LimitLoadToSessionType"] as? String == "Aqua" && o["ProcessType"] as? String == "Interactive")
    #expect(o["StandardErrorPath"] as? String == "/y/logs/imctld.log")
    #expect(try spec.plistXML().contains("<key>ProgramArguments</key>"))
}
@Test func installDryRunWritesNothingAndRunsNoLaunchctl() throws {
    var calls: [[String]] = []
    Launchctl.run = { args in calls.append(args); return (0, "") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-agent-\(UUID().uuidString)")
    let cmd = try AgentInstallCommand.parse(["--dry-run", "--daemon", "/usr/bin/true", "--plist", dir.appendingPathComponent("a.plist").path, "--log-dir", dir.path, "--socket", "/tmp/s.sock"])
    let xml = try cmd.render()
    #expect(xml.contains("--socket") && xml.contains("/tmp/s.sock") && !xml.contains("--mqtt"))
    try cmd.run()
    #expect(calls.isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.plist").path))
}
@Test func launchctlPrintIsParsed() {
    let s = LaunchctlStatus.parse("gui/501/com.sunkailun.imctl = {\n\tactive count = 1\n\tpath = /x.plist\n\tstate = running\n\n\tpid = 4242\n\tlast exit code = 0\n}")
    #expect(s.loaded && s.state == "running" && s.pid == 4242 && s.lastExitCode == "0")
    #expect(!LaunchctlStatus.parse("Could not find service \"com.sunkailun.imctl\" in domain for user gui: 501").loaded)
}
```
`CommandParsingTests.rootListsFourSubcommands` 期望表尾加 `"agent"`。

- [ ] **Step 2–4** → **Step 5: Commit** `feat(cli): imctl agent install/uninstall/status renders and manages the LaunchAgent (not installed by default)`

---

### Task 8: 签名脚本与文档（无测试）

**Files:**
- Modify: `scripts/build-signed.sh`：身份选择顺序 `IMCTL_SIGN_IDENTITY` → 本 team 的 "Developer ID Application"（team 匹配 `JVL9CBM345` 或 `FCZGS779KT`）→ "Apple Development"；stderr 打印所选身份；`IMCTL_HARDENED=1` 时加 `--options runtime`；支持 `release`。
- Create: `docs/ops/launchagent.md`：安装决定后的一条命令、验证清单（登录自启、`kill -9` 后 5 s 内重启、TCC 不重弹、`imctl status` 与 retained state 一致、7 天）、卸载、日志位置与轮转说明。
- Create: `docs/ops/emqx-auth-acl.md`：每机用户名 = controller_id，密码随机；EMQX 5.9 内置数据库认证 + 文件/内置授权规则（`{allow, {username, "java"}, publish, ["im/+/cmd"]}`、`{allow, {username, "java"}, subscribe, ["im/+/evt", "im/+/state", "im/+/rsp/#"]}`、`{allow, all, all, ["im/${username}/#"]}`、`{deny, all}`，`no_match = deny`），共享订阅 `$share/<group>/im/+/evt` 需在仪表盘核对是否剥离前缀后再判；`imctl enroll --username <id> --password …` 写入；验证步骤。
- Create: `docs/protocol/java-consumer.md`：Java 最小消费方契约（连接、`$share/<group>/im/+/evt` 订阅、`im/<id>/cmd` 发布 + Response Topic 必须在 `im/<id>/rsp/<instance>` 下、`idempotencyKey` 规则、`message.observed.origin` 语义、gap 对账算法：按 controllerId 记 `lastEventId`，收到 `eventId > last+1` 或 `…/state` 从 offline 变 online 或自身重连时调 `event.replay{afterEventId:last}` 分页补齐，落库以 `(controllerId, eventId)` 唯一去重）。
- Modify: `README.md`（模块表、命令、文档指引）。

- [ ] **Commit** `docs: LaunchAgent/EMQX ACL/Java consumer contracts; build-signed prefers Developer ID when present`

---

### Task 9: 一次测试 + 活体 E2E + 门报告

- [ ] `swift test`（预期 131 + 新增 ≈ 12 个全部通过；`ForbiddenAPITests` 仍只放行 `KeystrokeInjector.swift`）。
- [ ] `scripts/build-signed.sh`（仍用 Apple Development；打印所选身份）。
- [ ] `imctld run --socket /tmp/imctl-b3.sock --watch-interval 1`（有 broker 可达时加 `--mqtt`），日志到 scratchpad。
- [ ] 经 socket：`controller.describe`；`conversation.read 文件传输助手`；`message.history{limit:40}` 与 `message.history{limit:40, scrollback:true}` 行数对比；`event.replay{afterEventId:0,limit:5}`。
- [ ] `message.send`（`imctl-b3-origin-1`）→ succeeded；事件流里 `message.observed` 带 `origin=controller`、`commandId`；日志有 `observer: … via ax:AXRowCountChanged in N ms`。
- [ ] 另一进程 `imctl probe submit --auto --allow-submit imctl-b3-other-1` → imctld 观察到 `origin=other`（模拟"从别处发出"）。
- [ ] `imctl agent install --dry-run --socket /tmp/imctl.sock` 只打印 plist；`ls ~/Library/LaunchAgents | grep imctl` 为空。
- [ ] `kill -TERM`；写 `docs/gates/2026-09-13-b3-observer-history-origin.md`。
- [ ] Commit `docs(gates): B3 e2e …`，push。

## 自审

- 覆盖：下一步 4 的四项 → Task 3 / 4 / 2+3 / 8（Developer ID 只能到"脚本就绪、证书待用户创建"）；下一步 1 → Task 7+8（不安装）；2 → Task 6+8；3 → Task 5+8（组名留空由用户定）。
- 类型一致性：`messageHistory(limit:scrollback:)` 在 Task 4 同时改协议、执行器、三个 fake；`WatchDraft.payload` 为 `[String: String]`，`DaemonWatcher` 用 `JSONValueLite.serialize` 落库；`ControllerSend` 定义在 ControlCore，`OriginClassifier` 在 WeComAdapter。

## 执行结果（2026-09-13 23:3x）

- Task 1–8 完成，155 个测试；E2E 见 `docs/gates/2026-09-13-b3-observer-history-origin.md`（通知→观察 290 ms；origin controller/other 各一例；replay；agent dry-run 未安装）。
- 偏离：(1) 活体发现两处缺陷并修正——`JSONValue` 把 `0/1` 当布尔、消息表超一屏后标题启发式失效（改以滚动区顶为界并排除滚动区内元素）；(2) 加了 `probe scrollback`（`--strategy bar|page`、`--no-restore`）作诊断探针；(3) `AXScrollUpByPage` 活体不可用，只保留滚动条 `AXValue` 路径为主；(4) 文件传输助手未增长行数，"加载更多"待有历史的会话验证；(5) B2 计划中的 broker 地址脱敏。

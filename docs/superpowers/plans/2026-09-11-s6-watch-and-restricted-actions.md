# S6 probe watch + 受限动作（select / compose --clear）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) `imctl probe watch`：轮询 diff 与 AXObserver 通知两条路并行观察会话表/消息区变化，记录延迟与 CPU（G0-4 / G0-5 的工具）；(2) 首批会改变客户端状态的原语——选中会话、输入框设值/清空——经过策略层，只对编译进代码的白名单目标、且只在命令行显式 `--allow-*` 时执行（G0-3 只读部分）。

**Architecture:** 策略在代码里：`ControlCore.ActionPolicy` 用 `ActionKind` × 目标标题判定，白名单 `["文件传输助手"]` 编译进 `WeComAdapter.WeComClient`，`submit` 在阶段 0 无条件拒绝。动作实现 `WeComActions` 每步"设值 → 复核"，复核失败即报错，不重试。观察层：AXKit 加 `AXObserving` 协议（live 用 `AXObserver` + CFRunLoop，fake 可 `emit`），`WeComAdapter.WatchSnapshot/WatchDiff` 是纯函数，对 fake 的 `mutate/replaceChildren` 做单元测试。`probe watch` 把两路事件都写成 JSONL（脱敏），夜间运行也能事后分析。

**Tech Stack:** ApplicationServices `AXObserverCreate/AXObserverAddNotification`，CFRunLoop，`getrusage`。

## Global Constraints

- 只有 `probe select` / `probe compose` 会调用 `setAttribute`；`probe watch` 只读；`performAction` 本任务不调用。
- 白名单外目标一律 `PolicyError.targetNotAllowed`；无 `--allow-*` 一律 `PolicyError.notEnabled`；`submit` 一律 `PolicyError.phaseForbids`。
- 输入框已有内容（人留草稿）→ `local_guard` 中止，不覆盖。
- 动作前后记录 `NSRunningApplication.isActive` 与 frontmost 应用，动作不得把企微拉到前台。

---

### Task 1: `ActionPolicy`（ControlCore）

**Files:**
- Create: `Sources/ControlCore/Policy/ActionKind.swift`
- Create: `Sources/ControlCore/Policy/ActionPolicy.swift`
- Test: `Tests/ControlCoreTests/ActionPolicyTests.swift`

**Interfaces:**

```swift
public enum ActionKind: String, Codable, CaseIterable { case selectConversation, composeText, clearComposer, submit }
public enum PolicyError: Error, Equatable, CustomStringConvertible {
    case notEnabled(ActionKind)           // 命令行没有 --allow-*
    case targetNotAllowed(String)         // 不在白名单
    case phaseForbids(ActionKind)         // 阶段 0：submit
    case targetRequired(ActionKind)
}
public struct ActionPolicy {
    public var allowedTargets: Set<String>
    public var enabled: Set<ActionKind>            // 由 --allow-* 填
    public var phase: Phase = .phase0
    public enum Phase { case phase0, phase1 }
    public init(allowedTargets: Set<String>, enabled: Set<ActionKind> = [], phase: Phase = .phase0)
    /// 顺序：phaseForbids → notEnabled → targetRequired/targetNotAllowed
    public func authorize(_ kind: ActionKind, target: String?) throws
}
```

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import ControlCore

@Suite("ActionPolicy")
struct ActionPolicyTests {
    let allow: Set<String> = ["文件传输助手"]

    @Test func deniesEverythingByDefault() {
        let p = ActionPolicy(allowedTargets: allow)
        #expect(throws: PolicyError.notEnabled(.selectConversation)) { try p.authorize(.selectConversation, target: "文件传输助手") }
        #expect(throws: PolicyError.notEnabled(.composeText)) { try p.authorize(.composeText, target: "文件传输助手") }
    }

    @Test func enabledStillRequiresAllowlistedTarget() {
        let p = ActionPolicy(allowedTargets: allow, enabled: [.selectConversation])
        #expect(throws: PolicyError.targetNotAllowed("张三")) { try p.authorize(.selectConversation, target: "张三") }
        #expect(throws: PolicyError.targetRequired(.selectConversation)) { try p.authorize(.selectConversation, target: nil) }
        #expect(throws: Never.self) { try p.authorize(.selectConversation, target: "文件传输助手") }
    }

    @Test func submitIsForbiddenInPhase0EvenWhenEnabled() {
        let p = ActionPolicy(allowedTargets: allow, enabled: [.submit])
        #expect(throws: PolicyError.phaseForbids(.submit)) { try p.authorize(.submit, target: "文件传输助手") }
    }

    @Test func clearComposerNeedsNoTargetButNeedsEnable() {
        #expect(throws: PolicyError.notEnabled(.clearComposer)) { try ActionPolicy(allowedTargets: allow).authorize(.clearComposer, target: nil) }
        #expect(throws: Never.self) { try ActionPolicy(allowedTargets: allow, enabled: [.clearComposer]).authorize(.clearComposer, target: nil) }
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(core): add ActionPolicy with compiled allowlist semantics`

### Task 2: `AXObserving`（AXKit）

**Files:**
- Create: `Sources/AXKit/AXObserving.swift`（协议 + `AXNotification` 常量）
- Modify: `Sources/AXKit/AXBackend.swift`（加 `func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving`）
- Modify: `Sources/AXKit/FakeAXBackend.swift`（`FakeAXObserver`，`emit(_:on:)`）
- Modify: `Sources/AXKit/LiveAXBackend.swift`（`LiveAXObserver`：`AXObserverCreate`，`AXObserverAddNotification`，run loop source 加到 `CFRunLoopGetMain()`）
- Test: `Tests/AXKitTests/AXObservingTests.swift`

**Interfaces:**

```swift
public struct AXNotificationEvent: Equatable { public var name: String; public var element: AXElementHandle; public var timestamp: Date }
public protocol AXObserving: AnyObject {
    func add(_ notification: String, to element: AXElementHandle) throws
    func remove(_ notification: String, from element: AXElementHandle) throws
    func stop()
}
public enum AXNotification {
    public static let valueChanged = "AXValueChanged", rowCountChanged = "AXRowCountChanged",
        selectedRowsChanged = "AXSelectedRowsChanged", created = "AXCreated", destroyed = "AXUIElementDestroyed",
        layoutChanged = "AXLayoutChanged", focusedUIElementChanged = "AXFocusedUIElementChanged",
        titleChanged = "AXTitleChanged", windowCreated = "AXWindowCreated", applicationActivated = "AXApplicationActivated",
        applicationDeactivated = "AXApplicationDeactivated", applicationHidden = "AXApplicationHidden", applicationShown = "AXApplicationShown"
}
extension FakeAXBackend { public func emit(_ notification: String, on element: AXElementHandle) }   // 只送给已 add 的 (notification, element)
```

- [ ] **Step 1: 写失败测试**

```swift
@Suite("AXObserving (fake)")
struct AXObservingTests {
    @Test func fakeDeliversOnlySubscribedPairs() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        var got: [AXNotificationEvent] = []
        let observer = try fake.makeObserver(pid: fake.pid) { got.append($0) }
        let table = try #require(fake.handle(atPath: [0, 0]))
        try observer.add(AXNotification.rowCountChanged, to: table)
        fake.emit(AXNotification.rowCountChanged, on: table)
        fake.emit(AXNotification.valueChanged, on: table)            // not subscribed
        fake.emit(AXNotification.rowCountChanged, on: fake.rootHandle) // other element
        #expect(got.map(\.name) == [AXNotification.rowCountChanged])
        try observer.remove(AXNotification.rowCountChanged, from: table)
        fake.emit(AXNotification.rowCountChanged, on: table)
        #expect(got.count == 1)
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(axkit): add AXObserving with fake and live observers`

### Task 3: `WatchSnapshot` / `WatchDiff`（WeComAdapter）

**Files:**
- Create: `Sources/WeComAdapter/Watch/WatchSnapshot.swift`
- Create: `Sources/WeComAdapter/Watch/WatchDiff.swift`
- Test: `Tests/WeComAdapterTests/WatchDiffTests.swift`

**Interfaces:**

```swift
public struct WatchSnapshot: Equatable, Codable {
    public struct Conversation: Equatable, Codable { var index: Int; var title: String?; var preview: String?; var timeLabel: String?; var badge: String?; var selected: Bool }
    public struct Message: Equatable, Codable { var index: Int; var text: String?; var timeLabel: String?; var direction: String; var y: Double }
    public var active: String?
    public var conversations: [Conversation]
    public var messages: [Message]
    public var composerLength: Int
    public static func take(_ reader: WeComReader) throws -> WatchSnapshot
}
public enum WatchEvent: Equatable, Codable {
    case activeChanged(from: String?, to: String?)
    case conversationChanged(index: Int, title: String?, fields: [String])   // fields ⊆ [title, preview, timeLabel, badge, selected]
    case conversationCountChanged(from: Int, to: Int)
    case messageAdded(index: Int, direction: String, timeLabel: String?)
    case messageChanged(index: Int, fields: [String])
    case messageCountChanged(from: Int, to: Int)
    case composerChanged(from: Int, to: Int)
    public var summary: String
}
public enum WatchDiff { public static func compare(_ old: WatchSnapshot, _ new: WatchSnapshot) -> [WatchEvent] }
```

比较规则：会话按 `index` 对齐（行数不同先报 `conversationCountChanged`，再对齐比较公共前缀）；消息按 `index` 对齐，新增尾部行报 `messageAdded`。

- [ ] **Step 1: 写失败测试（用 fixture + fake.mutate/replaceChildren）**

```swift
@Suite("WatchDiff")
struct WatchDiffTests {
    @Test func noChangeNoEvents() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let a = try WatchSnapshot.take(r), b = try WatchSnapshot.take(r)
        #expect(WatchDiff.compare(a, b).isEmpty)
    }

    @Test func previewMutationYieldsConversationChanged() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let before = try WatchSnapshot.take(r)
        // row #2 (文件传输助手) preview = cell child 2
        let preview = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0, 2]))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("new preview"))
        let after = try WatchSnapshot.take(r)
        #expect(WatchDiff.compare(before, after) == [.conversationChanged(index: 2, title: "文件传输助手", fields: ["preview"])])
    }

    @Test func appendedMessageRowYieldsMessageAdded() throws {
        let fake = try Fixtures.mainWindow()
        let r = try WeComReader(window: fake.rootElement)
        let before = try WatchSnapshot.take(r)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let existing = try #require(AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())).first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        var rows = existing.children
        rows.insert(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 151, width: 1609, height: 60), children: [
                AXNode(role: AXRole.textArea, value: .string("hi"), frame: CGRect(x: 380, y: 160, width: 100, height: 15)),
            ]),
        ]), at: rows.count - 1) // before the trailing AXColumn
        fake.replaceChildren(of: table, with: rows)
        let after = try WatchSnapshot.take(r)
        let events = WatchDiff.compare(before, after)
        #expect(events.contains(.messageCountChanged(from: 1, to: 2)))
        #expect(events.contains(.messageAdded(index: 1, direction: "inbound", timeLabel: nil)))
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(adapter): add watch snapshots and diff`

### Task 4: `WeComActions`（select / compose / clear，带复核）

**Files:**
- Create: `Sources/WeComAdapter/Actions/WeComActions.swift`
- Create: `Sources/WeComAdapter/Actions/ActionOutcome.swift`
- Test: `Tests/WeComAdapterTests/WeComActionsTests.swift`

**Interfaces:**

```swift
public enum ActionError: Error, Equatable, CustomStringConvertible {
    case targetNotFound(String), targetAmbiguous(String, count: Int), targetMismatch(expected: String, actual: String?)
    case localGuard(String)            // 输入框非空等
    case verifyFailed(String)          // 设值后读回不符
    case notSettable(String)
}
public struct ActionOutcome: Equatable, Codable {
    public var kind: String; public var target: String?; public var verified: Bool; public var details: [String: String]
}
public struct WeComActions {
    public var policy: ActionPolicy
    public init(policy: ActionPolicy)
    /// locate（精确标题匹配，0/多个报错）→ set AXSelectedRows=[row] → verify_target：重新定位布局，活动标题 == title
    public func selectConversation(_ title: String, reader: WeComReader) throws -> ActionOutcome
    /// precheck_input：composer 为空否则 localGuard → set AXValue → verify 读回 == text；target = 当前活动标题（必须在白名单）
    public func composeText(_ text: String, reader: WeComReader) throws -> ActionOutcome
    /// set AXValue "" → verify 空；不做 precheck（就是为了清掉我们自己写的）
    public func clearComposer(reader: WeComReader) throws -> ActionOutcome
}
```

- [ ] **Step 1: 写失败测试（fake 上：记录的 set、策略拒绝、local_guard、复核）**

```swift
@Suite("WeComActions on fake")
struct WeComActionsTests {
    func policy(_ enabled: Set<ActionKind>) -> ActionPolicy {
        ActionPolicy(allowedTargets: [WeComClient.fileTransferAssistantTitle], enabled: enabled)
    }

    @Test func selectSetsSelectedRowsAndVerifiesActiveTitle() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let out = try WeComActions(policy: policy([.selectConversation])).selectConversation("文件传输助手", reader: reader)
        #expect(out.verified)
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].attribute == AXAttribute.selectedRows)
        #expect(fake.recordedSets[0].value.elementsValue?.count == 1)
    }

    @Test func selectRefusesTargetsOutsideAllowlistBeforeTouchingAX() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        #expect(throws: PolicyError.targetNotAllowed("«b8e3a1b8»")) {
            try WeComActions(policy: policy([.selectConversation])).selectConversation("«b8e3a1b8»", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func composeThenClearRoundTrip() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let actions = WeComActions(policy: policy([.composeText, .clearComposer]))
        let composed = try actions.composeText("imctl-probe", reader: reader)
        #expect(composed.verified && composed.target == "文件传输助手")
        #expect(try reader.composerValue() == "imctl-probe")
        #expect(throws: ActionError.localGuard("composer not empty")) { try actions.composeText("again", reader: reader) }
        let cleared = try actions.clearComposer(reader: reader)
        #expect(cleared.verified)
        #expect(try reader.composerValue() == "")
        #expect(fake.recordedSets.map(\.attribute) == [AXAttribute.value, AXAttribute.value])
    }

    @Test func composeRefusesWhenActiveConversationNotAllowlisted() throws {
        let fake = try Fixtures.mainWindow()
        let title = try #require(fake.handle(atPath: [0, 33, 5]))
        fake.mutate(title, attribute: AXAttribute.value, to: .string("someone"))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(throws: PolicyError.targetNotAllowed("someone")) {
            try WeComActions(policy: policy([.composeText])).composeText("x", reader: reader)
        }
        #expect(fake.recordedSets.isEmpty)
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(adapter): add policy-gated select/compose/clear actions with verification`

### Task 5: CLI `probe watch` / `probe select` / `probe compose`

**Files:**
- Create: `Sources/imctl/Commands/ProbeWatchCommand.swift`
- Create: `Sources/imctl/Commands/ProbeActionCommands.swift`（`ProbeSelectCommand`、`ProbeComposeCommand`）
- Create: `Sources/imctl/Probe/WatchRunner.swift`（轮询 + 观察者 + JSONL 日志 + rusage）
- Modify: `Sources/imctl/Commands/ProbeCommand.swift`（注册三个子命令）
- Test: `Tests/imctlTests/ProbeActionCommandTests.swift`

**Interfaces:**
- `imctl probe watch [--seconds 60] [--interval 1.0] [--mode both|poll|observer] [--log <path.jsonl>] [--no-redact]`：每次 diff 事件打印 `<ISO> poll <event.summary>`，观察者通知打印 `<ISO> ax <name> <role>`；结束打印 `polls=<n> events=<n> notifications=<n by name> cpu_user=<s> cpu_sys=<s> max_poll_ms=<n>`；`--log` 每行 `{"t":…, "source":"poll|ax", "event":…}`。运行中每次 poll 也检查 `HostProbe.screenLocked()` 变化并记录 `lock` 事件。
- `imctl probe select --allow-select <title> [--from-fixture]`：策略 enabled=[selectConversation]；打印 outcome JSON；前后各打印 `client_active=<bool> frontmost=<bundle>`。
- `imctl probe compose --allow-compose <text> [--clear] [--from-fixture]`：策略 enabled=[composeText (+clearComposer)]；设值后重扫窗口查找新增的 `AXButton`（相对设值前的按钮集合）并打印其 title/description/frame（找"发送"按钮）；`--clear` 时清空并复核。

- [ ] **Step 1: 写失败测试**

```swift
@Suite("probe action commands")
struct ProbeActionCommandTests {
    @Test func selectRequiresAllowFlag() {
        #expect(throws: (any Error).self) { try ProbeSelectCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]) }
    }
    @Test func composeFromFixtureRoundTrips() throws {
        let cmd = try ProbeComposeCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--allow-compose", "imctl-probe", "--clear"])
        let out = try cmd.collect()
        #expect(out.composed.verified && out.cleared?.verified == true)
        #expect(out.newButtons.isEmpty)
    }
    @Test func watchRegistered() {
        let sub = ProbeCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["conversations", "messages", "watch", "select", "compose"])
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS。**
- [ ] **Step 3: live（企微在另一 Space、非前台）：**
  1. `probe watch --seconds 60 --mode both`（同时手机向文件传输助手发一条）→ 记录通知名、poll 延迟。
  2. `probe select --allow-select 文件传输助手`。
  3. `probe compose --allow-compose "imctl-probe" --clear`。
  4. 写 `docs/gates/2026-09-11-s6-actions-and-watch.md`（G0-3 只读部分、G0-5 通知 vs 轮询、CPU）。
- [ ] **Step 4: 提交** `feat(cli): add probe watch/select/compose with gate note`

## Self-Review

- 覆盖：AXObserver vs 轮询（T2/T3/T5）、延迟与 CPU（T5 rusage 与 max_poll_ms）、select/compose --clear（T4/T5）、白名单 + `--allow-*`（T1/T5）、白名单外拒绝（T1/T4 测试）。
- 类型一致：`ActionPolicy.authorize(_:target:)` 在 T1 定义，T4 调用；`WatchSnapshot.take(_:)` 在 T3 定义，T5 使用；`AXNotification` 常量在 T2 定义，T5 订阅。

## 执行结果（2026-09-11）

- 5 个任务完成，`swift test` 68 个测试通过；live 结果见 `docs/gates/2026-09-11-s6-actions-and-watch.md`。
- 偏离：活动会话无输入框时 `WeComLayout.composer` 为 nil（新增 no-composer 夹具与测试）；`probe select` 在真实"切换"场景下验证（活动会话原本是另一会话）。

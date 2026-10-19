# 批次 B6：安装包（`.pkg`）、测试控制台（菜单栏 SwiftUI 应用）与菜单驱动会话导航 `client.navigate` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 产出可安装的 `.pkg`（`/Applications/imctl.app`：控制台 + `imctl` CLI + `imctld` 守护进程），一个经守护进程本地套接字执行全部协议命令、看状态 / 事件 / 策略并做只读诊断的测试控制台，以及一个经客户端自身「窗口」菜单实现的确定性会话切换方法 `client.navigate`；顺带修复"会话筛选侧栏打开时布局定位选错会话表"的活体缺陷。

**Architecture:** 三条线。(1) 协议 / 适配器：`RPCMethod.clientNavigate` + `NavigateAction` → `CommandHandler.clientNavigate` → `WeComActions.navigate`（`WeComMenuBar` 在应用元素的 `AXMenuBar` 里找到 `窗口 › 选择下一个会话` 等菜单项后 `AXPress`，前后活动标题作证据）；`WeComLayout.locate` 用"高度 ≥ 半窗"选会话表。(2) 本地通道：`MCPTransport.UnixSocketClient`（每次调用一条连接的行分隔 JSON-RPC 客户端）供控制台与新 CLI `imctl call` 使用；`imctl agent install` 默认带 `--socket`；`state.json` 增 `trusted` / `socket`。(3) 控制台与打包：新可执行 target `imctl-console`（SwiftUI `MenuBarExtra` + 控制台窗口；改变客户端状态一律经守护进程套接字，自身只做只读 AX 诊断与本机配置文件写入）；`scripts/build-app.sh` 组装签名的 `imctl.app`，`scripts/build-pkg.sh` 生成 `.pkg`（有 Developer ID Installer 与 notary profile 时签名 + 公证，否则开发版未签名包）。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，SwiftUI（macOS 15+，`@Observable`），swift-testing，POSIX Unix socket，`pkgbuild` / `productbuild` / `codesign` / `notarytool`。

## Global Constraints

- 白名单编译在 `WeComClient.fileTransferAssistantTitle`，扩大只能经 `policy.json` 并由用户明确授权；开发期只对用户自己的测试群与本人微信作测试客户；不向真实客户 / 客户群发消息。
- 除 `KeystrokeInjector` 的 pid 级回车外不发合成事件：`client.navigate` 是 `AXPress` 客户端自己的菜单项；`ForbiddenAPITests` 继续拦截。不申请录屏 / 输入监控。
- 控制台不绕过执行器：切换 / 发送 / 导航 / 暂停只经 `imctld` 套接字（策略、幂等、速率、事件与 Java 路径完全一致）；控制台进程内只做只读 AX（布局探针、菜单列表）与本机配置文件写入（`mqtt.json` / `wecom-proxy.json`，0600）。
- 控制台是运维 / 测试工具，不是 LLM 驱动的自主控制器（用户 2026-09-15：模型仍只在 Java 侧）。
- `client.navigate` 只允许编译进代码的三个菜单项（`选择下一个会话` / `选择上一个会话` / `选择下一个未读会话`，客户端中文本地化）；找不到 → `UNSUPPORTED`；必须带 `idempotencyKey`（MQTT QoS 1 重投不会多走一步）；受暂停集合约束（同 `conversation.read`）。
- 安装包不碰 launchd 与 TCC：守护进程安装与授权由控制台 / CLI 在用户会话内完成；`postinstall` 只做 `/usr/local/bin/imctl` 符号链接，无权限即跳过。
- 签名：开发用 Apple Development（团队 `JVL9CBM345`，`scripts/build-signed.sh` 既有选择逻辑），`.pkg` 未签名，本机 `installer` 安装；`IMCTL_HARDENED=1 IMCTL_INSTALLER_IDENTITY=… IMCTL_NOTARY_PROFILE=…` 时同一脚本产出 hardened + 公证版。
- 不提交 `out/`；夹具脱敏（`dump-tree --keep` 只保留 UI 文案）；仓库不含 broker 地址、凭据、真实联系人、本机绝对路径。
- 协议文档 `docs/protocol/im-control-protocol.md` 与代码同一提交；`ProtocolDocTests` 兜底。
- 工作方式（用户约定）：批量实现，逐任务只做编译检查，最后一次 `swift test`；活体只对 文件传输助手 与「窗口」菜单导航（导航后恢复原会话）。

---

### Task 1: 布局修复——会话筛选侧栏不再遮蔽会话表

**Files:**
- Modify: `Sources/WeComAdapter/WeComLayout.swift:31-34`
- Create: `Tests/Fixtures/ax-trees/wecom-5.0.11-filter-panel.json`
- Test: `Tests/WeComAdapterTests/WeComLayoutTests.swift`

**Interfaces:**
- Produces: `WeComLayout.locate(in:)` 语义——会话表 = 高度 ≥ 窗口高一半的最左表；消息表 = 会话表右侧最宽的表（不再要求高）。

活体事实（2026-09-15，5.0.11）：主窗口左侧可展开 160 px 的会话筛选面板（未读 / @我 / 单聊 / 群聊 / 内部聊天 / 外部聊天 / 标记），它本身是一张 `AXTable`（frame ≈ (-1, 484, 162×242)，行高 8 / 32），位于会话表（159, 63, 252×1138）左侧；`locate` 按 `minX` 取第一张表就选中了它，`probe conversations` 因而输出 32 px 的筛选行、找不到 文件传输助手。

- [ ] **Step 1: 录制脱敏夹具**

```bash
.build/arm64-apple-macosx/debug/imctl dump-tree --root main-window \
  --keep 文件传输助手 未读 @我 单聊 群聊 内部聊天 外部聊天 标记 \
  --output Tests/Fixtures/ax-trees/wecom-5.0.11-filter-panel.json
# 消息表几十行只占体积：只留前 3 行
python3 - <<'EOF'
import json
p='Tests/Fixtures/ax-trees/wecom-5.0.11-filter-panel.json'
d=json.load(open(p)); root=d.get('root', d)
def tables(n, acc):
    if n.get('role')=='AXTable': acc.append(n)
    for c in n.get('children', []) or []: tables(c, acc)
acc=[]; tables(root, acc)
widest=max(acc, key=lambda t: (t.get('frame') or {}).get('width', 0))
rows=[c for c in widest['children'] if c.get('role')=='AXRow']
keep=rows[:3]; widest['children']=[c for c in widest['children'] if c.get('role')!='AXRow']+keep
json.dump(d, open(p,'w'), ensure_ascii=False, indent=1)
EOF
grep -c '«' Tests/Fixtures/ax-trees/wecom-5.0.11-filter-panel.json   # 脱敏 token 存在；无真实标题
```

- [ ] **Step 2: 失败测试（追加到 `WeComLayoutTests`）**

```swift
    @Test func filterSidePanelDoesNotShadowTheConversationList() throws {
        // 2026-09-15, 5.0.11: the 会话筛选 side panel is a 242 px tall AXTable left of the conversation list.
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-filter-panel.json")))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(Int(layout.conversationTableFrame.minX) == 159 && Int(layout.conversationTableFrame.height) == 1138)
        #expect((layout.messageTableFrame?.width ?? 0) > 1000)
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        let rows = try reader.conversations()
        #expect(rows.count == 11 && rows.allSatisfy { $0.frame.height == 64 })
        #expect(rows.contains { $0.title == "文件传输助手" && $0.selected })
    }

    @Test func shortMessageTableIsStillTheMessageTable() throws {
        // Few messages loaded: the message table is short; only the conversation table must be tall.
        let fake = try Fixtures.mainWindow()
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.mutate(table, attribute: AXAttribute.frame, to: .rect(CGRect(x: 310, y: 63, width: 1611, height: 150)))
        let layout = try WeComLayout.locate(in: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(Int(layout.messageTableFrame?.height ?? 0) == 150 && Int(layout.conversationTableFrame.minX) == 59)
    }
```

- [ ] **Step 3: 运行，确认失败**

Run: `swift test --filter WeComLayoutTests`
Expected: FAIL（`conversationTableFrame.minX` 为 -1；`activeConversationTitle` 不是 文件传输助手）

- [ ] **Step 4: 实现（替换 `WeComLayout.locate` 的表选择）**

```swift
        // The 会话筛选 side panel (2026-09-15, 5.0.11) is a 160 px split pane at the
        // window's left edge whose filter list is also an AXTable, but only ~240 px
        // tall; the conversation list always spans the window. The message table
        // can be short (few rows loaded), so only the conversation pick needs height.
        let tables = candidates.filter { $0.role == AXRole.table }.sorted { $0.frame.minX < $1.frame.minX }
        let tall = tables.filter { $0.frame.height >= windowFrame.height / 2 }
        guard let conversation = tall.first else { throw WeComError.region("conversationTable") }
        let message = tables.filter { $0.frame.minX > conversation.frame.minX }.max(by: { $0.frame.width < $1.frame.width })
```

- [ ] **Step 5: 运行，确认通过**

Run: `swift test --filter WeComLayoutTests`
Expected: PASS（含既有 4 个用例）

---

### Task 2: 协议 `client.navigate`

**Files:**
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`（`RPCMethod`、`NavigateAction`、`NavigateParams`）
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift`
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`（暂停门、路由分支）
- Modify: `Sources/ControlCore/Policy/ActionKind.swift`
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（`toolDescriptors` 28）
- Modify: `docs/protocol/im-control-protocol.md`（§6.11、§12）
- Test: `Tests/ControlCoreTests/ProtocolTests.swift`、`Tests/ControlCoreTests/CommandExecutorTests.swift`、`Tests/MCPTransportTests/DispatcherTests.swift`；伪处理器补方法：`Tests/MQTTTransportTests/MQTTBindingTests.swift`

**Interfaces:**
- `RPCMethod.clientNavigate = "client.navigate"`（声明在 `controllerResume` 之后、`groupList` 之前）；`requiresIdempotencyKey` 为 `messageSend || broadcastCreate || clientNavigate`；`isWeComAPI == false`
- `public enum NavigateAction: String, Codable, CaseIterable { case nextConversation, previousConversation, nextUnreadConversation }`
- `public struct NavigateParams: Codable, Equatable { var action: NavigateAction; var idempotencyKey: String }`
- `CommandHandler.clientNavigate(action: NavigateAction) throws -> [String: String]`（结果键 `action` / `before` / `after` / `changed`）
- `ActionKind.navigate`（`requiresTarget == false`）

- [ ] **Step 1: 失败测试**

```swift
// ProtocolTests：两处 26 → 27；idempotency 列表
        #expect(RPCMethod.allCases.count == 27)
        #expect(RPCMethod.allCases.filter(\.requiresIdempotencyKey) == [.messageSend, .clientNavigate, .broadcastCreate])
// ProtocolTests 追加
    @Test func clientNavigateIsAClientMethodWithThreeActions() throws {
        #expect(RPCMethod(rawValue: "client.navigate") == .clientNavigate && !RPCMethod.clientNavigate.isWeComAPI)
        #expect(NavigateAction.allCases.map(\.rawValue) == ["nextConversation", "previousConversation", "nextUnreadConversation"])
        let p = try JSONDecoder().decode(NavigateParams.self, from: Data(#"{"action":"nextUnreadConversation","idempotencyKey":"n1"}"#.utf8))
        #expect(p == NavigateParams(action: .nextUnreadConversation, idempotencyKey: "n1"))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NavigateParams.self, from: Data(#"{"action":"messagesView","idempotencyKey":"n1"}"#.utf8)) }
        #expect(!ActionKind.navigate.requiresTarget && ActionKind.allCases.count == 8)
    }

// CommandExecutorTests：FakeHandler 追加
    var navigations: [NavigateAction] = []
    func clientNavigate(action: NavigateAction) throws -> [String: String] {
        navigations.append(action)
        return ["action": action.rawValue, "before": "a", "after": "b", "changed": "true"]
    }
// CommandExecutorTests 追加
    @Test func clientNavigateNeedsKeyRespectsPauseAndRoutesToHandler() throws {
        let (exec, handler, store) = try make()
        let params = #"{"action":"nextConversation","idempotencyKey":"n1"}"#
        #expect(throws: ControlError.invalidParams("client.navigate requires idempotencyKey")) {
            try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: nil)
        }
        let ok = try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: "n1")
        #expect(ok.state == .succeeded && ok.resultJSON?.contains(#""changed":"true""#) == true && handler.navigations == [.nextConversation])
        // same key replays the record without a second press
        #expect(try exec.submit(method: .clientNavigate, paramsJSON: params, idempotencyKey: "n1").id == ok.id && handler.navigations.count == 1)
        let bad = try exec.submit(method: .clientNavigate, paramsJSON: #"{"action":"messagesView","idempotencyKey":"n2"}"#, idempotencyKey: "n2")
        #expect(bad.state == .failed && bad.errorCode == "INVALID_PARAMS" && handler.navigations.count == 1)
        try store.setPause(.api, on: true, nowMs: 5)
        let paused = try exec.submit(method: .clientNavigate, paramsJSON: params.replacingOccurrences(of: "n1", with: "n3"), idempotencyKey: "n3")
        #expect(paused.state == .failed && paused.errorCode == "PAUSED" && handler.navigations.count == 1)
    }

// DispatcherTests：27 → 28；DispatchFakeHandler 追加
    func clientNavigate(action: NavigateAction) throws -> [String: String] { ["action": action.rawValue, "changed": "false"] }
// MQTTBindingTests.BindingFakeHandler 追加同一方法
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift build --build-tests`
Expected: 编译错误（`clientNavigate` / `NavigateAction` 未定义）

- [ ] **Step 3: 实现**

`RPCTypes.swift`：

```swift
    case controllerResume = "controller.resume"
    /// Deterministic client navigation through the client's own 窗口 menu (B6).
    case clientNavigate = "client.navigate"
    // WeCom official-API route (through the token-injecting proxy), B5.
    …
    /// Methods that change client or platform state and therefore need an idempotency key.
    public var requiresIdempotencyKey: Bool { self == .messageSend || self == .broadcastCreate || self == .clientNavigate }

/// Relative navigation the client offers under its 窗口 menu. Menu-driven on
/// purpose: the items are the client's own commands, so no synthetic input.
public enum NavigateAction: String, Codable, CaseIterable {
    case nextConversation
    case previousConversation
    case nextUnreadConversation
}

public struct NavigateParams: Codable, Equatable {
    public var action: NavigateAction
    public var idempotencyKey: String
    public init(action: NavigateAction, idempotencyKey: String) { self.action = action; self.idempotencyKey = idempotencyKey }
}
```

`CommandHandler.swift`：

```swift
    /// Presses the client's own menu item for `action`; result keys `action`,
    /// `before`, `after` (active titles) and `changed` ("true"/"false").
    func clientNavigate(action: NavigateAction) throws -> [String: String]
```

`ActionKind.swift`：

```swift
    /// `AXPress` on one of the client's own 窗口 menu items (next / previous / next unread conversation); no target.
    case navigate
    …
        case .clearComposer, .confirmBroadcast, .navigate: return false
```

`CommandExecutor.swift`：暂停门 `if method == .messageSend || method == .conversationRead || method == .clientNavigate {`；`execute` 在 `.conversationRead` 分支后加

```swift
        case .clientNavigate:
            let p = try decode(NavigateParams.self, from: paramsJSON)
            return (.succeeded, try encode(try handler.clientNavigate(action: p.action)))
```

`RPCDispatcher.toolDescriptors`：在 `controller.resume` 之后加

```swift
            ("client.navigate", "Press one of the client's own 窗口 menu items (nextConversation | previousConversation | nextUnreadConversation); needs idempotencyKey; result = before/after active titles and changed", schema(["action": ("string", "nextConversation | previousConversation | nextUnreadConversation"), "idempotencyKey": ("string", "Caller-generated unique key")], required: ["action", "idempotencyKey"])),
```

`docs/protocol/im-control-protocol.md`：§6.11 由「保留」改为

```markdown
### 6.11 `client.navigate`

参数 `{action, idempotencyKey（必填）}`，`action ∈ {nextConversation, previousConversation, nextUnreadConversation}`。按客户端自己的「窗口」菜单项切换活动会话（`AXPress` 菜单项，不是合成按键；改变客户端状态，经策略 `navigate` 与暂停集合）。结果：`{action, before, after, changed:"true"|"false"}`——`before` / `after` 为切换前后的活动会话标题，`nextUnreadConversation` 没有未读时 `changed:"false"` 不算失败。菜单项不存在（非中文本地化、无主窗口）→ `failed` + `UNSUPPORTED`。`account.changed` 事件已定义未使用（见 7.2）。
```

§12 追加行 `| 2026-09-15 | B6：\`client.navigate\`（窗口菜单导航）、\`state.json\` 增 \`trusted\` / \`socket\`；控制台与安装包不改 wire 协议 |`。

- [ ] **Step 4: 编译检查**

Run: `swift build --build-tests`
Expected: 成功（全量测试在 Task 8）

---

### Task 3: 适配器——`WeComMenuBar`、`WeComActions.navigate`、处理器 `clientNavigate`、`probe menubar`

**Files:**
- Create: `Sources/WeComAdapter/WeComMenuBar.swift`
- Create: `Sources/WeComAdapter/Actions/Navigate.swift`
- Modify: `Sources/AXKit/AXConstants.swift`（`AXRole.menuBar` / `menuBarItem`）
- Modify: `Sources/AXKit/FakeAXBackend.swift`（应用节点派生 `AXMainWindow` / `AXFocusedWindow` / `AXWindows`）
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Modify: `Sources/imctld/main.swift`（策略 `enabled` 增 `.navigate`）
- Create: `Sources/imctl/Commands/ProbeMenuBarCommand.swift`；Modify: `Sources/imctl/Commands/ProbeCommand.swift`（注册 `menubar`）、`Sources/imctl/Probe/ProbeSession.swift`（`root(_:)`）
- Create: `Tests/Fixtures/ax-trees/wecom-5.0.11-app-menubar.json`
- Test: Create `Tests/WeComAdapterTests/NavigateTests.swift`；Modify `Tests/AXKitTests/FakeAXBackendTests.swift`、`Tests/WeComAdapterTests/WeComCommandHandlerTests.swift`、`Tests/imctlTests/ProbeCommandTests.swift`

**Interfaces:**
- `AXRole.menuBar = "AXMenuBar"`, `AXRole.menuBarItem = "AXMenuBarItem"`
- `public struct MenuItemInfo: Codable, Equatable { public var title: String; public var enabled: Bool? }`
- `WeComMenuBar.windowMenuTitle = "窗口"`; `WeComMenuBar.items(in app: AXElement, menu: String) throws -> [MenuItemInfo]`; `WeComMenuBar.menuItem(in app: AXElement, menu: String, item: String) throws -> AXElement`（都对非应用根抛 `WeComError.region("menuBar")`）
- `WeComActions.navigateMenuItems: [NavigateAction: String]`; `WeComActions.navigate(_ action: NavigateAction, app: AXElement, reader: WeComReader) throws -> ActionOutcome`
- `WeComCommandHandler.clientNavigate(action:)`
- CLI：`imctl probe menubar [--menu 窗口] [--from-fixture …] [--json]`（只读）

活体事实（2026-09-15，5.0.11）：应用元素子节点 = `[AXWindow, AXMenuBar, AXMenuBar]`；「窗口」菜单项 `选择下一个会话` / `选择上一个会话` / `选择下一个未读会话` 在客户端非前台时报告 `AXEnabled=false`，此时 `AXPress` 返回成功但**不切换**（执行中实测；最初"能切换"的结论来自每进程随机的 `hashValue` 比较，作废）；`AXRaise` 窗口无效；把应用元素的 `AXFrontmost` 设为 true 后菜单项变为 enabled，`AXPress` 才真的切换，之后用同一属性把焦点还给之前的前台应用。左侧导航栏按钮在树里是 2×4 px 的禁用切片，`AXPress` 无效——视图切换不在本批范围。

**As-built 变更**：`navigate` 增加 `AXFrontmost` 前置与焦点归还（`WeComActions.frontmostPid` / `restoreFrontmost` 可注入），结果多一个 `enabled` 键；`AXAttribute.frontmost` 新增。

- [ ] **Step 1: 失败测试**

`Tests/AXKitTests/FakeAXBackendTests.swift` 追加：

```swift
    @Test func applicationNodeDerivesItsWindowsFromChildren() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let app = fake.rootElement
        #expect(try app.element(AXAttribute.mainWindow)?.title() == "Main")
        #expect(try app.element(AXAttribute.focusedWindow)?.title() == "Main")
        #expect(try app.elements(AXAttribute.windows).count == 1)
        let window = try #require(fake.element(atPath: [0]))
        #expect(try window.attributeIfSupported(AXAttribute.mainWindow) == nil)
    }
```

`Tests/WeComAdapterTests/NavigateTests.swift`：

```swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Application root = the main-window fixture plus a 窗口 menu, as the live client exposes it.
enum NavigateFixture {
    static func app() throws -> FakeAXBackend {
        let window = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        func item(_ t: String) -> AXNode { AXNode(role: AXRole.menuItem, title: t, enabled: false, actions: [AXAction.press]) }
        let menu = AXNode(role: AXRole.menu, children: [item("最小化"), item("选择下一个会话"), item("选择上一个会话"), item("选择下一个未读会话")])
        let bar = AXNode(role: AXRole.menuBar, children: [
            AXNode(role: AXRole.menuBarItem, title: "文件", children: [AXNode(role: AXRole.menu, children: [item("关闭")])]),
            AXNode(role: AXRole.menuBarItem, title: "窗口", children: [menu]),
        ])
        return FakeAXBackend(root: AXNode(role: AXRole.application, title: "企业微信", children: [window, bar]))
    }
    /// Path of the active-title static text inside the app root (window is child 0).
    static let headerPath = [0, 0, 33, 5]
}

@Suite("client.navigate via the 窗口 menu")
struct NavigateTests {
    let policy = ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.navigate])

    @Test func menuBarListsWindowMenuItemsWithEnabledFlags() throws {
        let fake = try NavigateFixture.app()
        let items = try WeComMenuBar.items(in: fake.rootElement, menu: "窗口")
        #expect(items.map(\.title) == ["最小化", "选择下一个会话", "选择上一个会话", "选择下一个未读会话"])
        #expect(items.allSatisfy { $0.enabled == false })
        #expect(throws: WeComError.region("menuBar")) { try WeComMenuBar.items(in: try #require(fake.element(atPath: [0])), menu: "窗口") }
        #expect(throws: WeComError.region("menu 窗口 › 不存在")) { try WeComMenuBar.menuItem(in: fake.rootElement, menu: "窗口", item: "不存在") }
    }

    @Test func navigatePressesTheMenuItemAndReportsTheTitleChange() throws {
        let fake = try NavigateFixture.app()
        let header = try #require(fake.handle(atPath: NavigateFixture.headerPath))
        fake.reactions["action:AXPress"] = { fake.mutate(header, attribute: AXAttribute.value, to: .string("someone")) }
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        var actions = WeComActions(policy: policy)
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        let out = try actions.navigate(.nextConversation, app: fake.rootElement, reader: reader)
        #expect(out.kind == "navigate" && out.verified)
        #expect(out.details == ["action": "nextConversation", "before": "文件传输助手", "after": "someone", "changed": "true"])
        #expect(fake.recordedActions.count == 1 && fake.recordedActions[0].action == AXAction.press)
        #expect(try AXElement(handle: fake.recordedActions[0].handle, backend: fake).title() == "选择下一个会话")
        #expect(fake.recordedSets.isEmpty)   // never touches AXSelectedRows
    }

    @Test func navigateWithoutAChangeIsNotAnError() throws {
        let fake = try NavigateFixture.app()
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        var actions = WeComActions(policy: policy)
        actions.verifyTimeout = 0.05; actions.verifyInterval = 0.01
        let out = try actions.navigate(.nextUnreadConversation, app: fake.rootElement, reader: reader)
        #expect(out.details["changed"] == "false" && out.details["before"] == "文件传输助手" && out.details["after"] == "文件传输助手")
    }

    @Test func navigateIsRefusedByPolicyBeforeAnyAX() throws {
        let fake = try NavigateFixture.app()
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(throws: PolicyError.notEnabled(.navigate)) {
            try WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"])).navigate(.nextConversation, app: fake.rootElement, reader: reader)
        }
        #expect(fake.recordedActions.isEmpty)
    }

    @Test func missingMenuItemIsActionUnavailable() throws {
        let window = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [window, AXNode(role: AXRole.menuBar)]))
        let reader = try WeComReader(window: try WeComWindowLocator.mainWindow(from: fake.rootElement))
        #expect(throws: ActionError.actionUnavailable("menu 窗口 › 选择下一个会话")) {
            try WeComActions(policy: policy).navigate(.nextConversation, app: fake.rootElement, reader: reader)
        }
    }
}
```

`Tests/WeComAdapterTests/WeComCommandHandlerTests.swift` 追加（`handler(_:)` 的 `enabled` 集合加 `.navigate`）：

```swift
    @Test func clientNavigateGoesThroughTheHandlerAndMapsMissingMenusToUnsupported() throws {
        let fake = try NavigateFixture.app()
        let h = try handler(fake)
        h.configureActions = { a in a.verifyTimeout = 0.05; a.verifyInterval = 0.01 }
        let out = try h.clientNavigate(action: .previousConversation)
        #expect(out["action"] == "previousConversation" && out["changed"] == "false" && out["before"] == "文件传输助手")
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
        let bare = try Fixtures.mainWindow()   // window root: no menu bar reachable
        #expect(throws: ControlError.unsupported("action menu 窗口 › 选择下一个会话 unavailable")) {
            try handler(bare).clientNavigate(action: .nextConversation)
        }
    }
```

`Tests/imctlTests/ProbeCommandTests.swift`：`sub == [..., "menu", "scrollback", "menubar"]`，并追加

```swift
    @Test func menubarFromAppFixture() throws {
        let path = Fixtures.root.appendingPathComponent("wecom-5.0.11-app-menubar.json").path
        let out = try ProbeMenuBarCommand.parse(["--from-fixture", path]).collect()
        #expect(out.menu == "窗口" && out.items.map(\.title).contains("选择下一个会话"))
        #expect(try ProbeMenuBarCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]).collect().items.isEmpty)
    }
```

- [ ] **Step 2: 录制应用根夹具**

```bash
.build/arm64-apple-macosx/debug/imctl dump-tree --root app --depth 4 --max-children 40 \
  --keep 文件传输助手 --output Tests/Fixtures/ax-trees/wecom-5.0.11-app-menubar.json
```

（菜单角色属于 chrome，标题原样保留；窗口内容深度 ≤ 4 且已脱敏。）

- [ ] **Step 3: 运行，确认失败**

Run: `swift build --build-tests`
Expected: 编译错误（`WeComMenuBar`、`navigate`、`AXRole.menuBar` 未定义）

- [ ] **Step 4: 实现**

`AXConstants.swift`（`AXRole`）：

```swift
    public static let menuBar = "AXMenuBar"
    public static let menuBarItem = "AXMenuBarItem"
```

`FakeAXBackend.attribute` 的 `default:` 分支改为：

```swift
        default:
            if let v = node.attributes[name] { return v }
            // Like the real API: an application's windows are derived, not stored.
            if node.attributes[AXAttribute.role] == .string(AXRole.window) == false,
               node.attributes[AXAttribute.role] == .string(AXRole.application) {
                let windows = node.children.filter { nodes[$0]?.attributes[AXAttribute.role] == .string(AXRole.window) }.map { AXElementHandle(id: $0) }
                switch name {
                case AXAttribute.windows: return .elements(windows)
                case AXAttribute.mainWindow, AXAttribute.focusedWindow: if let first = windows.first { return .element(first) }
                default: break
                }
            }
            throw AXKitError.attributeUnsupported(name)
```

`Sources/WeComAdapter/WeComMenuBar.swift`：

```swift
import AXKit

public struct MenuItemInfo: Codable, Equatable {
    public var title: String
    public var enabled: Bool?
    public init(title: String, enabled: Bool?) { self.title = title; self.enabled = enabled }
}

/// The client's own menu bar, reached from the application element. Items are
/// driven with `AXPress` — the client's own command dispatch, no synthetic
/// input. 2026-09-15 on 5.0.11: the 窗口 items report `AXEnabled = false`
/// while the client is not the active app, yet `AXPress` succeeds and the
/// conversation switches, so `enabled` is reported but never consulted.
public enum WeComMenuBar {
    public static let windowMenuTitle = "窗口"

    public static func items(in app: AXElement, menu: String) throws -> [MenuItemInfo] {
        try menuElement(in: app, menu: menu).children()
            .filter { (try? $0.role()) == AXRole.menuItem }
            .map { MenuItemInfo(title: (try? $0.title()) ?? "", enabled: try? $0.isEnabled()) }
    }

    public static func menuItem(in app: AXElement, menu: String, item: String) throws -> AXElement {
        guard let found = try menuElement(in: app, menu: menu).children().first(where: { (try? $0.title()) == item }) else {
            throw WeComError.region("menu \(menu) › \(item)")
        }
        return found
    }

    /// The `AXMenu` under the bar item titled `menu`; there may be several
    /// `AXMenuBar` children (the live client exposes two).
    private static func menuElement(in app: AXElement, menu: String) throws -> AXElement {
        guard try app.role() == AXRole.application else { throw WeComError.region("menuBar") }
        for bar in try app.children() where (try? bar.role()) == AXRole.menuBar {
            for barItem in try bar.children() where (try? barItem.title()) == menu {
                if let submenu = try barItem.children().first(where: { (try? $0.role()) == AXRole.menu }) { return submenu }
            }
        }
        throw WeComError.region("menu \(menu)")
    }
}
```

`Sources/WeComAdapter/Actions/Navigate.swift`：

```swift
import AXKit
import ControlCore

public extension WeComActions {
    /// Menu titles as the client localises them (Chinese UI, 2026-09-15, 5.0.11).
    static let navigateMenuItems: [NavigateAction: String] = [
        .nextConversation: "选择下一个会话",
        .previousConversation: "选择上一个会话",
        .nextUnreadConversation: "选择下一个未读会话",
    ]

    /// `AXPress` the 窗口 menu item for `action`, then wait (verifyTimeout)
    /// for the active title to change. No change is a legitimate outcome
    /// (nothing unread), reported as `changed = false`.
    func navigate(_ action: NavigateAction, app: AXElement, reader: WeComReader) throws -> ActionOutcome {
        try policy.authorize(.navigate, target: nil)
        let title = Self.navigateMenuItems[action] ?? action.rawValue
        let item: AXElement
        do { item = try WeComMenuBar.menuItem(in: app, menu: WeComMenuBar.windowMenuTitle, item: title) }
        catch { throw ActionError.actionUnavailable("menu \(WeComMenuBar.windowMenuTitle) › \(title)") }
        let before = try reader.activeConversationTitle()
        try item.perform(AXAction.press)
        var after = before
        let changed = try waitUntil {
            after = try WeComReader(window: reader.layout.window).activeConversationTitle()
            return after != before
        }
        return ActionOutcome(kind: ActionKind.navigate.rawValue, target: nil, verified: true, details: [
            "action": action.rawValue, "before": before ?? "", "after": after ?? "", "changed": changed ? "true" : "false",
        ])
    }
}
```

`WeComCommandHandler.swift`（`confirmBroadcast` 之后）：

```swift
    public func clientNavigate(action: NavigateAction) throws -> [String: String] {
        try mapErrors {
            let app = try rootProvider()
            return try actions(for: nil).navigate(action, app: app, reader: try reader()).details
        }
    }
```

`Sources/imctld/main.swift`：`enabled: [.selectConversation, .composeText, .clearComposer, .scrollHistory, .submit, .confirmBroadcast, .navigate]`。

`Sources/imctl/Probe/ProbeSession.swift` 追加：

```swift
    /// The root element (application when live or app-rooted fixture; window for window-rooted fixtures).
    static func root(_ options: ProbeOptions) throws -> AXElement {
        if let path = options.fromFixture {
            return FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: path))).rootElement
        }
        let live = LiveAXBackend()
        guard live.isProcessTrusted(prompt: false) else { throw IMCTLError.notTrusted }
        return try AXApp.byBundleID(options.bundle, backend: live)
    }
```

`Sources/imctl/Commands/ProbeMenuBarCommand.swift`：

```swift
import ArgumentParser
import AXKit
import Foundation
import WeComAdapter

struct MenuBarOutput: Codable {
    var menu: String
    var reachable: Bool
    var items: [MenuItemInfo]
}

struct ProbeMenuBarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menubar",
        abstract: "List the items of one of the client's menu-bar menus (default 窗口) with their enabled flags. Read-only; presses nothing."
    )

    @OptionGroup var options: ProbeOptions
    @Option(help: "Menu-bar item title.") var menu: String = WeComMenuBar.windowMenuTitle

    func collect() throws -> MenuBarOutput {
        let root = try ProbeSession.root(options)
        do {
            return MenuBarOutput(menu: menu, reachable: true, items: try WeComMenuBar.items(in: root, menu: menu))
        } catch let e as WeComError {
            // Window-rooted fixtures and clients without a menu bar: report, do not fail.
            FileHandle.standardError.write(Data("menu bar unavailable: \(e.description)\n".utf8))
            return MenuBarOutput(menu: menu, reachable: false, items: [])
        }
    }

    func run() throws {
        let out = try collect()
        if options.json { print(try ProbeSession.encode(out)); return }
        print("menu: \(out.menu) reachable: \(out.reachable)")
        for item in out.items { print("  - \(item.title)\(item.enabled == false ? " [disabled]" : "")") }
    }
}
```

`ProbeCommand.swift` 子命令数组末尾加 `ProbeMenuBarCommand.self`。

- [ ] **Step 5: 编译检查**

Run: `swift build --build-tests`
Expected: 成功

---

### Task 4: `UnixSocketClient` 与 `imctl call`

**Files:**
- Create: `Sources/MCPTransport/UnixSocketClient.swift`
- Create: `Sources/imctl/Commands/CallCommand.swift`；Modify: `Sources/imctl/IMCTL.swift`（`call` 在 `status` 之后）
- Test: Create `Tests/MCPTransportTests/UnixSocketClientTests.swift`；Modify `Tests/imctlTests/CommandParsingTests.swift`

**Interfaces:**
- `public final class UnixSocketClient { init(path: String, timeout: TimeInterval = 30); func call(_ method: String, params: [String: JSONValue] = [:]) throws -> JSONValue }`
- `UnixSocketClient.RPCError(code: Int, message: String, data: JSONValue?)`（服务器 `error` 对象）；`UnixSocketClient.TransportError { connect(String), timeout, closed, malformed(String) }`
- CLI：`imctl call <method> [--params '{}'] [--socket <path>] [--timeout 30]`，成功打印 `result` JSON，JSON-RPC 错误打印 `error` 并退出码 1

- [ ] **Step 1: 失败测试**

`Tests/MCPTransportTests/UnixSocketClientTests.swift`：

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("UnixSocketClient", .serialized)
struct UnixSocketClientTests {
    func server() throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-c-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let s = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler())), path: path)
        s.log = { _ in }
        try s.start()
        return (s, path)
    }

    @Test func roundTripsResultsAndErrors() throws {
        let (server, path) = try server()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let client = UnixSocketClient(path: path, timeout: 5)
        let describe = try client.call("controller.describe")
        #expect(describe.objectValue?["result"]?.objectValue?["platform"] == .string("fake"))
        let send = try client.call("message.send", params: ["target": .string("文件传输助手"), "text": .string("hi"), "idempotencyKey": .string("k1")])
        #expect(send.objectValue?["state"] == .string("succeeded"))
        let replay = try client.call("event.replay", params: ["afterEventId": .number(0)])
        #expect((replay.objectValue?["count"]?.numberValue ?? 0) >= 3)
        #expect(throws: UnixSocketClient.RPCError(code: -32601, message: "method not found", data: nil)) { try client.call("nope") }
        do { _ = try client.call("message.send", params: ["target": .string("x")]); Issue.record("expected an error") }
        catch let e as UnixSocketClient.RPCError { #expect(e.code == -32000 && e.data?.objectValue?["code"] == .string("INVALID_PARAMS")) }
    }

    @Test func missingSocketIsAConnectError() {
        do { _ = try UnixSocketClient(path: "/tmp/imctl-none-\(UUID().uuidString.prefix(6)).sock", timeout: 1).call("ping"); Issue.record("expected an error") }
        catch let e as UnixSocketClient.TransportError { if case .connect = e {} else { Issue.record("wrong error \(e)") } }
        catch { Issue.record("wrong error \(error)") }
    }
}
```

`CommandParsingTests.rootListsFourSubcommands`：`["version", "permission", "env", "dump-tree", "probe", "status", "call", "enroll", "mqtt", "agent", "policy", "identity", "wecom"]`。

- [ ] **Step 2: 运行，确认失败**

Run: `swift build --build-tests`
Expected: 编译错误（`UnixSocketClient` 未定义）

- [ ] **Step 3: 实现**

`Sources/MCPTransport/UnixSocketClient.swift`：

```swift
import Darwin
import Foundation

/// Blocking newline-delimited JSON-RPC client for `UnixSocketServer` (the
/// console, `imctl call`, tests). One connection per call: the daemon's
/// socket is local and cheap, and a fresh connection cannot mix up replies.
public final class UnixSocketClient {
    public let path: String
    public var timeout: TimeInterval

    /// The server's JSON-RPC `error` object (`data.code` carries the wire error code for -32000).
    public struct RPCError: Error, Equatable, CustomStringConvertible {
        public var code: Int
        public var message: String
        public var data: JSONValue?
        public init(code: Int, message: String, data: JSONValue?) { self.code = code; self.message = message; self.data = data }
        public var description: String {
            let extra = data.flatMap { try? $0.serialized() }.map { " \($0)" } ?? ""
            return "JSON-RPC error \(code): \(message)\(extra)"
        }
    }

    public enum TransportError: Error, Equatable, CustomStringConvertible {
        case connect(String)
        case timeout
        case closed
        case malformed(String)
        public var description: String {
            switch self {
            case .connect(let why): return "cannot connect: \(why)"
            case .timeout: return "no response before the timeout"
            case .closed: return "server closed the connection without answering"
            case .malformed(let line): return "malformed response: \(line.prefix(200))"
            }
        }
    }

    public init(path: String, timeout: TimeInterval = 30) {
        self.path = path
        self.timeout = timeout
    }

    public func call(_ method: String, params: [String: JSONValue] = [:]) throws -> JSONValue {
        let id = UUID().uuidString
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
        let line = try request.serialized() + "\n"
        let fd = try connect()
        defer { close(fd) }
        try writeAll(fd, Array(line.utf8))
        let response = try readLine(fd)
        guard let object = (try? JSONValue.parse(response))?.objectValue else { throw TransportError.malformed(response) }
        if let error = object["error"]?.objectValue {
            throw RPCError(code: Int(error["code"]?.numberValue ?? -1), message: error["message"]?.stringValue ?? "", data: error["data"])
        }
        guard let result = object["result"] else { throw TransportError.malformed(response) }
        return result
    }

    // MARK: Socket plumbing

    private func connect() throws -> Int32 {
        guard path.utf8.count <= UnixSocketServer.maxPathLength else { throw TransportError.connect("path longer than \(UnixSocketServer.maxPathLength) bytes") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.connect(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { src in raw.copyMemory(from: src) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw TransportError.connect("\(path): \(why)")
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { throw TransportError.timeout }
            guard written > 0 else { throw TransportError.closed }
            offset += written
        }
    }

    private func readLine(_ fd: Int32) throws -> String {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw (errno == EAGAIN || errno == EWOULDBLOCK) ? TransportError.timeout : TransportError.closed }
            if n == 0 { throw TransportError.closed }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[..<newline], as: UTF8.self)
            }
        }
    }
}
```

`Sources/imctl/Commands/CallCommand.swift`：

```swift
import ArgumentParser
import ControlCore
import Foundation
import MCPTransport

struct CallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Send one JSON-RPC request to the local imctld socket (the same path the console uses) and print the result."
    )

    @Argument(help: "Protocol method, e.g. conversation.list, client.navigate, event.replay") var method: String
    @Option(help: "JSON object with params.") var params: String = "{}"
    @Option(help: "Unix socket served by `imctld run --socket`.") var socket: String = IMCTLPaths.socket.path
    @Option(help: "Seconds to wait for the response.") var timeout: Double = 30

    func run() throws {
        guard let object = try JSONValue.parse(params).objectValue else { throw ValidationError("--params must be a JSON object") }
        do {
            let result = try UnixSocketClient(path: socket, timeout: timeout).call(method, params: object)
            let data = try JSONSerialization.data(withJSONObject: result.any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        } catch let e as UnixSocketClient.RPCError {
            FileHandle.standardError.write(Data("\(e)\n".utf8))
            throw ExitCode(1)
        } catch let e as UnixSocketClient.TransportError {
            throw ValidationError("\(e) (is imctld running with --socket \(socket)?)")
        }
    }
}
```

`IMCTL.swift`：子命令列表在 `StatusCommand.self` 后插入 `CallCommand.self`。

- [ ] **Step 4: 编译检查**

Run: `swift build --build-tests`
Expected: 成功

---

### Task 5: 路径常量、守护进程状态字段、`agent install` 默认套接字

**Files:**
- Modify: `Sources/ControlCore/IMCTLPaths.swift`
- Modify: `Sources/imctld/DaemonPaths.swift`、`Sources/imctld/DaemonWatcher.swift`、`Sources/imctld/main.swift`
- Modify: `Sources/imctl/Commands/AgentCommand.swift`、`Sources/imctl/Commands/StatusCommand.swift`
- Test: `Tests/ControlCoreTests/IMCTLVersionTests.swift`、`Tests/imctlTests/AgentCommandTests.swift`

**Interfaces:**
- `IMCTLPaths.database` (`imctl.sqlite`)、`.stateFile` (`state.json`)、`.runDirectory` (`run/`)、`.socket` (`run/imctl.sock`)、`.logDirectory` (`~/Library/Logs/imctl`)
- `state.json` 新键：`trusted: Bool`（守护进程自己的辅助功能授权）、`socket: String`（空串 = 未开）
- `imctl agent install`：`--socket <path>` 默认 `IMCTLPaths.socket.path`；`--no-socket` 关闭

- [ ] **Step 1: 失败测试**

`IMCTLVersionTests.swift` 追加：

```swift
    @Test func runtimePathsLiveUnderTheDataDirectory() {
        let root = IMCTLPaths.dataDirectory.path
        #expect(IMCTLPaths.database.path == root + "/imctl.sqlite" && IMCTLPaths.stateFile.path == root + "/state.json")
        #expect(IMCTLPaths.socket.path == root + "/run/imctl.sock" && IMCTLPaths.runDirectory.path == root + "/run")
        #expect(IMCTLPaths.socket.path.utf8.count <= 103)
        #expect(IMCTLPaths.logDirectory.path.hasSuffix("/Library/Logs/imctl"))
    }
```

`AgentCommandTests.installDryRunWritesNothingAndRunsNoLaunchctl` 末尾改为：

```swift
        let withMQTT = try AgentInstallCommand.parse(["--dry-run", "--mqtt", "--no-observe", "--daemon", "/usr/bin/true"])
        #expect(withMQTT.spec().arguments == ["run", "--watch-interval", "1.0", "--mqtt", "--socket", IMCTLPaths.socket.path, "--no-observe"])
        let noSocket = try AgentInstallCommand.parse(["--dry-run", "--no-socket", "--daemon", "/usr/bin/true"])
        #expect(noSocket.spec().arguments == ["run", "--watch-interval", "1.0"])
```

（文件顶部加 `import ControlCore`。）

- [ ] **Step 2: 运行，确认失败**

Run: `swift build --build-tests`
Expected: 编译错误（`IMCTLPaths.socket` 未定义）

- [ ] **Step 3: 实现**

`IMCTLPaths.swift`：

```swift
    /// `imctl.sqlite`: commands, events, pause reasons, identities.
    public static var database: URL { dataDirectory.appendingPathComponent("imctl.sqlite") }
    /// `state.json`, rewritten by imctld every few seconds.
    public static var stateFile: URL { dataDirectory.appendingPathComponent("state.json") }
    /// Owner-only directory for the daemon's socket (`UnixSocketServer` verifies 0700).
    public static var runDirectory: URL { dataDirectory.appendingPathComponent("run", isDirectory: true) }
    /// Newline-delimited JSON-RPC served by `imctld run --socket` (console, `imctl call`, local Java).
    public static var socket: URL { runDirectory.appendingPathComponent("imctl.sock") }
    /// `~/Library/Logs/imctl` (launchd stdout / stderr of the daemon).
    public static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/imctl", isDirectory: true)
    }
```

`DaemonPaths.swift`：`db` → `IMCTLPaths.database`，`state` → `IMCTLPaths.stateFile`，`root` → `IMCTLPaths.dataDirectory`（保留 `checkpoints`）。`StatusCommand`：`defaultRoot` 改为 `IMCTLPaths.dataDirectory`，默认值用 `IMCTLPaths.stateFile.path` / `IMCTLPaths.database.path`。

`DaemonWatcher.swift`：属性 `private let backend: AXBackend`、`var socketPath: String?`；`init` 存 `backend`；`writeState` 的字典追加

```swift
            "trusted": backend.isProcessTrusted(prompt: false),
            "socket": socketPath ?? "",
```

`main.swift`：`watcher.socketPath = socket`（在 `watcher.start()` 之前）。

`AgentCommand.swift`：

```swift
    @Option(help: "Serve newline-delimited JSON-RPC on this Unix socket path (the console and `imctl call` use it).")
    var socket: String = IMCTLPaths.socket.path
    @Flag(name: .customLong("no-socket"), help: "Do not pass --socket to imctld.") var noSocket = false
    …
        if mqtt { arguments.append("--mqtt") }
        if !noSocket { arguments += ["--socket", socket] }
```

（文件加 `import ControlCore`。）

- [ ] **Step 4: 编译检查**

Run: `swift build --build-tests`
Expected: 成功

---

### Task 6: 控制台 `imctl-console`

**Files:**
- Modify: `Package.swift`（产品 + 可执行 target `imctl-console` + 测试 target `imctl-consoleTests`）
- Create: `Sources/imctl-console/ConsoleApp.swift`
- Create: `Sources/imctl-console/Model/ConsolePaths.swift`、`Model/DaemonState.swift`、`Model/CLIRunner.swift`、`Model/DaemonControl.swift`、`Model/RPCService.swift`、`Model/Diagnostics.swift`、`Model/ConsoleModel.swift`
- Create: `Sources/imctl-console/Views/ConsoleWindow.swift`、`Views/StatusView.swift`、`Views/ConversationsView.swift`、`Views/SendView.swift`、`Views/EventsView.swift`、`Views/PolicyView.swift`、`Views/SettingsView.swift`、`Views/DiagnosticsView.swift`、`Views/LogView.swift`、`Views/MenuBarMenu.swift`
- Test: Create `Tests/imctl-consoleTests/DaemonStateTests.swift`、`CLIRunnerTests.swift`、`DaemonControlTests.swift`、`RPCServiceTests.swift`、`DiagnosticsTests.swift`

**Interfaces:**
- `ConsolePaths.socket` / `.stateFile` / `.cli`（环境变量 `IMCTL_SOCKET` / `IMCTL_STATE` / `IMCTL_CLI` 覆盖，开发期指向临时守护进程）
- `struct DaemonState: Codable`（`state.json` 全部键可选，除 `pid`）；`DaemonState.load(from:)`、`isAlive`
- `struct CLIRunner { var executable: URL; static func sibling() -> CLIRunner; func run(_ args: [String], stdin: String? = nil) throws -> Result }`
- `struct DaemonControl { static func installArguments(mqttEnrolled: Bool, socket: String) -> [String]; func status() throws -> AgentStatus; install / uninstall / restart }`
- `struct RPCService { var socketPath: String; func call(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue; static func idempotencyKey() -> String; static func sendParams(target:text:) / navigateParams(_:) }`
- `enum Diagnostics { static func run() -> DiagnosticsReport; static func fill(_ base: DiagnosticsReport, app: AXElement) throws -> DiagnosticsReport }`
- `@MainActor @Observable final class ConsoleModel`

- [ ] **Step 1: 失败测试**

`Tests/imctl-consoleTests/DaemonStateTests.swift`：

```swift
import Foundation
import Testing
@testable import imctl_console

@Suite("DaemonState")
struct DaemonStateTests {
    @Test func decodesOldAndNewStateFiles() throws {
        let old = #"{"active":"","conversations":0,"errors":3,"lastEventId":52,"paused":["system"],"pid":1,"polls":0,"version":"0.1.0-dev"}"#
        let s = try JSONDecoder().decode(DaemonState.self, from: Data(old.utf8))
        #expect(s.pid == 1 && s.pausedReasons == ["system"] && s.trusted == nil && s.socket == nil && s.lastEventId == 52)
        let new = #"{"pid":2,"trusted":true,"socket":"/x/run/imctl.sock","paused":[],"startedMs":1,"policy":"titles=0"}"#
        let n = try JSONDecoder().decode(DaemonState.self, from: Data(new.utf8))
        #expect(n.trusted == true && n.socket == "/x/run/imctl.sock" && n.pausedReasons.isEmpty && n.policy == "titles=0")
        #expect(DaemonState(pid: Int(ProcessInfo.processInfo.processIdentifier)).isAlive)
    }
}
```

`Tests/imctl-consoleTests/CLIRunnerTests.swift`：

```swift
import Foundation
import Testing
@testable import imctl_console

@Suite("CLIRunner")
struct CLIRunnerTests {
    @Test func capturesOutputAndStatus() throws {
        let echo = CLIRunner(executable: URL(fileURLWithPath: "/bin/echo"))
        #expect(try echo.run(["hi", "there"]) == CLIRunner.Result(status: 0, output: "hi there\n"))
        let cat = CLIRunner(executable: URL(fileURLWithPath: "/bin/cat"))
        #expect(try cat.run([], stdin: "secret\n").output == "secret\n")
        #expect(try CLIRunner(executable: URL(fileURLWithPath: "/usr/bin/false")).run([]).status == 1)
    }

    @Test func siblingHonoursTheEnvironmentOverride() {
        setenv("IMCTL_CLI", "/tmp/fake-imctl", 1)
        defer { unsetenv("IMCTL_CLI") }
        #expect(CLIRunner.sibling().executable.path == "/tmp/fake-imctl")
    }
}
```

`Tests/imctl-consoleTests/DaemonControlTests.swift`：

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import imctl_console

@Suite("DaemonControl")
struct DaemonControlTests {
    @Test func installArgumentsFollowTheCLI() {
        #expect(DaemonControl.installArguments(mqttEnrolled: false, socket: "/s") == ["agent", "install", "--socket", "/s"])
        #expect(DaemonControl.installArguments(mqttEnrolled: true, socket: "/s") == ["agent", "install", "--socket", "/s", "--mqtt"])
        #expect(DaemonControl.installArguments(mqttEnrolled: false).contains(IMCTLPaths.socket.path))
    }

    @Test func statusDecodesAgentStatusJSON() throws {
        let json = #"{"label":"com.sunkailun.imctl","lastExitCode":"0","loaded":true,"logDirectory":"/l","pid":4242,"plist":"/p","plistPresent":true,"state":"running"}"#
        let s = try JSONDecoder().decode(DaemonControl.AgentStatus.self, from: Data(json.utf8))
        #expect(s.loaded && s.state == "running" && s.pid == 4242 && s.plistPresent == true)
        #expect(DaemonControl.kickstartArguments(label: "com.sunkailun.imctl").prefix(2) == ["kickstart", "-k"])
    }
}
```

`Tests/imctl-consoleTests/RPCServiceTests.swift`：

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

final class ConsoleFakeHandler: CommandHandler {
    func describe() throws -> [String: String] { ["platform": "fake", "allowlist": "文件传输助手"] }
    func accountStatus() throws -> [String: String] { ["windowReachable": "true"] }
    func conversationList() throws -> [[String: String]] { [["title": "文件传输助手", "selected": "true", "conversationType": "unknown"]] }
    func conversationRead(target: String) throws -> [String: String] { ["active": target, "messageCount": "1"] }
    func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] { [["index": "0", "direction": "outbound", "text": "hi"]] }
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        try checkpoint(); try afterSubmit(); return SendResult(state: .succeeded, evidence: "row #1", latencyMs: 9)
    }
    func clientNavigate(action: NavigateAction) throws -> [String: String] { ["action": action.rawValue, "before": "a", "after": "b", "changed": "true"] }
}

@Suite("RPCService against a real socket", .serialized)
struct RPCServiceTests {
    @Test func sendsNavigatesAndReplaysThroughTheDaemonPath() throws {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let server = UnixSocketServer(dispatcher: RPCDispatcher(executor: CommandExecutor(store: store, handler: ConsoleFakeHandler())), path: path)
        server.log = { _ in }
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let service = RPCService(socketPath: path, timeout: 5)
        #expect(try service.call("controller.describe").objectValue?["result"]?.objectValue?["platform"] == .string("fake"))
        let sent = try service.call("message.send", RPCService.sendParams(target: "文件传输助手", text: "hi"))
        #expect(sent.objectValue?["state"] == .string("succeeded"))
        let nav = try service.call("client.navigate", RPCService.navigateParams(.nextConversation))
        #expect(nav.objectValue?["result"]?.objectValue?["changed"] == .string("true"))
        let replay = try service.call("event.replay", RPCService.replayParams(after: 0, limit: 50))
        #expect((replay.objectValue?["count"]?.numberValue ?? 0) >= 6)
        #expect(RPCService.idempotencyKey().hasPrefix("console-") && RPCService.idempotencyKey() != RPCService.idempotencyKey())
        #expect(try store.recentCommands(limit: 10).count == 3)   // describe, send, navigate — replay is a query
    }
}
```

`Tests/imctl-consoleTests/DiagnosticsTests.swift`：

```swift
import Foundation
import Testing
@testable import AXKit
@testable import imctl_console

@Suite("Diagnostics on fixture")
struct DiagnosticsTests {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ax-trees")
    }

    @Test func fillsLayoutAndMenuFactsFromAnApplicationRoot() throws {
        let window = try AXNode.load(from: Self.fixtures.appendingPathComponent("wecom-5.0.10-main-window.json"))
        let menu = AXNode(role: AXRole.menu, children: [AXNode(role: AXRole.menuItem, title: "选择下一个会话", enabled: false, actions: [AXAction.press])])
        let bar = AXNode(role: AXRole.menuBar, children: [AXNode(role: AXRole.menuBarItem, title: "窗口", children: [menu])])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [window, bar]))
        let report = try Diagnostics.fill(DiagnosticsReport(consoleTrusted: true, clientRunning: true), app: fake.rootElement)
        #expect(report.activeTitle == "文件传输助手" && report.conversationCount == 6 && report.composerPresent == true)
        #expect(report.rowHeights == [64] && report.windowMenuItems == ["选择下一个会话 [disabled]"])
        #expect(report.conversationTable?.hasPrefix("(59") == true && report.error == nil)
    }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift build --build-tests`
Expected: 编译错误（target / 类型不存在）

- [ ] **Step 3: 实现 `Package.swift`**

```swift
        .executable(name: "imctl-console", targets: ["imctl-console"]),
        …
        .executableTarget(
            name: "imctl-console",
            dependencies: ["ControlCore", "AXKit", "WeComAdapter", "MCPTransport", "MQTTTransport", "WeComAPI"],
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit")]
        ),
        …
        .testTarget(name: "imctl-consoleTests", dependencies: ["imctl-console", "MCPTransport"]),
```

- [ ] **Step 4: 实现模型层**

`Model/ConsolePaths.swift`：

```swift
import ControlCore
import Foundation

/// Where the console finds the daemon. Environment overrides exist so a
/// development build can talk to a temporary daemon instead of the LaunchAgent.
enum ConsolePaths {
    static var socket: String { ProcessInfo.processInfo.environment["IMCTL_SOCKET"] ?? IMCTLPaths.socket.path }
    static var stateFile: URL { ProcessInfo.processInfo.environment["IMCTL_STATE"].map { URL(fileURLWithPath: $0) } ?? IMCTLPaths.stateFile }
    static var logDirectory: URL { IMCTLPaths.logDirectory }
}
```

`Model/DaemonState.swift`：

```swift
import Foundation

/// `state.json` as imctld writes it every 5 s. Everything but `pid` is
/// optional so a state file from an older daemon still decodes.
struct DaemonState: Codable, Equatable {
    var pid: Int
    var version: String?
    var startedMs: Int64?
    var lastPollMs: Int64?
    var polls: Int?
    var errors: Int?
    var relocations: Int?
    var active: String?
    var conversations: Int?
    var observer: Bool?
    var notifications: Int?
    var observedViaNotification: Int?
    var lastEventId: Int64?
    var paused: [String]?
    var policy: String?
    var trusted: Bool?
    var socket: String?

    init(pid: Int) { self.pid = pid }

    static func load(from url: URL) throws -> DaemonState {
        try JSONDecoder().decode(DaemonState.self, from: Data(contentsOf: url))
    }

    var isAlive: Bool { kill(pid_t(pid), 0) == 0 }
    var pausedReasons: [String] { paused ?? [] }
    var uptimeSeconds: Int? { startedMs.map { Int(Date().timeIntervalSince1970) - Int($0 / 1000) } }
}
```

`Model/CLIRunner.swift`：

```swift
import Foundation

/// Runs the sibling `imctl` CLI (same bundle, same signing identity). Every
/// change the console makes to launchd or policy.json goes through the CLI,
/// so the console can never diverge from what the terminal would do.
struct CLIRunner {
    var executable: URL

    struct Result: Equatable {
        var status: Int32
        var output: String
    }

    /// `imctl` next to this executable (imctl.app/Contents/MacOS); `IMCTL_CLI` overrides in development.
    static func sibling() -> CLIRunner {
        if let override = ProcessInfo.processInfo.environment["IMCTL_CLI"] { return CLIRunner(executable: URL(fileURLWithPath: override)) }
        let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        return CLIRunner(executable: me.deletingLastPathComponent().appendingPathComponent("imctl"))
    }

    func run(_ arguments: [String], stdin: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
```

`Model/DaemonControl.swift`：

```swift
import ControlCore
import Foundation

/// launchd-side operations, delegated to `imctl agent …` and `launchctl`.
/// Nothing here touches TCC: the Accessibility grant stays a human click.
struct DaemonControl {
    var cli: CLIRunner
    var label = "com.sunkailun.imctl"

    struct AgentStatus: Codable, Equatable {
        var loaded: Bool
        var state: String?
        var pid: Int?
        var plistPresent: Bool?
        var lastExitCode: String?
        var logDirectory: String?
    }

    static func installArguments(mqttEnrolled: Bool, socket: String = IMCTLPaths.socket.path) -> [String] {
        var arguments = ["agent", "install", "--socket", socket]
        if mqttEnrolled { arguments.append("--mqtt") }
        return arguments
    }

    static func kickstartArguments(label: String) -> [String] { ["kickstart", "-k", "gui/\(getuid())/\(label)"] }

    func status() throws -> AgentStatus {
        let result = try cli.run(["agent", "status", "--json"])
        return try JSONDecoder().decode(AgentStatus.self, from: Data(result.output.utf8))
    }

    func install(mqttEnrolled: Bool) throws -> CLIRunner.Result { try cli.run(Self.installArguments(mqttEnrolled: mqttEnrolled)) }
    func uninstall() throws -> CLIRunner.Result { try cli.run(["agent", "uninstall"]) }
    func restart() throws -> CLIRunner.Result {
        try CLIRunner(executable: URL(fileURLWithPath: "/bin/launchctl")).run(Self.kickstartArguments(label: label))
    }
}
```

`Model/RPCService.swift`：

```swift
import ControlCore
import Foundation
import MCPTransport

/// Every command the console issues goes through the daemon's socket, so
/// policy, idempotency, the rate cap and the event log apply exactly as they
/// do for Java. Parameter builders are static so tests can check them.
struct RPCService {
    var socketPath: String
    var timeout: TimeInterval = 30

    func call(_ method: String, _ params: [String: JSONValue] = [:]) throws -> JSONValue {
        try UnixSocketClient(path: socketPath, timeout: timeout).call(method, params: params)
    }

    static func idempotencyKey() -> String { "console-\(UUID().uuidString.lowercased())" }

    static func sendParams(target: String, text: String) -> [String: JSONValue] {
        ["target": .string(target), "text": .string(text), "idempotencyKey": .string(idempotencyKey())]
    }

    static func navigateParams(_ action: NavigateAction) -> [String: JSONValue] {
        ["action": .string(action.rawValue), "idempotencyKey": .string(idempotencyKey())]
    }

    static func replayParams(after: Int64, limit: Int) -> [String: JSONValue] {
        ["afterEventId": .number(Double(after)), "limit": .number(Double(limit))]
    }

    static func pretty(_ value: JSONValue) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value.any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }
}
```

`Model/Diagnostics.swift`：

```swift
import AppKit
import AXKit
import WeComAdapter

/// Read-only, in-process look at the client: what the daemon would see if it
/// were trusted. Needs the console's own Accessibility grant; presses nothing.
struct DiagnosticsReport: Codable, Equatable {
    var consoleTrusted: Bool
    var clientRunning: Bool
    var windowFrame: String?
    var conversationTable: String?
    var messageTable: String?
    var composerPresent: Bool?
    var activeTitle: String?
    var activeType: String?
    var conversationCount: Int?
    var rowHeights: [Int]?
    var windowMenuItems: [String]?
    var error: String?
}

enum Diagnostics {
    static func run(bundleID: String = WeComClient.bundleID) -> DiagnosticsReport {
        let backend = LiveAXBackend()
        var report = DiagnosticsReport(consoleTrusted: backend.isProcessTrusted(prompt: false),
                                       clientRunning: AXApp.runningApplication(bundleID: bundleID) != nil)
        guard report.consoleTrusted, report.clientRunning else { return report }
        do { report = try fill(report, app: try AXApp.byBundleID(bundleID, backend: backend)) }
        catch { report.error = String(describing: error) }
        return report
    }

    static func fill(_ base: DiagnosticsReport, app: AXElement) throws -> DiagnosticsReport {
        var report = base
        report.windowMenuItems = (try? WeComMenuBar.items(in: app, menu: WeComMenuBar.windowMenuTitle))?
            .map { $0.title + ($0.enabled == false ? " [disabled]" : "") }
        do {
            let window = try WeComWindowLocator.mainWindow(from: app)
            let reader = try WeComReader(window: window)
            let layout = reader.layout
            report.windowFrame = describe(layout.windowFrame)
            report.conversationTable = describe(layout.conversationTableFrame)
            report.messageTable = layout.messageTableFrame.map(describe)
            report.composerPresent = layout.composer != nil
            report.activeTitle = try reader.activeConversationTitle()
            report.activeType = try reader.activeConversationType().rawValue
            let rows = try reader.conversations()
            report.conversationCount = rows.count
            report.rowHeights = Array(Set(rows.map { Int($0.frame.height) })).sorted()
        } catch {
            report.error = String(describing: error)
        }
        return report
    }

    private static func describe(_ r: CGRect) -> String { "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))" }
}
```

`Model/ConsoleModel.swift`：

```swift
import AppKit
import AXKit
import ControlCore
import Foundation
import MCPTransport
import MQTTTransport
import Observation
import WeComAPI

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    var time = Date()
    var title: String
    var body: String
    var isError = false
}

struct EventRow: Identifiable, Equatable {
    var id: Int64
    var tsMs: Int64
    var kind: String
    var payload: String
}

/// All console state. Commands run off the main actor; results land back here.
@MainActor @Observable final class ConsoleModel {
    // status
    var state: DaemonState?
    var stateError: String?
    var agent: DaemonControl.AgentStatus?
    var agentError: String?
    var socketReachable = false
    var describe: [String: String] = [:]
    var consoleTrusted = false
    var clientRunning = false
    var mqttEnrolled = false
    var proxyEnrolled = false
    // conversations
    var conversations: [[String: String]] = []
    var activeTitle = ""
    var messages: [[String: String]] = []
    // events
    var events: [EventRow] = []
    var lastEventId: Int64 = 0
    var tailing = false
    // policy / diagnostics / log
    var policyText = ""
    var diagnostics: DiagnosticsReport?
    var log: [LogEntry] = []
    var busy = false

    let cli = CLIRunner.sibling()
    var service: RPCService { RPCService(socketPath: state?.socket.flatMap { $0.isEmpty ? nil : $0 } ?? ConsolePaths.socket) }
    var control: DaemonControl { DaemonControl(cli: cli) }

    var menuBarSymbol: String {
        guard let state, state.isAlive else { return "exclamationmark.triangle" }
        return state.pausedReasons.isEmpty ? "message.badge.waveform" : "pause.circle"
    }

    var statusLine: String {
        guard let state, state.isAlive else { return "守护进程未运行" }
        let paused = state.pausedReasons.isEmpty ? "运行中" : "暂停 [\(state.pausedReasons.joined(separator: ","))]"
        return "\(paused) · pid \(state.pid) · 事件 \(state.lastEventId ?? 0)" + (state.trusted == false ? " · 未授权辅助功能" : "")
    }

    // MARK: Refresh

    func refresh() async {
        do { state = try DaemonState.load(from: ConsolePaths.stateFile); stateError = nil }
        catch { state = nil; stateError = String(describing: error) }
        consoleTrusted = LiveAXBackend().isProcessTrusted(prompt: false)
        clientRunning = AXApp.runningApplication(bundleID: WeComClient.bundleID) != nil
        mqttEnrolled = FileManager.default.fileExists(atPath: MQTTSettings.defaultURL.path)
        proxyEnrolled = FileManager.default.fileExists(atPath: WeComProxySettings.defaultURL.path)
        let control = self.control
        do { agent = try await Task.detached { try control.status() }.value; agentError = nil }
        catch { agent = nil; agentError = String(describing: error) }
        if let result = await rpc("controller.describe", log: false) {
            socketReachable = true
            describe = result.objectValue?["result"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        } else {
            socketReachable = false
        }
    }

    /// One JSON-RPC call through the daemon socket, logged; nil on error (also logged).
    @discardableResult
    func rpc(_ method: String, _ params: [String: JSONValue] = [:], log shouldLog: Bool = true) async -> JSONValue? {
        let service = self.service
        busy = true
        defer { busy = false }
        do {
            let result = try await Task.detached { try service.call(method, params) }.value
            if shouldLog { append(method, RPCService.pretty(result)) }
            return result
        } catch {
            if shouldLog || !(error is UnixSocketClient.TransportError) { append(method, String(describing: error), error: true) }
            return nil
        }
    }

    func append(_ title: String, _ body: String, error: Bool = false) {
        log.append(LogEntry(title: title, body: body, isError: error))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Conversations

    func loadConversations() async {
        guard let r = await rpc("conversation.list") else { return }
        conversations = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
        activeTitle = conversations.first { $0["selected"] == "true" }?["title"] ?? activeTitle
    }

    func open(_ target: String) async {
        guard let r = await rpc("conversation.read", ["target": .string(target)]) else { return }
        activeTitle = r.objectValue?["result"]?.objectValue?["active"]?.stringValue ?? target
        await loadHistory()
    }

    func loadHistory(limit: Int = 30, scrollback: Bool = false) async {
        guard let r = await rpc("message.history", ["limit": .number(Double(limit)), "scrollback": .bool(scrollback)]) else { return }
        messages = (r.objectValue?["result"]?.arrayValue ?? []).map { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
    }

    func navigate(_ action: NavigateAction) async {
        guard let r = await rpc("client.navigate", RPCService.navigateParams(action)) else { return }
        if let after = r.objectValue?["result"]?.objectValue?["after"]?.stringValue { activeTitle = after }
        await loadConversations()
    }

    func send(target: String, text: String) async -> String {
        guard let r = await rpc("message.send", RPCService.sendParams(target: target, text: text)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    func pause() async { await rpc("controller.pause"); await refresh() }
    func resume() async { await rpc("controller.resume"); await refresh() }

    // MARK: Events

    func tailOnce() async {
        guard let r = await rpc("event.replay", RPCService.replayParams(after: lastEventId, limit: 200), log: false) else { return }
        let rows = (r.objectValue?["events"]?.arrayValue ?? []).compactMap { e -> EventRow? in
            guard let o = e.objectValue, let id = o["eventId"]?.numberValue else { return nil }
            return EventRow(id: Int64(id), tsMs: Int64(o["tsMs"]?.numberValue ?? 0), kind: o["kind"]?.stringValue ?? "",
                            payload: o["payload"].map { (try? $0.serialized()) ?? "" } ?? "")
        }
        if let last = rows.last { lastEventId = last.id }
        events.append(contentsOf: rows)
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
    }

    func resetTail(from id: Int64) { events = []; lastEventId = id }

    // MARK: Policy (via CLI)

    func loadPolicy() async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", "list"]) }.value
        policyText = result?.output ?? "imctl policy list failed"
    }

    func policy(_ verb: String, title: String) async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["policy", verb, "--title", title]) }.value
        append("policy \(verb)", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    // MARK: Daemon (via CLI / launchctl)

    func installDaemon() async {
        let control = self.control, mqtt = mqttEnrolled
        let result = try? await Task.detached { try control.install(mqttEnrolled: mqtt) }.value
        append("agent install", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await refresh()
    }

    func restartDaemon() async {
        let control = self.control
        let result = try? await Task.detached { try control.restart() }.value
        append("launchctl kickstart", result?.output.isEmpty == false ? result!.output : "ok", error: (result?.status ?? 1) != 0)
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }

    func uninstallDaemon() async {
        let control = self.control
        let result = try? await Task.detached { try control.uninstall() }.value
        append("agent uninstall", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await refresh()
    }

    func openAccessibilitySettings() {
        if let url = AXPermission.accessibilitySettingsURL { NSWorkspace.shared.open(url) }
    }

    func openLogs() { NSWorkspace.shared.open(ConsolePaths.logDirectory) }

    // MARK: Settings (local files only, 0600)

    func saveMQTT(host: String, port: Int, tls: Bool, controllerID: String, username: String, password: String, topicPrefix: String) {
        let settings = MQTTSettings(host: host, port: port, controllerID: controllerID, username: username.isEmpty ? nil : username,
                                    password: password.isEmpty ? nil : password, useTLS: tls, topicPrefix: topicPrefix.isEmpty ? "im" : topicPrefix)
        do { try settings.save(to: MQTTSettings.defaultURL); append("mqtt enroll", "saved \(MQTTSettings.defaultURL.path) (0600); controller \(controllerID); restart the daemon to reconnect") }
        catch { append("mqtt enroll", String(describing: error), error: true) }
        mqttEnrolled = FileManager.default.fileExists(atPath: MQTTSettings.defaultURL.path)
    }

    func saveProxy(baseURL: String, token: String) {
        do { try WeComProxySettings(baseURL: baseURL, token: token).save(to: WeComProxySettings.defaultURL); append("wecom enroll", "saved \(WeComProxySettings.defaultURL.path) (0600); restart the daemon to enable the API route") }
        catch { append("wecom enroll", String(describing: error), error: true) }
        proxyEnrolled = FileManager.default.fileExists(atPath: WeComProxySettings.defaultURL.path)
    }

    // MARK: Diagnostics (read-only, in-process)

    func runDiagnostics() async {
        diagnostics = await Task.detached { Diagnostics.run() }.value
        append("diagnostics", (try? JSONEncoder().encode(diagnostics)).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
```

- [ ] **Step 5: 实现应用与视图**

`ConsoleApp.swift`：

```swift
import AppKit
import SwiftUI

@main
struct ConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ConsoleModel()

    var body: some Scene {
        Window("imctl 控制台", id: "console") {
            ConsoleWindow().environment(model)
        }
        .defaultSize(width: 1040, height: 720)
        MenuBarExtra("imctl", systemImage: model.menuBarSymbol) {
            MenuBarMenu().environment(model)
        }
    }
}

/// Menu-bar app: no Dock icon, also when run as a bare executable in development.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

`Views/MenuBarMenu.swift`：

```swift
import SwiftUI

struct MenuBarMenu: View {
    @Environment(ConsoleModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button("打开控制台") { openWindow(id: "console"); NSApp.activate(ignoringOtherApps: true) }
        Button("刷新状态") { Task { await model.refresh() } }
        if model.state?.pausedReasons.contains("api") == true {
            Button("恢复（去掉 api 暂停）") { Task { await model.resume() } }
        } else {
            Button("暂停（api）") { Task { await model.pause() } }
        }
        Button("重启守护进程") { Task { await model.restartDaemon() } }
        Divider()
        Button("退出 imctl 控制台") { NSApp.terminate(nil) }
    }
}
```

`Views/ConsoleWindow.swift`：

```swift
import SwiftUI

enum ConsoleSection: String, CaseIterable, Identifiable {
    case status = "状态", conversations = "会话", send = "发送", events = "事件", policy = "策略", settings = "设置", diagnostics = "诊断", log = "日志"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .status: return "heart.text.square"
        case .conversations: return "bubble.left.and.bubble.right"
        case .send: return "paperplane"
        case .events: return "list.bullet.rectangle"
        case .policy: return "checklist"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        case .log: return "doc.text.magnifyingglass"
        }
    }
}

struct ConsoleWindow: View {
    @Environment(ConsoleModel.self) private var model
    @State private var section: ConsoleSection = .status

    var body: some View {
        NavigationSplitView {
            List(ConsoleSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            Group {
                switch section {
                case .status: StatusView()
                case .conversations: ConversationsView()
                case .send: SendView()
                case .events: EventsView()
                case .policy: PolicyView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                case .log: LogView()
                }
            }
            .padding()
        }
        .task { await model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.refresh()
                if model.tailing { await model.tailOnce() }
            }
        }
        .overlay(alignment: .bottomTrailing) { if model.busy { ProgressView().controlSize(.small).padding() } }
    }
}
```

`Views/StatusView.swift`：

```swift
import SwiftUI

struct StatusView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        Form {
            Section("守护进程 imctld（state.json）") {
                if let s = model.state {
                    LabeledContent("存活", value: s.isAlive ? "是（pid \(s.pid)）" : "否（state.json 残留，pid \(s.pid)）")
                    LabeledContent("版本", value: s.version ?? "-")
                    LabeledContent("运行时长", value: s.uptimeSeconds.map { "\($0 / 60) 分钟" } ?? "-")
                    LabeledContent("暂停原因", value: s.pausedReasons.isEmpty ? "无" : s.pausedReasons.joined(separator: ", "))
                    LabeledContent("守护进程辅助功能", value: s.trusted.map { $0 ? "已授权" : "未授权（系统设置 › 隐私与安全性 › 辅助功能 勾选 imctld）" } ?? "旧版守护进程未上报")
                    LabeledContent("本地套接字", value: s.socket?.isEmpty == false ? s.socket! : "未开（重新安装守护进程即默认开启）")
                    LabeledContent("套接字可达", value: model.socketReachable ? "是" : "否")
                    LabeledContent("观察者 / 轮询 / 错误", value: "\(s.observer == true ? "AX 通知" : "仅轮询") / \(s.polls ?? 0) / \(s.errors ?? 0)")
                    LabeledContent("活动会话 / 会话数", value: "\(s.active?.isEmpty == false ? s.active! : "-") / \(s.conversations ?? 0)")
                    LabeledContent("最新事件 id", value: "\(s.lastEventId ?? 0)")
                    LabeledContent("策略", value: s.policy ?? "-")
                } else {
                    Text(model.stateError ?? "无 state.json").foregroundStyle(.secondary)
                }
            }
            Section("LaunchAgent（imctl agent status）") {
                if let a = model.agent {
                    LabeledContent("已装入", value: a.loaded ? "是" : "否")
                    LabeledContent("状态 / pid", value: "\(a.state ?? "-") / \(a.pid ?? 0)")
                    LabeledContent("上次退出码", value: a.lastExitCode ?? "-")
                } else {
                    Text(model.agentError ?? "-").foregroundStyle(.secondary)
                }
                HStack {
                    Button("安装 / 更新守护进程") { Task { await model.installDaemon() } }
                    Button("重启") { Task { await model.restartDaemon() } }
                    Button("卸载", role: .destructive) { Task { await model.uninstallDaemon() } }
                }
            }
            Section("控制器（controller.describe）") {
                ForEach(model.describe.keys.sorted(), id: \.self) { k in LabeledContent(k, value: model.describe[k] ?? "") }
            }
            Section("本机") {
                LabeledContent("企业微信运行中", value: model.clientRunning ? "是" : "否")
                LabeledContent("控制台辅助功能（只影响诊断页）", value: model.consoleTrusted ? "已授权" : "未授权")
                LabeledContent("MQTT / 代理 已 enroll", value: "\(model.mqttEnrolled ? "是" : "否") / \(model.proxyEnrolled ? "是" : "否")")
                HStack {
                    Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                    Button("打开日志目录") { model.openLogs() }
                    Button("刷新") { Task { await model.refresh() } }
                    if model.state?.pausedReasons.contains("api") == true {
                        Button("恢复") { Task { await model.resume() } }
                    } else {
                        Button("暂停（api）") { Task { await model.pause() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

`Views/ConversationsView.swift`：

```swift
import ControlCore
import SwiftUI

struct ConversationsView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var selected: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Button("读取列表") { Task { await model.loadConversations() } }
                    Button("上一会话") { Task { await model.navigate(.previousConversation) } }
                    Button("下一会话") { Task { await model.navigate(.nextConversation) } }
                    Button("下一未读") { Task { await model.navigate(.nextUnreadConversation) } }
                }
                List(model.conversations, id: \.["index"], selection: $selected) { row in
                    HStack {
                        Text(row["title"] ?? "-").bold(row["selected"] == "true")
                        Spacer()
                        Text(row["conversationType"] ?? "").foregroundStyle(.secondary)
                        if let b = row["badge"], !b.isEmpty { Text(b).padding(.horizontal, 6).background(.red.opacity(0.2)).clipShape(Capsule()) }
                    }
                    .tag(row["index"] ?? "")
                }
                Button("打开选中会话（conversation.read）") {
                    if let title = model.conversations.first(where: { $0["index"] == selected })?["title"] { Task { await model.open(title) } }
                }
                .disabled(selected == nil)
            }
            .frame(minWidth: 320)
            VStack(alignment: .leading) {
                HStack {
                    Text("活动会话：\(model.activeTitle.isEmpty ? "-" : model.activeTitle)").bold()
                    Spacer()
                    Button("读 30 条") { Task { await model.loadHistory() } }
                    Button("回滚读 60 条") { Task { await model.loadHistory(limit: 60, scrollback: true) } }
                }
                List(model.messages, id: \.["index"]) { m in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(m["direction"] ?? "").font(.caption).foregroundStyle(.secondary)
                            if let s = m["sender"] { Text(s).font(.caption) }
                            if let t = m["timeLabel"] { Text(t).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(m["messageKey"] ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text(m["text"] ?? "").textSelection(.enabled)
                    }
                }
            }
            .frame(minWidth: 400)
        }
    }
}
```

`Views/SendView.swift`：

```swift
import SwiftUI
import WeComAdapter

struct SendView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var target = WeComClient.fileTransferAssistantTitle
    @State private var text = ""
    @State private var result = ""

    var body: some View {
        Form {
            Section("message.send（经守护进程：策略、幂等键、速率上限、事件）") {
                TextField("目标：标题 | chatId:<id> | externalUserId:<id>", text: $target)
                TextEditor(text: $text).frame(minHeight: 120).font(.body.monospaced())
                HStack {
                    Button("发送") {
                        let t = target, x = text
                        Task { result = await model.send(target: t, text: x) }
                    }
                    .disabled(text.isEmpty || target.isEmpty || model.busy)
                    Text("白名单：\(model.describe["allowlist"] ?? "-") · 策略：\(model.describe["policy"] ?? "-")").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("结果") {
                ScrollView { Text(result).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 160)
            }
        }
        .formStyle(.grouped)
    }
}
```

`Views/EventsView.swift`：

```swift
import SwiftUI

struct EventsView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var filter = ""
    @State private var from = ""

    var rows: [EventRow] { filter.isEmpty ? model.events : model.events.filter { $0.kind.contains(filter) || $0.payload.contains(filter) } }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Toggle("实时跟踪（每 3 s event.replay）", isOn: Binding(get: { model.tailing }, set: { model.tailing = $0 }))
                Button("拉取一次") { Task { await model.tailOnce() } }
                TextField("从事件 id 之后重放", text: $from).frame(width: 160)
                Button("重置游标") { model.resetTail(from: Int64(from) ?? 0); Task { await model.tailOnce() } }
                TextField("过滤 kind / payload", text: $filter).frame(width: 200)
                Spacer()
                Text("游标 \(model.lastEventId) · \(rows.count) 条").foregroundStyle(.secondary)
            }
            Table(rows) {
                TableColumn("id") { Text("\($0.id)") }.width(60)
                TableColumn("时间") { Text(Date(timeIntervalSince1970: Double($0.tsMs) / 1000), style: .time) }.width(80)
                TableColumn("kind", value: \.kind).width(160)
                TableColumn("payload") { Text($0.payload).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled) }
            }
        }
    }
}
```

`Views/PolicyView.swift`：

```swift
import SwiftUI

struct PolicyView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var title = ""

    var body: some View {
        Form {
            Section("policy.json（imctl policy list）") {
                Text(model.policyText.isEmpty ? "点击刷新" : model.policyText).font(.body.monospaced()).textSelection(.enabled)
                Button("刷新") { Task { await model.loadPolicy() } }
            }
            Section("放宽 / 收回（人的决定；只对测试群与本人微信）") {
                TextField("会话标题（与客户端完全一致，例如 imctl测试群）", text: $title)
                HStack {
                    Button("允许标题") { let t = title; Task { await model.policy("allow", title: t) } }.disabled(title.isEmpty)
                    Button("收回标题", role: .destructive) { let t = title; Task { await model.policy("deny", title: t) } }.disabled(title.isEmpty)
                }
                Text("类型 / chatId / externalUserId 规则请用终端：imctl policy allow --type group --chat-id … --external-user-id …").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadPolicy() }
    }
}
```

`Views/SettingsView.swift`：

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var host = ""
    @State private var port = "1883"
    @State private var tls = false
    @State private var controllerID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var topicPrefix = "im"
    @State private var proxyURL = ""
    @State private var proxyToken = ""

    var body: some View {
        Form {
            Section("MQTT（写 mqtt.json，0600；不入库）\(model.mqttEnrolled ? " · 已存在" : "")") {
                TextField("broker 主机", text: $host)
                TextField("端口", text: $port)
                Toggle("TLS", isOn: $tls)
                TextField("controller id（一机一号一 id）", text: $controllerID)
                TextField("用户名（可选）", text: $username)
                SecureField("密码（可选）", text: $password)
                TextField("topic 前缀", text: $topicPrefix)
                Button("保存 MQTT 设置") {
                    model.saveMQTT(host: host, port: Int(port) ?? (tls ? 8883 : 1883), tls: tls, controllerID: controllerID,
                                   username: username, password: password, topicPrefix: topicPrefix)
                    password = ""
                }
                .disabled(host.isEmpty || controllerID.isEmpty)
            }
            Section("企微令牌代理（写 wecom-proxy.json，0600；secret 只在代理）\(model.proxyEnrolled ? " · 已存在" : "")") {
                TextField("代理地址 https://…", text: $proxyURL)
                SecureField("Bearer token", text: $proxyToken)
                Button("保存代理设置") { model.saveProxy(baseURL: proxyURL, token: proxyToken); proxyToken = "" }
                    .disabled(proxyURL.isEmpty || proxyToken.isEmpty)
            }
            Section { Text("保存后在「状态」页重启守护进程生效；安装守护进程时若 mqtt.json 存在会自动带 --mqtt。").font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
```

`Views/DiagnosticsView.swift`：

```swift
import SwiftUI

struct DiagnosticsView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        Form {
            Section("只读诊断（控制台进程内的 AX，不按任何东西；需要控制台自己的辅助功能授权）") {
                Button("运行诊断") { Task { await model.runDiagnostics() } }
                if let d = model.diagnostics {
                    LabeledContent("控制台辅助功能", value: d.consoleTrusted ? "已授权" : "未授权（状态页 › 打开辅助功能设置，勾选 imctl 控制台）")
                    LabeledContent("企业微信运行中", value: d.clientRunning ? "是" : "否")
                    LabeledContent("窗口", value: d.windowFrame ?? "-")
                    LabeledContent("会话表", value: d.conversationTable ?? "-")
                    LabeledContent("消息表", value: d.messageTable ?? "-")
                    LabeledContent("输入框", value: d.composerPresent.map { $0 ? "有" : "无（通知类会话）" } ?? "-")
                    LabeledContent("活动会话 / 类型", value: "\(d.activeTitle ?? "-") / \(d.activeType ?? "-")")
                    LabeledContent("会话行数 / 行高", value: "\(d.conversationCount ?? 0) / \(d.rowHeights?.map(String.init).joined(separator: ",") ?? "-")")
                    LabeledContent("窗口菜单", value: d.windowMenuItems?.joined(separator: " · ") ?? "-")
                    if let e = d.error { Text(e).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

`Views/LogView.swift`：

```swift
import SwiftUI

struct LogView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("每次调用的请求 / 结果（\(model.log.count)）"); Spacer(); Button("清空") { model.log = [] } }
            List(model.log.reversed()) { e in
                VStack(alignment: .leading) {
                    HStack { Text(e.time, style: .time); Text(e.title).bold().foregroundStyle(e.isError ? .red : .primary) }
                    Text(e.body).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
```

- [ ] **Step 6: 编译检查**

Run: `swift build --build-tests`
Expected: 成功

---

### Task 7: 应用包、安装包脚本与文档

**Files:**
- Create: `packaging/console/Info.plist.in`、`packaging/pkg/distribution.xml.in`、`packaging/pkg/resources/welcome.txt`、`readme.txt`、`conclusion.txt`、`packaging/pkg/scripts/postinstall`
- Create: `scripts/signing-identity.sh`、`scripts/build-app.sh`、`scripts/build-pkg.sh`；Modify: `scripts/build-signed.sh`（改用 `signing-identity.sh`；`IMCTL_HARDENED=1` 时 `--options runtime --timestamp`）
- Create: `docs/ops/installer.md`；Modify: `.gitignore`（`out/`）、`README.md`、`docs/ops/launchagent.md`、`docs/ai-coding/AI_DIRECTORY_STRUCTURE_GUIDE.md`、`docs/ai-coding/AI_CODING_GUIDE.md`

**Interfaces:**
- `scripts/build-app.sh [debug|release]` → 打印 `out/imctl.app`（`Contents/MacOS/{imctl-console, imctl, imctld}`；控制台 identifier `com.sunkailun.imctl.console`，CLI / 守护进程保持 `com.sunkailun.imctl`）
- `scripts/build-pkg.sh [debug|release]` → 打印 `out/imctl-<version>.pkg`；环境变量 `IMCTL_INSTALLER_IDENTITY`（Developer ID Installer）、`IMCTL_NOTARY_PROFILE`、`IMCTL_HARDENED=1`
- `postinstall`：`$2/Applications/imctl.app/Contents/MacOS/imctl` → `/usr/local/bin/imctl`（可写才做）

- [ ] **Step 1: 验收命令（先写，作为本任务的"测试"）**

```bash
scripts/build-pkg.sh debug
codesign --verify --deep --strict --verbose=2 out/imctl.app
codesign -dv --verbose=2 out/imctl.app/Contents/MacOS/imctld 2>&1 | grep -E '^Identifier=com.sunkailun.imctl$'
codesign -dv --verbose=2 out/imctl.app 2>&1 | grep -E '^Identifier=com.sunkailun.imctl.console$'
pkgutil --payload-files out/imctl-0.1.0.pkg | grep -E 'MacOS/(imctl|imctld|imctl-console)$'
installer -pkg out/imctl-0.1.0.pkg -target CurrentUserHomeDirectory
"$HOME/Applications/imctl.app/Contents/MacOS/imctl" version
```

Expected（实现前）：`scripts/build-pkg.sh: No such file or directory`。

- [ ] **Step 2: 实现脚本**

`scripts/signing-identity.sh`：

```bash
#!/usr/bin/env bash
# Print the code-signing identity imctl uses (first match wins):
#   1. $IMCTL_SIGN_IDENTITY  2. "Developer ID Application" for $IMCTL_SIGN_TEAM_ID (default FCZGS779KT)
#   3. "Apple Development" for $IMCTL_SIGN_TEAM (default JVL9CBM345)
set -euo pipefail
TEAM="${IMCTL_SIGN_TEAM:-JVL9CBM345}"
TEAM_ID="${IMCTL_SIGN_TEAM_ID:-FCZGS779KT}"
if [[ -n "${IMCTL_SIGN_IDENTITY:-}" ]]; then echo "$IMCTL_SIGN_IDENTITY"; exit 0; fi
pick() { grep "$1" | grep -E "\((${TEAM}|${TEAM_ID})\)" | head -1 | sed -E 's/.*"(.*)".*/\1/'; }
IDS="$(security find-identity -v -p codesigning)"
IDENTITY="$(pick "Developer ID Application" <<<"$IDS" || true)"
[[ -n "$IDENTITY" ]] || IDENTITY="$(pick "Apple Development" <<<"$IDS" || true)"
[[ -n "$IDENTITY" ]] || { echo "no code-signing identity for team $TEAM/$TEAM_ID; set IMCTL_SIGN_IDENTITY" >&2; exit 1; }
echo "$IDENTITY"
```

`scripts/build-signed.sh`：身份选择段替换为 `IDENTITY="$(scripts/signing-identity.sh)"`；`OPTS` 段改为

```bash
OPTS=(--timestamp=none)
[[ "${IMCTL_HARDENED:-0}" == "1" ]] && OPTS=(--options runtime --timestamp)
…
  codesign --force --sign "$IDENTITY" --identifier "$IDENT_ID" "${OPTS[@]}" "$B"
```

`scripts/build-app.sh`：

```bash
#!/usr/bin/env bash
# Assemble and sign out/imctl.app: the console as the main executable plus the
# imctl CLI and the imctld daemon next to it. The CLI and daemon keep the
# identifier com.sunkailun.imctl (signed by build-signed.sh) so the
# Accessibility grant survives updates; the console is com.sunkailun.imctl.console.
# Usage: scripts/build-app.sh [debug|release]   (prints the .app path)
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-release}"
OUT="${IMCTL_OUT_DIR:-out}"
APP="$OUT/imctl.app"
APP_ID="com.sunkailun.imctl.console"

CLI="$(scripts/build-signed.sh "$CFG")"
BINDIR="$(dirname "$CLI")"
swift build -c "$CFG" --product imctl-console >/dev/null

VERSION="$(sed -nE 's/.*public static let string = "([0-9]+\.[0-9]+\.[0-9]+)[^"]*".*/\1/p' Sources/ControlCore/IMCTLVersion.swift)"
[[ -n "$VERSION" ]] || { echo "cannot read the version from IMCTLVersion.swift" >&2; exit 1; }
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/console/Info.plist.in > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BINDIR/imctl-console" "$BINDIR/imctl" "$BINDIR/imctld" "$APP/Contents/MacOS/"

IDENTITY="$(scripts/signing-identity.sh)"
OPTS=(--timestamp=none)
[[ "${IMCTL_HARDENED:-0}" == "1" ]] && OPTS=(--options runtime --timestamp)
codesign --force --sign "$IDENTITY" --identifier "$APP_ID" "${OPTS[@]}" "$APP/Contents/MacOS/imctl-console"
codesign --force --sign "$IDENTITY" "${OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed $APP with: $IDENTITY (version $VERSION build $BUILD)" >&2
echo "$APP"
```

`scripts/build-pkg.sh`：

```bash
#!/usr/bin/env bash
# Build out/imctl-<version>.pkg from out/imctl.app. Unsigned by default
# (development: install with `installer -pkg … -target CurrentUserHomeDirectory`
# or `sudo installer -pkg … -target /`). With IMCTL_INSTALLER_IDENTITY
# ("Developer ID Installer: …") the product is signed; with IMCTL_NOTARY_PROFILE
# (a `notarytool store-credentials` profile) it is also notarized and stapled —
# then build with IMCTL_HARDENED=1 so the binaries pass notarization.
# Usage: scripts/build-pkg.sh [debug|release]   (prints the .pkg path)
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-release}"
OUT="${IMCTL_OUT_DIR:-out}"
APP="$(scripts/build-app.sh "$CFG")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$OUT/pkg"
rm -rf "$STAGE"
mkdir -p "$STAGE/root/Applications"
cp -R "$APP" "$STAGE/root/Applications/"
pkgbuild --root "$STAGE/root" --identifier com.sunkailun.imctl.pkg --version "$VERSION" --install-location / \
  --scripts packaging/pkg/scripts "$STAGE/imctl-component.pkg" >/dev/null
sed -e "s/__VERSION__/$VERSION/g" packaging/pkg/distribution.xml.in > "$STAGE/distribution.xml"
productbuild --distribution "$STAGE/distribution.xml" --resources packaging/pkg/resources --package-path "$STAGE" \
  "$STAGE/imctl-unsigned.pkg" >/dev/null
PKG="$OUT/imctl-$VERSION.pkg"
if [[ -n "${IMCTL_INSTALLER_IDENTITY:-}" ]]; then
  productsign --sign "$IMCTL_INSTALLER_IDENTITY" "$STAGE/imctl-unsigned.pkg" "$PKG" >/dev/null
  if [[ -n "${IMCTL_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$PKG" --keychain-profile "$IMCTL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
  fi
  echo "signed pkg: $PKG" >&2
else
  mv -f "$STAGE/imctl-unsigned.pkg" "$PKG"
  echo "unsigned development pkg: $PKG (install: installer -pkg \"$PKG\" -target CurrentUserHomeDirectory, or sudo … -target /)" >&2
fi
echo "$PKG"
```

`packaging/console/Info.plist.in`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>imctl 控制台</string>
	<key>CFBundleExecutable</key>
	<string>imctl-console</string>
	<key>CFBundleIdentifier</key>
	<string>com.sunkailun.imctl.console</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>imctl</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>__VERSION__</string>
	<key>CFBundleVersion</key>
	<string>__BUILD__</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
```

`packaging/pkg/distribution.xml.in`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>imctl __VERSION__</title>
    <organization>com.sunkailun</organization>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <readme file="readme.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.sunkailun.imctl.pkg"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.sunkailun.imctl.pkg" visible="false">
        <pkg-ref id="com.sunkailun.imctl.pkg"/>
    </choice>
    <pkg-ref id="com.sunkailun.imctl.pkg" version="__VERSION__" onConclusion="none">imctl-component.pkg</pkg-ref>
</installer-gui-script>
```

`packaging/pkg/resources/welcome.txt`：

```text
imctl —— macOS 企业微信消息端控制器

本安装包把 imctl.app 放到 应用程序 文件夹：
  · imctl 控制台（菜单栏应用）：状态、会话、发送、事件、策略、设置、诊断
  · imctl 命令行（同时链接到 /usr/local/bin/imctl，系统级安装时）
  · imctld 守护进程（由控制台或 imctl agent install 安装为登录项）

安装包本身不修改 launchd，也不申请任何系统权限。
```

`packaging/pkg/resources/readme.txt`：

```text
安装后的三步：
1. 打开 应用程序 › imctl.app，菜单栏出现 imctl 图标，点「打开控制台」。
2. 「状态」页点「安装 / 更新守护进程」（有 mqtt.json 时自动带 --mqtt）。
3. 系统会提示辅助功能授权：系统设置 › 隐私与安全性 › 辅助功能 里勾选 imctld；
   诊断页要在控制台进程内读客户端时再勾选 imctl 控制台。除辅助功能外不申请任何权限。

发送目标只有编译进代码的 文件传输助手，放宽由「策略」页写 policy.json（人的决定）。
升级：安装新包后在「状态」页点「重启」；辅助功能授权保持（签名身份不变）。
```

`packaging/pkg/resources/conclusion.txt`：

```text
安装完成。请打开 应用程序 › imctl.app 完成守护进程安装与辅助功能授权。
```

`packaging/pkg/scripts/postinstall`：

```bash
#!/bin/sh
# Runs as root for a system install ($2 = /) or as the user for a home install
# ($2 = ~). Only links the CLI; launchd and Accessibility are set up from
# imctl 控制台 inside the user's session, never from the installer.
APP="$2/Applications/imctl.app"
CLI="$APP/Contents/MacOS/imctl"
if [ -x "$CLI" ]; then
  if [ -w /usr/local/bin ] || { [ "$(id -u)" = "0" ] && mkdir -p /usr/local/bin; }; then
    ln -sfn "$CLI" /usr/local/bin/imctl
  fi
fi
exit 0
```

`chmod +x packaging/pkg/scripts/postinstall scripts/build-app.sh scripts/build-pkg.sh scripts/signing-identity.sh`。`.gitignore` 追加 `out/`。

- [ ] **Step 3: 文档**

`docs/ops/installer.md`：

```markdown
# 安装包与控制台（B6，2026-09-15）

## 产物

| 文件 | 内容 | 脚本 |
|---|---|---|
| `out/imctl.app` | `Contents/MacOS/imctl-console`（控制台，`com.sunkailun.imctl.console`）+ `imctl` + `imctld`（保持 `com.sunkailun.imctl`，TCC 跨升级保持） | `scripts/build-app.sh [debug|release]` |
| `out/imctl-<version>.pkg` | 装到 `/Applications/imctl.app`（或 `~/Applications`）；`postinstall` 只做 `/usr/local/bin/imctl` 链接 | `scripts/build-pkg.sh [debug|release]` |

版本来自 `IMCTLVersion.string`（去掉 `-dev`），build 号 = `git rev-list --count HEAD`。

## 签名与公证

- 开发：Apple Development（`scripts/signing-identity.sh` 选择），`.pkg` 不签名。安装：`installer -pkg out/imctl-0.1.0.pkg -target CurrentUserHomeDirectory`（装到 `~/Applications`，不需要 sudo）或 `sudo installer -pkg … -target /`。
- 发布：`IMCTL_HARDENED=1 IMCTL_INSTALLER_IDENTITY="Developer ID Installer: …" IMCTL_NOTARY_PROFILE=<profile> scripts/build-pkg.sh release`（`xcrun notarytool store-credentials <profile>` 先存好）。换成 Developer ID Application 后 designated requirement 变化，首次要重新勾选辅助功能。

## 安装后的三步（控制台）

1. 打开 `imctl.app` → 菜单栏图标 → 打开控制台。
2. 状态页「安装 / 更新守护进程」= `imctl agent install --socket ~/Library/Application Support/imctl/run/imctl.sock [--mqtt]`（守护进程路径 = 包内 `imctld`）。
3. 勾选辅助功能：`imctld`（守护进程读写客户端）；`imctl 控制台` 只在用诊断页时需要。安装包与控制台不申请录屏 / 输入监控。

## 控制台能做什么 / 不能做什么

- 经守护进程套接字（与 Java 同一路径，策略 / 幂等 / 速率 / 事件一致）：`conversation.list|read`、`message.history|send`、`client.navigate`、`controller.pause|resume`、`event.replay` 实时跟踪。
- 经 CLI：`agent install|uninstall|status`、`policy list|allow|deny`；`launchctl kickstart -k` 重启。
- 进程内只读：诊断页（布局、活动会话、窗口菜单）；写 `mqtt.json` / `wecom-proxy.json`（0600）。
- 不做：任何绕过守护进程的客户端写操作；不是 LLM 自主控制器。

## 开发期直接跑

```bash
scripts/build-app.sh debug
IMCTL_SOCKET=/tmp/x/s.sock IMCTL_STATE=/tmp/x/state.json out/imctl.app/Contents/MacOS/imctl-console   # 从终端启动：环境变量覆盖、继承终端的辅助功能授权
open out/imctl.app                                                                                         # 作为普通应用启动：走默认路径，需要自己的授权
```

## 验证

`codesign --verify --deep --strict out/imctl.app`；`pkgutil --payload-files out/imctl-<v>.pkg`；装后 `~/Applications/imctl.app/Contents/MacOS/imctl version`；`imctl call controller.describe`。

## 卸载

控制台「卸载」（`imctl agent uninstall`）→ 删除 `imctl.app` 与 `/usr/local/bin/imctl` → 数据在 `~/Library/Application Support/imctl`、日志在 `~/Library/Logs/imctl`，按需删除。
```

`README.md`：模块表加行 `| \`imctl-console\` | 菜单栏测试控制台（SwiftUI）：状态 / 会话 / 发送 / 事件 / 策略 / 设置 / 诊断 / 日志；改客户端状态只经 imctld 套接字 | B6 |`；「构建与测试」加 `scripts/build-app.sh`、`scripts/build-pkg.sh`、`imctl call client.navigate --params '{"action":"nextConversation","idempotencyKey":"n1"}'`、`imctl probe menubar`；「文档」加 `docs/ops/installer.md`。`docs/ops/launchagent.md` 在「安装 / 更新」后加一段"安装包形态：`/Applications/imctl.app/Contents/MacOS/imctld`，由控制台安装，`--socket` 默认开启"。`AI_DIRECTORY_STRUCTURE_GUIDE.md` 加 `Sources/imctl-console/`（`Model/` 可测逻辑、`Views/` SwiftUI）、`packaging/`（Info.plist 模板、pkg 资源与脚本）、`out/`（忽略）三行；`AI_CODING_GUIDE.md` 分层表加 `imctl-console` 行（依赖全部库 + SwiftUI/AppKit；禁止：任何绕过执行器的客户端写操作）。

- [ ] **Step 4: 运行 Step 1 的验收命令**

Expected: 全部通过；`imctl version` 打印 `0.1.0-dev`。

---

### Task 8: 一次 `swift test`、活体 E2E、门报告、提交与 wiki

- [ ] **Step 1: 全量测试**

Run: `swift test 2>&1 | tail -5`
Expected: 全部通过；记录用例数（预计 ≥ 215）。

- [ ] **Step 2: 活体（客户端在消息视图，文件传输助手为活动会话）**

```bash
scripts/build-signed.sh debug >/dev/null
B=.build/arm64-apple-macosx/debug
$B/imctl probe conversations | head -3          # 64 px 行，含 文件传输助手（不再是筛选面板）
$B/imctl probe menubar                          # 窗口菜单三项，[disabled] 标记
T=$(mktemp -d /tmp/imctl-b6.XXXX); mkdir -m 700 $T/run
$B/imctld run --db $T/imctl.sqlite --state $T/state.json --socket $T/run/s.sock --watch-interval 2 2>$T/daemon.log &
sleep 3; $B/imctl status --state $T/state.json --db $T/imctl.sqlite | grep -E 'trusted|socket|paused'
$B/imctl call --socket $T/run/s.sock client.navigate --params '{"action":"nextConversation","idempotencyKey":"b6-n1"}'
$B/imctl call --socket $T/run/s.sock client.navigate --params '{"action":"previousConversation","idempotencyKey":"b6-n2"}'   # after == 文件传输助手
$B/imctl call --socket $T/run/s.sock client.navigate --params '{"action":"nextConversation","idempotencyKey":"b6-n1"}'       # 同键回放，不再按
IMCTL_SOCKET=$T/run/s.sock IMCTL_STATE=$T/state.json IMCTL_CLI=$B/imctl out/imctl.app/Contents/MacOS/imctl-console &        # 控制台连临时守护进程
```

控制台用 AX 驱动验证（`imctl dump-tree --bundle com.sunkailun.imctl.console --root app`）：菜单栏项存在、控制台窗口各页可达；会话页「读取列表」「下一会话」「上一会话」；发送页向 文件传输助手 发 1 条 `imctl console b6`；事件页出现 `command.state` 与 `message.observed{origin:controller}`。结束：`kill %1 %2`，`rm -rf $T`。

- [ ] **Step 3: 安装包**

`scripts/build-pkg.sh debug` → `installer -pkg out/imctl-0.1.0.pkg -target CurrentUserHomeDirectory` → `~/Applications/imctl.app/Contents/MacOS/imctl version`；不切换现有 LaunchAgent（用户决定何时改用包内守护进程）。

- [ ] **Step 4: 门报告 `docs/gates/2026-09-15-b6-installer-console-navigate.md`**

条件、实现、单测数字、活体表（探针 / 导航 / 控制台 / 安装包）、结论、未闭环（Developer ID、LaunchAgent 切换、控制台授权、视图切换不可达）。

- [ ] **Step 5: 提交推送**

```bash
swift test 2>&1 | tail -3 && bash scripts/check-secrets.sh && git status --short
git add -A && git commit -m "feat(b6): client.navigate via the client's 窗口 menu, UnixSocketClient + imctl call, imctl-console menu-bar test console (SwiftUI, daemon-socket path only), signed imctl.app + .pkg build scripts, filter-side-panel layout fix, state.json trusted/socket, agent install --socket default; gate report" && git push
```

- [ ] **Step 6: wiki 归档**

`queries/2026-09-15-imctl批次B6安装包控制台与菜单导航记忆.md`（证据）、覆写 `repos/imctl.md` / topic 稳定区（只替换，≤ 200 行）/ `synthesis` 路线页 / `overview.md` 状态行（≤ 260 字）/ `review/待复核清单.md`（"控制台授权与 LaunchAgent 切换"）、`log.md` 追加；不暂存 `工作区/美联` 下他人改动；validator 0 失败；提交推送。

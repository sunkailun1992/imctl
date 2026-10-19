# S5 WeComAdapter 只读解析 + probe conversations/messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从企微主窗口的 AX 树解析出会话表行、活动会话标题、消息区行（含几何与方向推导），`imctl probe conversations` / `probe messages` 输出结构化结果；解析逻辑全部对录制夹具 `Tests/Fixtures/ax-trees/wecom-5.0.10-main-window.json` 做单元测试。

**Architecture:** 三层：`WeComWindowLocator`（app → 主窗口，`AXMainWindow` 优先，因窗口在另一 Space 时 `AXWindows` 为空）→ `WeComLayout`（按角色 + 几何 + 可设属性定位五个区域：会话表、活动标题、消息表、输入框、搜索框；**不用固定路径与 `_NS:` 标识符**）→ 行解析器（`ConversationRowParser`、`MessageRowParser`）。方向推导是独立纯函数 `DirectionInference`，只吃两个 `CGRect`，阈值明确，不确定即 `unknown`——S3 夹具里唯一一条消息左右边距几乎相等（599 vs 600），结论必须是 `unknown`，G0-2 要等有入站+出站样本再定。协议枚举 `MessageDirection` 放 ControlCore。

**Tech Stack:** AXKit（`AXElement`、`FakeAXBackend`）、ControlCore、swift-argument-parser。

## Global Constraints

- 本任务不调用 `setAttribute` / `performAction`。
- 解析器只依赖角色、子角色、几何、可设属性、值；`_NS:*` 标识符只能作为 `identifier` 字段透传，不作为选择依据。
- probe 输出默认脱敏（`--no-redact` 才打印真实标题）；门报告里不出现真实联系人。
- 夹具根是 `AXWindow`；解析入口接受窗口元素。

---

### Task 1: `MessageDirection` 与 `DirectionInference`

**Files:**
- Create: `Sources/ControlCore/Protocol/MessageDirection.swift`
- Create: `Sources/WeComAdapter/DirectionInference.swift`
- Test: `Tests/WeComAdapterTests/DirectionInferenceTests.swift`

**Interfaces:**

```swift
// ControlCore
public enum MessageDirection: String, Codable, Equatable { case inbound, outbound, unknown }

// WeComAdapter
public struct DirectionInference {
    /// 左边距 < 右边距 × ratio → inbound；右边距 < 左边距 × ratio → outbound；否则 unknown。
    public var ratio: CGFloat = 0.6
    public init(ratio: CGFloat = 0.6)
    public func infer(body: CGRect, container: CGRect) -> MessageDirection
}
```

- [ ] **Step 1: 写失败测试**

```swift
import CoreGraphics
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("DirectionInference")
struct DirectionInferenceTests {
    let table = CGRect(x: 310, y: 63, width: 1611, height: 933)
    let infer = DirectionInference()

    @Test func leftAlignedIsInbound() {
        #expect(infer.infer(body: CGRect(x: 380, y: 100, width: 400, height: 20), container: table) == .inbound)
    }
    @Test func rightAlignedIsOutbound() {
        #expect(infer.infer(body: CGRect(x: 1450, y: 100, width: 400, height: 20), container: table) == .outbound)
    }
    @Test func centeredIsUnknown() {
        // The single message in the S3 fixture: gaps 599 / 600.
        #expect(infer.infer(body: CGRect(x: 909, y: 106, width: 412, height: 15), container: table) == .unknown)
    }
    @Test func degenerateFramesAreUnknown() {
        #expect(infer.infer(body: .zero, container: table) == .unknown)
        #expect(infer.infer(body: CGRect(x: 0, y: 0, width: 10, height: 10), container: .zero) == .unknown)
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(adapter): add MessageDirection and geometry-based DirectionInference`

### Task 2: `WeComWindowLocator` 与 `WeComLayout`

**Files:**
- Create: `Sources/WeComAdapter/WeComError.swift`
- Create: `Sources/WeComAdapter/WeComWindowLocator.swift`
- Create: `Sources/WeComAdapter/WeComLayout.swift`
- Create: `Tests/WeComAdapterTests/FixtureLoading.swift`（`Fixtures.mainWindow() -> FakeAXBackend`，路径由 `#filePath` 推 `Tests/Fixtures/ax-trees/`）
- Test: `Tests/WeComAdapterTests/WeComLayoutTests.swift`

**Interfaces:**

```swift
public enum WeComError: Error, Equatable, CustomStringConvertible {
    case noWindow, region(String)   // region("conversationTable") 等
}

public enum WeComWindowLocator {
    /// root 是 AXWindow → 原样；AXApplication → AXMainWindow ?? AXFocusedWindow ?? AXWindows.first；否则 noWindow
    public static func mainWindow(from root: AXElement) throws -> AXElement
}

public struct WeComLayout {
    public let window: AXElement
    public let windowFrame: CGRect
    public let conversationTable: AXElement    // 最靠左的 AXTable（minX 最小）
    public let conversationTableFrame: CGRect
    public let messageTable: AXElement         // 其余 AXTable 中最宽的
    public let messageTableFrame: CGRect
    public let composer: AXElement             // settable 含 AXValue 的 AXTextArea 中面积最大者
    public let composerFrame: CGRect
    public let activeTitle: AXElement?         // AXStaticText：minY < messageTableFrame.minY 且 minX >= conversationTableFrame.maxX，取 minY 最小者
    public let searchField: AXElement?         // 第一个 AXTextField
    public static func locate(in window: AXElement) throws -> WeComLayout
}
```

实现要点：一次 BFS 收集全部后代（深度上限 12，节点上限 2000），按 `role()` 分桶再按几何挑选；缺表/缺输入框抛 `region(...)`。

- [ ] **Step 1: 写失败测试**

```swift
@Suite("WeComLayout on 5.0.10 fixture")
struct WeComLayoutTests {
    @Test func locatesFiveRegionsByGeometry() throws {
        let fake = try Fixtures.mainWindow()
        let window = try WeComWindowLocator.mainWindow(from: fake.rootElement)
        let layout = try WeComLayout.locate(in: window)
        #expect(layout.windowFrame.width == 1920)
        #expect(layout.conversationTableFrame.minX < 100 && layout.conversationTableFrame.width < 400)
        #expect(layout.messageTableFrame.width > 1000)
        #expect(try layout.composer.identifier() == "_NS:30")
        #expect(try layout.composer.isSettable(AXAttribute.value))
        #expect(try layout.activeTitle?.valueString() == "文件传输助手")
        #expect(try layout.searchField?.role() == AXRole.textField)
    }

    @Test func missingTableIsReportedAsRegionError() throws {
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(throws: WeComError.region("conversationTable")) { try WeComLayout.locate(in: fake.rootElement) }
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(adapter): locate WeCom window regions by role and geometry`

### Task 3: `ConversationRow` / `MessageRow` 解析

**Files:**
- Create: `Sources/WeComAdapter/ConversationRow.swift`（模型 + `ConversationRowParser`）
- Create: `Sources/WeComAdapter/MessageRow.swift`（模型 + `MessageRowParser`）
- Create: `Sources/WeComAdapter/WeComReader.swift`（门面）
- Test: `Tests/WeComAdapterTests/ConversationRowParserTests.swift`、`Tests/WeComAdapterTests/MessageRowParserTests.swift`

**Interfaces:**

```swift
public struct ConversationRow: Equatable {
    public var index: Int                 // 表中行序（含高度 0 行）
    public var title: String?
    public var preview: String?
    public var timeLabel: String?
    public var badge: String?             // 小 AXTextArea 的值（未读数/草稿标记），原文
    public var avatarTitle: String?       // AXImage 的 title（可能带类型标记）
    public var selected: Bool
    public var frame: CGRect
    public var handle: AXElementHandle    // AXRow
}
public struct ConversationRowParser {
    /// 跳过高度为 0 的行与非 AXRow；单元格内 AXStaticText 按几何分配：
    /// 最上且最左 = title；与 title 同列、在其下方 = preview；顶部靠右（maxX ≥ cell.maxX − 40）= timeLabel。
    public func parse(table: AXElement) throws -> [ConversationRow]
}

public struct MessageRow: Equatable {
    public var index: Int
    public var text: String?              // AXTextArea 值，其次非时间的 AXStaticText
    public var timeLabel: String?
    public var bodyFrame: CGRect?
    public var direction: MessageDirection
    public var senderLabel: String?       // 群会话：正文上方的 AXStaticText（本夹具无，留 nil）
    public var frame: CGRect
    public var handle: AXElementHandle
}
public struct MessageRowParser {
    public var direction = DirectionInference()
    public func parse(table: AXElement, tableFrame: CGRect) throws -> [MessageRow]
}

public struct WeComReader {
    public init(window: AXElement) throws       // 内部 WeComLayout.locate
    public let layout: WeComLayout
    public func conversations() throws -> [ConversationRow]
    public func activeConversationTitle() throws -> String?
    public func messages() throws -> [MessageRow]
    public func composerValue() throws -> String?
}
```

时间标签判定复用 `AXRedactionPolicy.defaultKeepPattern`（数字/日期/时间）。

- [ ] **Step 1: 写失败测试（对夹具的具体期望）**

```swift
@Suite("ConversationRowParser on 5.0.10 fixture")
struct ConversationRowParserTests {
    @Test func parsesSixRowsSkippingZeroHeight() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        let rows = try reader.conversations()
        #expect(rows.count == 6)
        #expect(rows.map(\.index) == [1, 2, 3, 4, 5, 6])
        #expect(rows.allSatisfy { $0.frame.height == 64 })
        let fta = try #require(rows.first { $0.title == "文件传输助手" })
        #expect(fta.selected)
        #expect(fta.timeLabel == "9:18")
        #expect(fta.preview?.hasPrefix("«") == true)
        #expect(rows.filter(\.selected).count == 1)
        #expect(rows.map(\.timeLabel) == ["10:17", "9:18", "9:18", "9:18", "9/2", "8/28"])
        #expect(rows[5].badge != nil)
        #expect(rows[0...4].allSatisfy { $0.badge == nil })
    }
}

@Suite("MessageRowParser on 5.0.10 fixture")
struct MessageRowParserTests {
    @Test func parsesSingleVisibleMessageWithUnknownDirection() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        let rows = try reader.messages()
        #expect(rows.count == 1)
        #expect(rows[0].timeLabel == "9:18")
        #expect(rows[0].text?.hasPrefix("«") == true)
        #expect(rows[0].bodyFrame?.width == 412)
        #expect(rows[0].direction == .unknown)
        #expect(try reader.composerValue() == "")
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS → 提交** `feat(adapter): parse conversation and message rows from the WeCom window`

### Task 4: `imctl probe conversations` / `probe messages`

**Files:**
- Create: `Sources/imctl/Commands/ProbeCommand.swift`（父命令 `probe`，子命令 `conversations`、`messages`）
- Create: `Sources/imctl/Probe/ProbeSession.swift`（共享：live/fixture 取窗口 → `WeComReader`；`--redact` 用 `AXRedactionPolicy.default(keepTexts: [文件传输助手])`）
- Modify: `Sources/imctl/IMCTL.swift`（加 `ProbeCommand.self`）
- Test: `Tests/imctlTests/ProbeCommandTests.swift`

**Interfaces:**
- `imctl probe conversations [--from-fixture <path>] [--json] [--no-redact]` → 每行 `#idx sel=* title | preview | time | badge`。
- `imctl probe messages [--from-fixture <path>] [--json] [--no-redact]` → 首行 `active: <title>`，随后每行 `#idx dir=<inbound|outbound|unknown> time=<t> x=<minX>-<maxX> text=<text>`，末行 `composer: <n> chars`。
- `--json` 输出 `ProbeOutput`（Codable：`conversations` 或 `active/messages/composerLength`）。

- [ ] **Step 1: 写失败测试**

```swift
@Suite("probe commands")
struct ProbeCommandTests {
    @Test func conversationsFromFixtureRedactedByDefault() throws {
        let path = try Fixtures.mainWindowPath()
        let cmd = try ProbeConversationsCommand.parse(["--from-fixture", path])
        let out = try cmd.collect()
        #expect(out.conversations.count == 6)
        #expect(out.conversations.contains { $0.title == "文件传输助手" })
    }
    @Test func messagesFromFixture() throws {
        let path = try Fixtures.mainWindowPath()
        let cmd = try ProbeMessagesCommand.parse(["--from-fixture", path, "--json"])
        let out = try cmd.collect()
        #expect(out.active == "文件传输助手")
        #expect(out.messages.count == 1)
        #expect(out.messages[0].direction == "unknown")
    }
    @Test func probeIsRegistered() {
        let names = IMCTL.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names.contains("probe"))
    }
}
```

`imctlTests` 需要自己的 `Fixtures` 助手（路径同样由 `#filePath` 推）。

- [ ] **Step 2: 确认失败 → 实现 → PASS。**
- [ ] **Step 3: live 运行（只读）：** `imctl probe conversations`、`imctl probe messages`（默认脱敏），结果摘要写入 `docs/gates/2026-09-11-s5-probe-readonly.md`（行数、时间标签、badge 有无、方向分布、耗时）。
- [ ] **Step 4: 提交** `feat(cli): add probe conversations/messages (read-only)`

## Self-Review

- 覆盖：会话表行（标题/未读/预览/类型标记→`avatarTitle`+`badge`）、活动会话标题、消息区行（文本/时间/几何/方向）、`probe conversations`/`probe messages`、夹具测试。群发送者标签（G0-2 群部分）本夹具无样本，字段预留 `senderLabel`，测试不断言。
- 类型一致：`WeComReader` 在 T3 定义，T4 使用；`MessageDirection` 在 T1 定义，T3 `MessageRow.direction` 使用；`Fixtures.mainWindow()` 在 T2 定义，T3/T4 使用。

## 执行结果（2026-09-11）

- 4 个任务完成，`swift test` 46 个测试通过；live 结果见 `docs/gates/2026-09-11-s5-probe-readonly.md`。
- 偏离：会话行时间标签位于预览行而非标题行，`ConversationRowParser` 改为先按"贴右边缘 + 时间样式"取时间再分带；`AXElement.descendants` 放进 AXKit 作通用遍历。

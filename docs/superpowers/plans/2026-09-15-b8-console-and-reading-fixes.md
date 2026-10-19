# 批次 B8：控制台读取 / 发送修正与外部群解析校准 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Batch implement, one `swift test` at the end.

**Goal:** 按 `docs/superpowers/specs/2026-09-15-b8-console-and-reading-fixes-design.md`：外部群标题 / 行标签解析、非文本消息行、控制台会话页刷新、发送页目标选择、设置页补全；活体重发 1 条到三人外部群校准。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，swift-testing，`FakeAXBackend`，SwiftUI；两份新脱敏夹具 `wecom-5.0.11-external-group.json`、`wecom-5.0.11-image-message.json`。

## Global Constraints

- 只读探针与已授权的 1 条发送；不改白名单 / 策略语义；无新合成输入。
- 协议文档同一提交更新（§6.3 / §6.6 / §7.4 / §5）；`ProtocolDocTests` 兜底。
- 夹具脱敏；群标题含本人姓名，不入文档。

### Task 1: WeComLayout 标题候选含文本框；搜索框限定在会话表左侧
- Modify `Sources/WeComAdapter/WeComLayout.swift`；Test `Tests/WeComAdapterTests/WeComLayoutTests.swift`（外部群夹具：标题元素是 `AXTextField`，y 20）。

### Task 2: 行 badge 作为 marker
- Modify `Sources/WeComAdapter/ConversationRow.swift`；Test `GroupParsingTests` + `GroupFixture.conversationRow(badge:)`。

### Task 3: 消息行 media / 居中文本区 system；`kind` 贯穿 history 与事件
- Modify `MessageRow.swift`（`MessageRowKind.media`、解析）、`WeComLayout.swift`（`messageImages`）、`WeComReader.chatMessages`（含 media）、`Watch/WatchSnapshot.swift`（`Message.kind`）、`Watch/WatchEngine.swift`（payload `kind`）、`Handler/WeComCommandHandler.swift`（history `kind`）。
- Test `MessageRowParserTests`（图片夹具）、`WeComCommandHandlerTests`、`WatchEngineTests`。

### Task 4: 控制台会话页刷新 / 清空 / 提示；发送页选择器；设置页补全
- Modify `Sources/imctl-console/Model/ConsoleModel.swift`（`socketPathOverride`、`historyError`、`navigate` 重读、`open` 提示、`loadStoredSettings(mqttURL:proxyURL:)`、`saveMQTT(keepAliveSeconds:to:)`、`saveProxy(corpId:agentId:timeout:to:)`）、`Views/ConversationsView.swift`、`Views/SendView.swift`、`Views/SettingsView.swift`。
- Test `Tests/imctl-consoleTests/ConsoleModelTests.swift`（假处理器 socket：切换重读、失败清空、设置往返）。

### Task 5: 文档与活体
- 协议 §6.3 / §6.6 / §7.4 / §5；README 控制台段；门报告 `docs/gates/2026-09-15-b8-console-reading-and-external-group.md`；活体：重发 1 条到三人外部群，`message.observed.conversationType = group`。
